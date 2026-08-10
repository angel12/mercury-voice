import Foundation

/// The hands-free conversation state machine:
/// `idle → listening → transcribing → thinking → speaking → (re-arm) listening`
/// with full-duplex barge-in. A port of the desktop's
/// `use-voice-conversation.ts`; deviations are commented at the site.
///
/// Generic over the clock so tests can drive time manually.
public actor ConversationEngine<C: Clock> where C.Duration == Duration {
    private let recorder: any VoiceRecording
    private let barge: any BargeMonitoring
    private let transcriber: any Transcribing
    private let speech: any SpeechPlaying
    private let agent: any AgentInterfacing
    private let callbacks: ConversationCallbacks
    private let clock: C

    // MARK: State (mirrors the desktop hook's refs)

    public private(set) var status: ConversationStatus = .idle
    private var enabled = false
    private var muted = false
    private var paused = false
    private var lastTranscript: String?

    private var pendingStart = false
    private var turnClosing = false
    private var awaitingSpokenResponse = false
    private var responseID: String?
    private var spokenSourceLength = 0
    private var speechSession: (any SpeechStreaming)?
    /// The reply text being spoken this turn, kept for the self-echo check on
    /// barge captures (issue #12).
    private var spokenReplyText: String?
    private var bargeMonitorActive = false
    private var bargeCapturePending = false
    private var barged = false
    private var speechStartSequence = 0
    /// Set when playback was interrupted by barge-in; the next submit within
    /// the TTL carries `interrupted: true`.
    private var interruptedLatchAt: C.Instant?

    private var turnTimeoutTask: Task<Void, Never>?
    private var turnTimeoutGeneration = 0
    private var speechTask: Task<Void, Never>?
    private var thinkingChimeTask: Task<Void, Never>?
    private var thinkingChimeGeneration = 0

    private var stateSubscribers: [UUID: AsyncStream<ConversationUIState>.Continuation] = [:]

    public init(
        recorder: any VoiceRecording,
        bargeMonitor: any BargeMonitoring,
        transcriber: any Transcribing,
        speech: any SpeechPlaying,
        agent: any AgentInterfacing,
        callbacks: ConversationCallbacks = ConversationCallbacks(),
        clock: C
    ) {
        self.recorder = recorder
        self.barge = bargeMonitor
        self.transcriber = transcriber
        self.speech = speech
        self.agent = agent
        self.callbacks = callbacks
        self.clock = clock
    }

    // MARK: Observation

    public var uiState: ConversationUIState {
        ConversationUIState(
            status: status, enabled: enabled, muted: muted, paused: paused,
            lastTranscript: lastTranscript)
    }

    public func uiStates() -> AsyncStream<ConversationUIState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(uiState)
            stateSubscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateSubscriber(id) }
            }
        }
    }

    private func removeStateSubscriber(_ id: UUID) {
        stateSubscribers.removeValue(forKey: id)
    }

    private func setStatus(_ new: ConversationStatus) {
        let old = status
        status = new
        if new == .thinking, old != .thinking {
            startThinkingChime()
        } else if new != .thinking, old == .thinking {
            stopThinkingChime()
        }
        publishState()
    }

    private func publishState() {
        for sub in stateSubscribers.values { sub.yield(uiState) }
    }

    // MARK: Public controls

    /// Begin the conversation: unmute, reset speech bookkeeping, arm the mic.
    public func start() async {
        enabled = true
        muted = false
        awaitingSpokenResponse = false
        await dropSpeechSession()
        await agent.consumePendingSpeech()
        pendingStart = true
        publishState()
        await startListening()
    }

    /// Full teardown: stop everything, no re-arm.
    public func end() async {
        enabled = false
        pendingStart = false
        clearTurnTimeout()
        speechTask?.cancel()
        speechTask = nil
        await dropSpeechSession()
        await speech.stopPlayback()
        await recorder.cancel()
        setStatus(.idle)
    }

    /// "Tap to end turn now" — force-transcribe (Space bar equivalent).
    public func stopTurnNow() async {
        guard status == .listening else { return }
        await handleTurn(forceTranscribe: true)
    }

    /// Stop button: end speech, don't re-arm the mic (conversation stays on;
    /// the user speaks again via `listenNow()` or by unmuting).
    public func stopSpeech() async {
        pendingStart = false
        if status == .listening {
            clearTurnTimeout()
            await recorder.cancel()
            setStatus(.idle)
            return
        }
        if status == .thinking {
            // Give up on speaking this turn's reply.
            awaitingSpokenResponse = false
        }
        await speech.stopPlayback()
        await drive()
    }

    /// The explicit way back to listening after Stop leaves the loop idle
    /// (issue #17): latch a mic start without touching mute. If the agent is
    /// still finishing the stopped turn, the latch holds until drive()
    /// re-arms on the busy flip.
    public func listenNow() async {
        guard enabled, !micBlocked, status == .idle else { return }
        pendingStart = true
        await drive()
    }

    public func toggleMute() async {
        muted.toggle()
        if muted {
            clearTurnTimeout()
            await recorder.cancel()
            await suspendBargeMonitor()
            if status == .listening { setStatus(.idle) } else { publishState() }
        } else {
            if enabled, status == .idle, !(await agent.isBusy) { pendingStart = true }
            await resumeBargeMonitor()
            publishState()
            await drive()
        }
    }

    /// Pause/resume the loop without ending it (approval sheet, audio-session
    /// interruption). Behaves like a mute the UI doesn't show as muted.
    public func setPaused(_ newValue: Bool) async {
        guard paused != newValue else { return }
        paused = newValue
        if paused {
            clearTurnTimeout()
            await recorder.cancel()
            await suspendBargeMonitor()
            if status == .listening { setStatus(.idle) } else { publishState() }
        } else {
            if enabled, status == .idle, !(await agent.isBusy) { pendingStart = true }
            await resumeBargeMonitor()
            publishState()
            await drive()
        }
    }

    /// External notification that agent state changed (busy flipped, reply
    /// text grew) — the equivalent of the desktop's drive effect re-running.
    public func agentStateChanged() async {
        await drive()
    }

    // MARK: Listening

    private var micBlocked: Bool { muted || paused }

    private func startListening() async {
        pendingStart = false
        guard enabled, !micBlocked, !(await agent.isBusy) else { return }
        guard !bargeCapturePending else { return }  // the monitor owns the mic
        guard status == .idle else { return }

        do {
            try await recorder.start(
                vad: VADParameters(),
                onAutoStop: { [weak self] in
                    Task { await self?.handleTurn(forceTranscribe: false) }
                })
        } catch {
            callbacks.onNotice("Microphone unavailable: \(error.localizedDescription)")
            setStatus(.idle)
            enabled = false
            callbacks.onFatalError(error.localizedDescription)
            return
        }
        // The engine may have been torn down while the mic was opening.
        guard enabled, !micBlocked else {
            await recorder.cancel()
            return
        }
        setStatus(.listening)

        // A stale hard-cap timer from an earlier cycle must never fire
        // mid-listen — clear before arming (desktop does the same).
        clearTurnTimeout()
        turnTimeoutGeneration += 1
        let generation = turnTimeoutGeneration
        turnTimeoutTask = Task { [clock] in
            try? await clock.sleep(for: VoiceConstants.turnHardCap, tolerance: nil)
            guard !Task.isCancelled else { return }
            await self.turnTimerFired(generation: generation)
        }
    }

    private func turnTimerFired(generation: Int) async {
        guard generation == turnTimeoutGeneration, status == .listening else { return }
        await handleTurn(forceTranscribe: false)
    }

    private func clearTurnTimeout() {
        turnTimeoutGeneration += 1
        turnTimeoutTask?.cancel()
        turnTimeoutTask = nil
    }

    // MARK: Thinking chime (issue #15)

    /// While status stays `.thinking`, tick `onThinkingTick` on a fixed
    /// cadence so the user can hear the agent is still working. First tick
    /// lands one full interval in — fast replies never chime.
    private func startThinkingChime() {
        stopThinkingChime()
        thinkingChimeGeneration += 1
        let generation = thinkingChimeGeneration
        thinkingChimeTask = Task { [clock] in
            while !Task.isCancelled {
                try? await clock.sleep(
                    for: VoiceConstants.thinkingChimeInterval, tolerance: nil)
                guard !Task.isCancelled else { return }
                guard await self.thinkingChimeTicked(generation: generation) else { return }
            }
        }
    }

    /// Returns false when the tick is stale and the loop should die.
    private func thinkingChimeTicked(generation: Int) -> Bool {
        guard generation == thinkingChimeGeneration, status == .thinking else { return false }
        // Paused = an approval/clarify sheet or an audio interruption — the
        // agent is waiting on the user, not thinking; stay quiet but keep the
        // loop alive for the resume.
        if !paused { callbacks.onThinkingTick() }
        return true
    }

    private func stopThinkingChime() {
        thinkingChimeGeneration += 1
        thinkingChimeTask?.cancel()
        thinkingChimeTask = nil
    }

    // MARK: Turn close (listening → transcribing → thinking)

    private func handleTurn(forceTranscribe: Bool) async {
        guard !turnClosing else { return }
        guard status == .listening else { return }
        turnClosing = true
        defer { turnClosing = false }

        clearTurnTimeout()
        setStatus(.transcribing)
        let result = await recorder.stop()

        guard let result, result.heardSpeech || forceTranscribe else {
            // Never heard speech — quietly re-arm.
            if enabled, !micBlocked, !(await agent.isBusy), status != .speaking {
                pendingStart = true
            }
            setStatus(.idle)
            await drive()
            return
        }
        callbacks.onTurnCaptured()

        let transcript: String
        do {
            transcript = try await transcriber.transcribe(result)
        } catch {
            callbacks.onNotice("Transcription failed: \(error.localizedDescription)")
            if enabled, !micBlocked, !(await agent.isBusy) { pendingStart = true }
            setStatus(.idle)
            await drive()
            return
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty transcript = silence: success, quietly re-arm.
            // (Desktop re-arms on `enabled` alone here.)
            if enabled { pendingStart = true }
            setStatus(.idle)
            await drive()
            return
        }

        if StopWords.isStopCommand(trimmed) {
            await endConversationOnStopWord()
            return
        }

        lastTranscript = trimmed
        awaitingSpokenResponse = true
        await dropSpeechSession()
        do {
            try await agent.submit(text: trimmed, interrupted: consumeInterruptedLatch())
        } catch {
            callbacks.onNotice("Send failed: \(error.localizedDescription)")
            awaitingSpokenResponse = false
            if enabled, !micBlocked { pendingStart = true }
            setStatus(.idle)
            await drive()
            return
        }
        setStatus(.thinking)
        await drive()
    }

    private func endConversationOnStopWord() async {
        await end()
        callbacks.onStopWord()
    }

    // MARK: Drive loop (the desktop's effect)

    private func drive() async {
        if awaitingSpokenResponse, status != .speaking {
            if status == .thinking {
                let busy = await agent.isBusy
                if busy || bargeCapturePending { await ensureBargeMonitor() }
            }
            if let response = await agent.pendingSpeech() {
                await openLiveSpeech(responseID: response.id)
                return
            }
            if !(await agent.isBusy), status == .thinking, !bargeCapturePending {
                // Tool-only or errored turn: nothing to speak, go around.
                awaitingSpokenResponse = false
                await dropSpeechSession()
                pendingStart = true
                setStatus(.idle)
            }
        }
        if !awaitingSpokenResponse, status == .thinking, !bargeCapturePending,
            !(await agent.isBusy)
        {
            // Stop landed while thinking, disowning this turn's reply. Settle
            // to idle when the turn completes — without this the status (and
            // its chime) stays "thinking" forever, and even unmute can't
            // recover. No auto re-arm: the user asked for quiet; listenNow()
            // or unmute is the way back.
            await agent.consumePendingSpeech()
            setStatus(.idle)
        }
        if await agent.isBusy { return }
        if status != .idle { return }
        if pendingStart { await startListening() }
    }

    // MARK: Speaking

    private func openLiveSpeech(responseID: String) async {
        // Reentrancy guard: two overlapping drive() calls can both see a
        // pending response across their suspension points; the first to get
        // here flips status synchronously, so the second must bail or it
        // would spawn a duplicate speech stream.
        guard status != .speaking else { return }
        self.responseID = responseID
        spokenSourceLength = 0
        setStatus(.speaking)
        await ensureBargeMonitor()
        speechTask = Task { await self.runLiveSpeech(responseID: responseID) }
    }

    private func runLiveSpeech(responseID: String) async {
        let sequenceBeforeStart = await speech.sequence
        guard let session = await speech.startStream() else {
            if await speech.sequence > sequenceBeforeStart {
                // A Stop landed during stream setup.
                awaitingSpokenResponse = false
                await settleAfterSpeech(barged: false, stoppedDuringSetup: true)
            } else {
                speechSession = nil
                await awaitFallbackSpeech(responseID: responseID)
            }
            return
        }
        guard self.responseID == responseID else {
            await speech.stopPlayback()
            return
        }
        // startStream stops old playback exactly once (+1); anything beyond
        // that was a user Stop racing the setup.
        let sequenceAfterStart = await speech.sequence
        let stoppedDuringStart = sequenceAfterStart > sequenceBeforeStart + 1
        speechStartSequence = sequenceAfterStart
        speechSession = session
        if stoppedDuringStart {
            await speech.stopPlayback()
            awaitingSpokenResponse = false
            await settleAfterSpeech(barged: false, stoppedDuringSetup: true)
            return
        }

        let feedTask = Task { [clock] in
            while !Task.isCancelled {
                await self.feedSpeechSession(responseID: responseID)
                try? await clock.sleep(for: VoiceConstants.speechFeedInterval, tolerance: nil)
            }
        }
        await feedSpeechSession(responseID: responseID)
        let outcome = await session.waitDone()
        feedTask.cancel()

        guard self.responseID == responseID else { return }
        if outcome == .fallback {
            await awaitFallbackSpeech(responseID: responseID)
        } else {
            awaitingSpokenResponse = false
            await settleAfterSpeech(barged: barged)
        }
    }

    /// Push the newly-grown reply tail into the stream; `finish` only when
    /// the reply bubble is complete AND the turn is no longer busy — a
    /// non-pending interim bubble mid-tool-call must NOT end the stream.
    private func feedSpeechSession(responseID: String) async {
        guard let session = speechSession, self.responseID == responseID else { return }
        let response = await agent.pendingSpeech()
        if let response, response.id == responseID {
            spokenReplyText = response.text
            let count = response.text.count
            if count > spokenSourceLength {
                let tail = String(response.text.dropFirst(spokenSourceLength))
                // Advance the watermark BEFORE suspending on append: an
                // overlapping feed tick must not see the stale length and
                // speak the same tail twice.
                spokenSourceLength = count
                await session.append(tail)
            }
            if !response.pending, !(await agent.isBusy) {
                await session.finish()
            }
        } else if !(await agent.isBusy) {
            await session.finish()
        }
    }

    /// Whole-clip fallback: wait for the reply text to finish, then play it.
    private func awaitFallbackSpeech(responseID: String) async {
        while true {
            guard self.responseID == responseID else { return }
            guard let response = await agent.pendingSpeech() else {
                await settleAfterSpeech(barged: false)
                return
            }
            if !response.pending, !(await agent.isBusy) {
                spokenReplyText = response.text
                await ensureBargeMonitor()
                // Deviation from the desktop (deliberate): stop + capture the
                // sequence BEFORE playback so a user Stop mid-clip is seen by
                // the settle logic and the mic does not re-arm.
                await speech.stopPlayback()
                speechStartSequence = await speech.sequence
                _ = await speech.playFallback(text: response.text)
                guard self.responseID == responseID else { return }
                awaitingSpokenResponse = false
                await settleAfterSpeech(barged: barged)
                return
            }
            try? await clock.sleep(for: VoiceConstants.fallbackPollInterval, tolerance: nil)
        }
    }

    /// After speech finishes (or is stopped): re-open the mic unless the user
    /// explicitly stopped, or a barge capture owns the next turn.
    private func settleAfterSpeech(barged: Bool, stoppedDuringSetup: Bool = false) async {
        if barged || !awaitingSpokenResponse {
            awaitingSpokenResponse = false
            await agent.consumePendingSpeech()
        }
        if bargeCapturePending {
            // The barge monitor's recorder owns the mic; it will hand the
            // captured utterance to submitCapturedUtterance.
            speechSession = nil
            responseID = nil
            spokenSourceLength = 0
            setStatus(.listening)
            return
        }
        await dropSpeechSession()
        let sequence = await speech.sequence
        let stoppedByUser =
            stoppedDuringSetup || (speechStartSequence > 0 && sequence > speechStartSequence)
        speechStartSequence = 0
        if enabled, !stoppedByUser { pendingStart = true }
        setStatus(.idle)
        await drive()
    }

    /// Universal speech-side reset (desktop's `dropSpeechSession`): stops the
    /// barge monitor and clears everything except `speechStartSequence`.
    private func dropSpeechSession() async {
        if bargeMonitorActive {
            bargeMonitorActive = false
            await barge.stop()
        }
        bargeCapturePending = false
        barged = false
        speechSession = nil
        spokenReplyText = nil
        responseID = nil
        spokenSourceLength = 0
    }

    // MARK: Barge-in

    private func ensureBargeMonitor() async {
        guard !bargeMonitorActive, !micBlocked else { return }
        bargeMonitorActive = true
        do {
            try await barge.start(
                isPlaying: { [speech] in await speech.isSpeaking },
                onSpeech: { [weak self] in
                    Task { await self?.bargeSpeechTripped() }
                },
                onUtterance: { [weak self] utterance in
                    Task { await self?.bargeUtteranceCaptured(utterance) }
                })
        } catch {
            bargeMonitorActive = false
        }
    }

    /// Mute/pause: make barge-in deaf without disturbing the speech session
    /// OR the capture engine — stopping the voice-processing mic unit
    /// mid-playback kills TTS output on macOS, so the monitor stays attached
    /// and just discards audio. Any in-flight capture is cancelled.
    private func suspendBargeMonitor() async {
        if bargeMonitorActive {
            await barge.setSuspended(true)
        }
        bargeCapturePending = false
        barged = false
    }

    /// Unblock: bring barge-in back. The still-attached monitor just starts
    /// hearing again (no engine restart); if it was never armed because the
    /// block predated playback, arm it now. drive() covers the thinking case.
    private func resumeBargeMonitor() async {
        guard !micBlocked else { return }
        if bargeMonitorActive {
            await barge.setSuspended(false)
        } else if status == .speaking {
            await ensureBargeMonitor()
        }
    }

    private func bargeSpeechTripped() async {
        // A trip can land after mute/pause already stopped the monitor (the
        // callback hops actors); a silenced mic must not interrupt playback.
        guard bargeMonitorActive, !micBlocked else { return }
        bargeCapturePending = true
        barged = true
        interruptedLatchAt = clock.now
        await speech.stopPlayback()
        if await agent.isBusy {
            await agent.interrupt()
        }
    }

    private func bargeUtteranceCaptured(_ utterance: RecordedUtterance?) async {
        bargeCapturePending = false
        bargeMonitorActive = false  // the monitor cleaned itself up
        // Muted/paused mid-capture: the audio was recorded from a mic the
        // user believes is off — drop it, never submit it.
        guard !micBlocked else { return }
        await submitCapturedUtterance(utterance)
    }

    private func submitCapturedUtterance(_ utterance: RecordedUtterance?) async {
        // Desktop's resumeListening: enabled && !muted, no busy check.
        func resumeListening() {
            if enabled, !micBlocked { pendingStart = true }
            setStatus(.idle)
        }

        guard let utterance else {
            resumeListening()
            await drive()
            return
        }
        callbacks.onTurnCaptured()
        setStatus(.transcribing)

        let transcript: String
        do {
            transcript = try await transcriber.transcribe(utterance)
        } catch {
            callbacks.onNotice("Transcription failed: \(error.localizedDescription)")
            resumeListening()
            await drive()
            return
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            resumeListening()
            await drive()
            return
        }
        if StopWords.isStopCommand(trimmed) {
            await endConversationOnStopWord()
            return
        }
        // Self-echo (issue #12): a capture that just repeats the reply being
        // spoken is the speakers, not the user — submitting it would loop the
        // agent's voice back at itself. Drop it and re-open the mic.
        if let reply = spokenReplyText, EchoGuard.isLikelyEcho(transcript: trimmed, reply: reply) {
            resumeListening()
            await drive()
            return
        }

        // Wait for the interrupted turn to settle (busy to clear); submit
        // anyway at the deadline — the submit seam itself rejects when busy.
        let deadline = clock.now.advanced(by: VoiceConstants.interruptSettleTimeout)
        while await agent.isBusy, clock.now < deadline {
            try? await clock.sleep(for: VoiceConstants.interruptSettlePoll, tolerance: nil)
        }

        lastTranscript = trimmed
        awaitingSpokenResponse = true
        await dropSpeechSession()
        await agent.consumePendingSpeech()
        do {
            try await agent.submit(text: trimmed, interrupted: consumeInterruptedLatch())
        } catch {
            callbacks.onNotice("Send failed: \(error.localizedDescription)")
            awaitingSpokenResponse = false
            resumeListening()
            await drive()
            return
        }
        setStatus(.thinking)
        await drive()
    }

    private func consumeInterruptedLatch() -> Bool {
        guard let at = interruptedLatchAt else { return false }
        interruptedLatchAt = nil
        return clock.now < at.advanced(by: VoiceConstants.interruptedLatchTTL)
    }
}
