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
    private let microphone: any MicrophoneAuthorizing
    private let callbacks: ConversationCallbacks
    private let clock: C

    // MARK: State (mirrors the desktop hook's refs)

    public private(set) var status: ConversationStatus = .idle
    private var enabled = false
    private var muted = false
    private var paused = false
    private var lastTranscript: String?
    private var microphoneDenied = false

    private var pendingStart = false
    private var turnClosing = false
    /// Stop pressed while a turn was closing (status == .transcribing, or a
    /// close already in flight): the user asked for quiet before the
    /// transcript existed, so the close path must drop its result — no
    /// submit, no re-arm (issue #5). Consumed by the close path, and cleared
    /// whenever the mic deliberately re-opens.
    private var stopRequested = false
    private var awaitingSpokenResponse = false
    private var responseID: String?
    private var spokenSourceLength = 0
    private var speechSession: (any SpeechStreaming)?
    /// The reply text being spoken this turn, kept for the self-echo check on
    /// barge captures (issue #12).
    private var spokenReplyText: String?
    private var bargeMonitorActive = false
    /// iOS mute must stop the barge monitor (and clear this flag) so unmute
    /// can restart capture; macOS only suspends so the voice-processing
    /// input stays attached during playback (issue #40).
    private let detachBargeCaptureWhileMuted: Bool
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
        microphone: any MicrophoneAuthorizing = AlwaysGrantedMicrophone(),
        callbacks: ConversationCallbacks = ConversationCallbacks(),
        clock: C,
        detachBargeCaptureWhileMuted: Bool? = nil
    ) {
        self.recorder = recorder
        self.barge = bargeMonitor
        self.transcriber = transcriber
        self.speech = speech
        self.agent = agent
        self.microphone = microphone
        self.callbacks = callbacks
        self.clock = clock
        self.detachBargeCaptureWhileMuted =
            detachBargeCaptureWhileMuted
            ?? shouldDetachBargeCaptureWhileMuted(isIOS: bargeMuteRunsOnIOS)
    }

    // MARK: Observation

    public var uiState: ConversationUIState {
        ConversationUIState(
            status: status, enabled: enabled, muted: muted, paused: paused,
            lastTranscript: lastTranscript, microphoneDenied: microphoneDenied)
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
        microphoneDenied = false
        stopRequested = false
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
        stopRequested = false
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
            // Latch as well as cancel: the VAD's auto-stop hops actors, so a
            // turn close may already be in flight — if handleTurn has passed
            // its .listening guard, the latch keeps it from re-arming off a
            // cancelled recording.
            stopRequested = true
            clearTurnTimeout()
            await recorder.cancel()
            // handleTurn may have taken over during the await; leave the
            // status to it (it settles to idle when it consumes the latch).
            if status == .listening { setStatus(.idle) }
            return
        }
        if status == .transcribing {
            // The turn is between mic close and submit (the 1-3s STT window,
            // issue #5); there is no playback to stop yet — latch so the
            // pending transcript is dropped instead of submitted.
            stopRequested = true
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
        // A deliberate mic re-open (listenNow, unmute, the next turn)
        // invalidates any stale stop request — it only ever applies to the
        // turn it interrupted.
        stopRequested = false

        // Ask for the permission ourselves (issue #23 §1.4). Letting the
        // audio engine trip the prompt hides a denial behind an OSStatus.
        // Re-checked on every arm: macOS lets the user revoke it any time.
        let authorization = await microphone.request()
        guard enabled, !micBlocked, status == .idle else { return }
        guard authorization == .granted else {
            microphoneDenied = true
            enabled = false
            setStatus(.idle)
            callbacks.onMicrophoneDenied()
            return
        }

        do {
            try await recorder.start(
                vad: VADParameters(endOfTurnSilence: TurnSilencePreference.duration),
                onAutoStop: { [weak self] in
                    Task { await self?.handleTurn(forceTranscribe: false) }
                })
        } catch {
            guard await callbacks.micFailureIsFatal() else {
                // Transient refusal (backgrounded / interrupted on iOS,
                // issue #31): park paused with the start latched — the
                // owner's setPaused(false) on foreground re-arms.
                paused = true
                pendingStart = true
                setStatus(.idle)
                callbacks.onMicParked()
                return
            }
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
        // Deliberately strong: [weak self] would break the closure's actor-
        // context inheritance, moving the task to the global executor — the
        // timer would then race the actor jobs it must stay FIFO with (a
        // cancel can land before the sleep parks). The task↔actor cycle this
        // creates lasts only until the timer fires or is cancelled (#7).
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
        // Strong on purpose (see turnTimeoutTask): this loop is the #7
        // retain cycle — it pins the engine while status stays .thinking, so
        // an engine released without end() mid-thinking leaks. Every owner
        // path calls end(); breaking the cycle with [weak self] costs the
        // actor-FIFO ordering the engine's determinism depends on.
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
            let stopped = consumeStopRequest()
            // Never heard speech — quietly re-arm (unless Stop landed while
            // the turn was closing; the user asked for quiet).
            if !stopped, enabled, !micBlocked, !(await agent.isBusy), status != .speaking {
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
            let stopped = consumeStopRequest()
            if !stopped {
                // A Stop mid-close voids the turn — the failure of a
                // transcript that was going to be dropped is not news.
                callbacks.onNotice("Transcription failed: \(error.localizedDescription)")
                if enabled, !micBlocked, !(await agent.isBusy) { pendingStart = true }
            }
            setStatus(.idle)
            await drive()
            return
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let stopped = consumeStopRequest()
            // Empty transcript = silence: success, quietly re-arm.
            // (Desktop re-arms on `enabled` alone here.)
            if enabled, !stopped { pendingStart = true }
            setStatus(.idle)
            await drive()
            return
        }

        if consumeStopRequest() {
            // Stop landed during the STT window (issue #5): the user asked
            // for quiet before this transcript existed. Drop it — no
            // stop-word scan, no submit — and don't re-arm; listenNow() or
            // unmute is the way back, matching Stop's contract in every
            // other phase.
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
        // Read the Stop-detection baseline BEFORE .speaking becomes visible:
        // a Stop can land between this method and runLiveSpeech's first
        // instruction (the task hop is not FIFO with other actor jobs), and a
        // baseline read after that Stop would absorb its sequence bump and
        // speak a reply the user just stopped (review finding L3).
        let sequenceBeforeStart = await speech.sequence
        guard status != .speaking else { return }
        setStatus(.speaking)
        await ensureBargeMonitor()
        speechTask = Task {
            await self.runLiveSpeech(
                responseID: responseID, sequenceBeforeStart: sequenceBeforeStart)
        }
    }

    private func runLiveSpeech(responseID: String, sequenceBeforeStart: Int) async {
        guard let session = await speech.startStream() else {
            // startStream's own stopPlayback bumps the sequence once (+1)
            // even when it fails; only a bump beyond that is a user Stop
            // racing the setup. Counting the contract bump as a Stop made
            // every unavailable stream settle as "user stopped" — the
            // fallback below was unreachable, so a TTS setup failure
            // silently muted the reply and parked the mic (issue #11).
            if await speech.sequence > sequenceBeforeStart + 1 {
                awaitingSpokenResponse = false
                await settleAfterSpeech(barged: false, stoppedByUser: true)
            } else {
                speechSession = nil
                // The guard above proved the sequence is exactly the contract
                // bump, so pass that instead of re-reading it: a Stop landing
                // between here and the wait's first hop must stay visible.
                await awaitFallbackSpeech(
                    responseID: responseID, baseline: sequenceBeforeStart + 1)
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
            await settleAfterSpeech(barged: false, stoppedByUser: true)
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
            // Keep the baseline the stream was started against: a Stop during
            // streaming stays a bump past it.
            await awaitFallbackSpeech(responseID: responseID, baseline: speechStartSequence)
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
    ///
    /// The wait is the second Stop-detection window (issue #34). Nothing here
    /// is playing yet, so a Stop lands as a bare sequence bump against
    /// `baseline` — the loop must notice it instead of polling on and
    /// re-capturing a baseline that hides it. `baseline` is the caller's
    /// already-validated sequence and is never re-read from the speech
    /// output, so a Stop from any earlier phase of this turn stays visible.
    private func awaitFallbackSpeech(responseID: String, baseline: Int) async {
        while true {
            guard self.responseID == responseID else { return }
            if await speech.sequence > baseline {
                // A Stop (or a barge trip) landed during the wait. Settle
                // without speaking: `barged` routes a pending capture to the
                // mic, everything else stays quiet until listenNow/unmute.
                await abandonFallbackSpeech()
                return
            }
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
                let sequence = await speech.sequence
                // Our own stopPlayback is the only bump we expect (+1);
                // anything past it is a Stop that raced the last hop of the
                // wait, and adopting it as the baseline would absorb it.
                guard sequence == baseline + 1 else {
                    await abandonFallbackSpeech()
                    return
                }
                speechStartSequence = sequence
                _ = await speech.playFallback(text: response.text)
                guard self.responseID == responseID else { return }
                awaitingSpokenResponse = false
                await settleAfterSpeech(barged: barged)
                return
            }
            try? await clock.sleep(for: VoiceConstants.fallbackPollInterval, tolerance: nil)
        }
    }

    /// Give up on the whole-clip reply because playback was stopped before it
    /// could start. No baseline is left behind for settle to compare against
    /// (there was no playback), so the stop is passed in directly.
    private func abandonFallbackSpeech() async {
        speechStartSequence = 0
        awaitingSpokenResponse = false
        await settleAfterSpeech(barged: barged, stoppedByUser: true)
    }

    /// After speech finishes (or is stopped): re-open the mic unless the user
    /// explicitly stopped, or a barge capture owns the next turn.
    private func settleAfterSpeech(barged: Bool, stoppedByUser: Bool = false) async {
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
        let stopped =
            stoppedByUser || (speechStartSequence > 0 && sequence > speechStartSequence)
        speechStartSequence = 0
        if enabled, !stopped { pendingStart = true }
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

    /// Mute/pause: make barge-in deaf. macOS keeps the monitor attached —
    /// stopping the voice-processing mic unit mid-playback kills TTS.
    /// iOS releases the capture consumer so the hardware mic / privacy
    /// indicator can go off; unmute re-arms via `ensureBargeMonitor`, which
    /// already swallows a refused background mic start. Any in-flight
    /// capture is cancelled.
    private func suspendBargeMonitor() async {
        if bargeMonitorActive {
            if detachBargeCaptureWhileMuted {
                bargeMonitorActive = false
                await barge.stop()
            } else {
                await barge.setSuspended(true)
            }
        }
        bargeCapturePending = false
        barged = false
    }

    /// Unblock: bring barge-in back. A still-attached monitor (macOS) just
    /// starts hearing again; a detached one (iOS) is restarted. drive()
    /// covers the thinking case if we aren't speaking.
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
        // Desktop's resumeListening: enabled && !muted, no busy check. The
        // stop latch is consumed at every exit — a Stop during the capture's
        // STT window voids the turn and must not re-arm (issue #5).
        func resumeListening() {
            if enabled, !micBlocked, !consumeStopRequest() { pendingStart = true }
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

        if consumeStopRequest() {
            // Stop landed while the capture was transcribing or waiting for
            // the interrupted turn to settle — drop it, don't re-arm.
            setStatus(.idle)
            await drive()
            return
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

    private func consumeStopRequest() -> Bool {
        let requested = stopRequested
        stopRequested = false
        return requested
    }

    private func consumeInterruptedLatch() -> Bool {
        guard let at = interruptedLatchAt else { return false }
        interruptedLatchAt = nil
        return clock.now < at.advanced(by: VoiceConstants.interruptedLatchTTL)
    }
}
