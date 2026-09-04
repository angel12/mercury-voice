import Foundation
import HermesKit
import Observation
import VoiceEngine

#if os(iOS)
    import AVFoundation
    import CallKit
    import UIKit
#endif

/// Glue for one voice conversation: owns the session, routes gateway events
/// into the turn tracker, drives the voice engine, and surfaces
/// approval/clarify prompts to the UI.
@MainActor
@Observable
final class ConversationController {
    enum Mode {
        case create(cwd: String?, title: String?)
        case resume(storedID: String)
    }

    // MARK: Published state

    private(set) var voiceState = ConversationUIState()
    private(set) var sessionTitle: String?
    private(set) var profileName: String?
    private(set) var projectName: String?
    private(set) var assistantCaption: String = ""
    private(set) var toolTicker: String?
    private(set) var micLevel: Double = 0
    private(set) var setupError: String?
    private(set) var notice: String?
    private(set) var connectionHealthy = true
    /// Latest usage snapshot: live `session.usage` ticks mid-turn, settled by
    /// the authoritative `message.complete` usage. nil until the first turn
    /// reports, or when the backend doesn't report usage at all.
    private(set) var usage: SessionUsage?
    var approval: ApprovalRequest?
    var clarify: ClarifyRequest?
    /// Ends the conversation view when the user speaks a stop word.
    var didEndByStopWord = false

    // Dev screen transcript (text path).
    struct DevMessage: Identifiable {
        let id = UUID()
        var role: String
        var text: String
    }
    private(set) var devMessages: [DevMessage] = []

    // MARK: Wiring

    private let connection: HermesConnection
    private let profile: String?
    private var handle: SessionHandle?
    private var mode: Mode?

    private let tracker: AgentTurnTracker
    private var engine: ConversationEngine<ContinuousClock>?
    private let speech: HermesSpeechOutput
    private let voiceStore: VoiceConfigStore
    private let capture = AudioCaptureService.shared
    private let cues = ConversationCuePlayer()
    private var stateTask: Task<Void, Never>?
    private var captionTask: Task<Void, Never>?

    #if os(iOS)
        // Background-audio lifecycle (issue #31). The keepalive stream pins
        // the capture engine on for the whole conversation, so iOS never
        // sees a stopped-audio gap to suspend into, and audio only ever
        // CONTINUES in the background (allowed) rather than STARTING
        // (refused). Recorder/monitor consumers still decide what is heard.
        private var keepaliveStreamID: UUID?
        private var keepaliveDrain: Task<Void, Never>?
        private var interruptionObserver: (any NSObjectProtocol)?
        /// Observation-only CallKit: a phone call's interruption `.ended` is
        /// often never delivered, but CXCallObserver reports the call ending
        /// reliably — that's the auto-resume trigger.
        private var callObserver: CXCallObserver?
        private var callObserverDelegate: CallEndWatcher?
        /// True between an interruption's begin and end notifications.
        private var audioInterrupted = false
        /// True when the engine parked after a refused mic start; cleared by
        /// the foreground/interruption-ended resume.
        private var parkedForBackground = false
    #endif

    /// Runtime session id lives in a box the tracker's submit closure reads,
    /// so a reconnect-resume transparently re-routes prompts.
    private let sessionBox = SessionBox()

    final class SessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _runtimeID: String?
        private var _storedID: String?

        var runtimeID: String? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _runtimeID
            }
            set {
                lock.lock()
                _runtimeID = newValue
                lock.unlock()
            }
        }

        var storedID: String? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _storedID
            }
            set {
                lock.lock()
                _storedID = newValue
                lock.unlock()
            }
        }
    }

    /// Tracker events must be applied in arrival order (deltas garble
    /// otherwise) — handle() yields into this serial pump.
    private var trackerEventContinuation: AsyncStream<GatewayEvent>.Continuation?
    private var trackerEventPump: Task<Void, Never>?

    init(connection: HermesConnection, profile: String?) {
        self.connection = connection
        self.profile = profile
        self.profileName = profile
        // One client-direct voice-config cache per conversation: STT and TTS
        // share the fetch, and its keys die with the controller (memory only).
        let voiceStore = VoiceConfigStore(rest: connection.rest, profile: profile)
        self.voiceStore = voiceStore
        self.speech = HermesSpeechOutput(
            rest: connection.rest, profile: profile, voiceConfig: voiceStore)

        let box = sessionBox
        self.tracker = AgentTurnTracker(
            submit: { text, interrupted in
                guard let sid = box.runtimeID else { throw HermesError.notConnected }
                try await connection.submitPrompt(
                    sessionID: sid, text: text, interrupted: interrupted)
            },
            interrupt: {
                guard let sid = box.runtimeID else { return }
                try? await connection.interruptSession(sessionID: sid)
            })

        let (stream, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        trackerEventContinuation = continuation
        let tracker = self.tracker
        trackerEventPump = Task.detached {
            for await event in stream {
                await tracker.handle(event: event)
            }
        }
    }

    // MARK: Lifecycle

    /// True once teardown() has run. begin() re-checks this after every
    /// suspension point: the user can end the conversation while session
    /// opening is still in flight (issue #38), and nothing may start after
    /// that — teardown ran against a controller with no engine or session
    /// yet, so a resumed begin() would otherwise arm the mic and hold a
    /// backend session that nobody can reach anymore.
    private var isTornDown = false

    func begin(mode: Mode) async {
        self.mode = mode
        do {
            try await openSession(mode: mode)
        } catch {
            guard !isTornDown else { return }
            setupError = (error as? HermesError)?.errorDescription ?? error.localizedDescription
            return
        }
        guard !isTornDown else {
            // Torn down while the open was in flight: teardown couldn't see
            // the session (the handle didn't exist yet), so close it here.
            await closeSessionIfOpen()
            return
        }
        await startVoiceLoop()
    }

    private func openSession(mode: Mode) async throws {
        let handle: SessionHandle
        switch mode {
        case .create(let cwd, let title):
            handle = try await connection.createSession(
                cwd: cwd, profile: profile, title: title)
        case .resume(let storedID):
            handle = try await connection.resumeSession(storedID: storedID, profile: profile)
        }
        self.handle = handle
        sessionBox.runtimeID = handle.runtimeID
        sessionBox.storedID = handle.storedID
        sessionTitle = handle.title?.isEmpty == false ? handle.title : nil
        projectName = handle.project
        if let contract = handle.desktopContract,
            contract < GatewayClient.builtAgainstDesktopContract
        {
            notice = "This Hermes backend is older than the app was built for (contract \(contract) < \(GatewayClient.builtAgainstDesktopContract)); some features may misbehave."
        }
        let running = handle.raw["running"]?.truthy ?? false
        usage = nil  // new session identity; the first turn re-reports
        lastSeenSeq = nil
        replayEpoch = await connection.replayEpoch
        await tracker.reset(busy: running)
        // A resumed live session can be parked on a prompt that was emitted
        // while no client was attached; replay it. Nothing to clear on a
        // fresh controller.
        adoptPendingPrompts(from: handle, clearStale: false)
        noteHydration(from: handle)
    }

    /// A deferred cold resume answers immediately with `hydrating: true` and
    /// loads the transcript in a background worker. The voice loop is usable
    /// right away (the first prompt.submit waits server-side), but a slow
    /// hydration should be visible; the resume_progress events clear or fail
    /// it.
    private static let hydrationNotice = "Loading session history…"

    private func noteHydration(from handle: SessionHandle) {
        if handle.raw["hydrating"]?.truthy == true {
            notice = Self.hydrationNotice
        }
    }

    private func startVoiceLoop() async {
        let engine = ConversationEngine(
            recorder: MicRecorder(capture: capture),
            bargeMonitor: BargeInMonitor(capture: capture),
            transcriber: RestTranscriber(
                rest: connection.rest, profile: profile, voiceConfig: voiceStore),
            speech: speech,
            agent: tracker,
            microphone: SystemMicrophoneAuthorization(),
            callbacks: ConversationCallbacks(
                onStopWord: { [weak self] in
                    Task { @MainActor in self?.didEndByStopWord = true }
                },
                onFatalError: { [weak self] message in
                    Task { @MainActor in self?.setupError = message }
                },
                onNotice: { [weak self] message in
                    Task { @MainActor in self?.notice = message }
                },
                onTurnCaptured: { [cues] in cues.playTurnCaptured() },
                onThinkingTick: { [cues] in cues.playThinkingTick() },
                micFailureIsFatal: { @MainActor [weak self] in
                    // Background / interruption refusals are transient
                    // (issue #31); real device or permission problems in the
                    // foreground stay fatal.
                    #if os(iOS)
                        guard let self else { return true }
                        if self.audioInterrupted { return false }
                        if UIApplication.shared.applicationState != .active { return false }
                    #endif
                    return true
                },
                onMicParked: { [weak self] in
                    Task { @MainActor in
                        #if os(iOS)
                            self?.parkedForBackground = true
                        #endif
                    }
                }),
            clock: ContinuousClock())
        self.engine = engine

        await tracker.setOnChange { [weak self] in
            Task { await self?.agentChanged() }
        }
        // Teardown may have interleaved during the hop above; it already
        // ended the (never-started) engine and closed the session — bail
        // before arming handlers, keepalive, or the mic.
        guard !isTornDown else { return }

        stateTask = Task { [weak self] in
            for await state in await engine.uiStates() {
                guard let self else { return }
                #if os(iOS)
                    let wasMuted = self.voiceState.muted
                #endif
                self.voiceState = state
                #if os(iOS)
                    if state.muted != wasMuted {
                        self.applyMuteToCapture(muted: state.muted)
                    }
                #endif
            }
        }
        capture.setLevelHandler { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }
        #if os(iOS)
            startAudioKeepalive()
            observeAudioInterruptions()
        #endif

        // A prompt replayed from the resume payload arrived before the engine
        // existed, so present() couldn't pause it — park the loop before the
        // mic ever arms; answering the prompt unpauses via resumeIfUnprompted.
        if approval != nil || clarify != nil {
            await engine.setPaused(true)
        }
        await engine.start()
    }

    func teardown() async {
        isTornDown = true
        trackerEventContinuation?.finish()
        trackerEventPump?.cancel()
        stateTask?.cancel()
        captionTask?.cancel()
        capture.setLevelHandler(nil)
        #if os(iOS)
            stopAudioKeepalive()
            if let interruptionObserver {
                NotificationCenter.default.removeObserver(interruptionObserver)
                self.interruptionObserver = nil
            }
            callObserver?.setDelegate(nil, queue: nil)
            callObserver = nil
            callObserverDelegate = nil
        #endif
        await tracker.setOnChange(nil)
        if let engine { await engine.end() }
        await closeSessionIfOpen()
    }

    /// Consumes the runtime session id so teardown and a torn-down begin()
    /// can both call this without double-closing.
    private func closeSessionIfOpen() async {
        guard let sid = sessionBox.runtimeID else { return }
        sessionBox.runtimeID = nil
        await connection.closeSession(sessionID: sid)
    }

    /// AppModel forwards scene-active. Foregrounding is authoritative: an
    /// interruption's `.ended` notification is NOT guaranteed (a phone call
    /// can end without one), so clear the flag, revive a silently-dead
    /// capture engine, and resume — every branch no-ops when nothing is
    /// actually paused or stopped.
    func appBecameActive() {
        #if os(iOS)
            audioInterrupted = false
            // Starting audio is allowed again: restore a keepalive that was
            // dropped by a mute (or refused while backgrounded), or the rest
            // of the conversation runs without the issue #31 guard. No-ops
            // when one is already open.
            if !voiceState.muted { startAudioKeepalive() }
            capture.ensureRunning()
            resumeIfUnprompted()
        #endif
    }

    #if os(iOS)
        private func startAudioKeepalive() {
            guard keepaliveStreamID == nil,
                let opened = try? capture.openStream()
            else { return }
            keepaliveStreamID = opened.id
            keepaliveDrain = Task.detached {
                for await _ in opened.stream {}  // discard; consumers decide what's heard
            }
        }

        /// Mute has to stop the microphone, not just discard its samples.
        /// The engine's own mute cancels the recorder and the barge monitor,
        /// but the keepalive stream above holds the capture engine and the
        /// `.playAndRecord` session open for the whole conversation — so
        /// without this the hardware mic and the system privacy indicator
        /// stay live behind a UI that says "Muted".
        ///
        /// Tradeoff: dropping the keepalive gives up the issue #31 guarantee
        /// for as long as the mute lasts, so unmuting from the Live Activity
        /// while backgrounded can no longer start the mic immediately — iOS
        /// refuses to START audio there. That refusal is already modelled:
        /// the engine parks and `appBecameActive()` re-arms on foreground.
        /// Holding the mic open through a mute is the worse of the two.
        private func applyMuteToCapture(muted: Bool) {
            if muted {
                stopAudioKeepalive()
            } else {
                startAudioKeepalive()
            }
        }

        private func stopAudioKeepalive() {
            if let keepaliveStreamID {
                capture.closeStream(keepaliveStreamID)
                self.keepaliveStreamID = nil
            }
            keepaliveDrain?.cancel()
            keepaliveDrain = nil
        }

        /// Pause the loop for the interruption's duration; the capture
        /// service separately rebuilds its engine on the ended signal.
        private func observeAudioInterruptions() {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil, queue: .main
            ) { notification in
                guard
                    let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                        as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: raw)
                else { return }
                MainActor.assumeIsolated {
                    AppModel.shared.conversation?.audioInterruption(began: type == .began)
                }
            }

            let watcher = CallEndWatcher {
                MainActor.assumeIsolated {
                    AppModel.shared.conversation?.systemCallsEnded()
                }
            }
            let observer = CXCallObserver()
            observer.setDelegate(watcher, queue: .main)
            callObserver = observer
            callObserverDelegate = watcher
        }

        /// Every system call is over — the reliable stand-in for the
        /// unreliable interruption `.ended`. Same recovery as foregrounding.
        private func systemCallsEnded() {
            audioInterrupted = false
            capture.ensureRunning()
            resumeIfUnprompted()
        }

        private func audioInterruption(began: Bool) {
            audioInterrupted = began
            if began {
                Task { await engine?.setPaused(true) }
            } else {
                resumeIfUnprompted()
            }
        }
    #endif

    private func agentChanged() async {
        await engine?.agentStateChanged()
        let caption = await tracker.visibleAssistantText
        assistantCaption = String(caption.suffix(600))
    }

    // MARK: Gateway events

    /// Replay-contract state: the last `seq` observed for the runtime
    /// session, and the `replay_epoch` its numbering belongs to. Both reset
    /// whenever the runtime session identity changes.
    private var lastSeenSeq: Int?
    private var replayEpoch: String?
    /// While a reconnect-resume is deciding between event replay and a tracker
    /// reset, live events are parked here so replayed frames can't interleave
    /// out of order with them; the seq gate dedups any overlap on drain.
    private var holdingEvents = false
    private var heldEvents: [GatewayEvent] = []

    /// Called by AppModel's pump for every gateway event.
    func handle(event: GatewayEvent) {
        // Session-scoped events only, except title/info which some backends
        // emit with the stored id.
        let ours =
            event.sessionID == nil
            || event.sessionID == sessionBox.runtimeID
            || event.sessionID == sessionBox.storedID
        guard ours else { return }

        if holdingEvents {
            heldEvents.append(event)
            return
        }
        apply(event)
    }

    private func drainHeldEvents() {
        holdingEvents = false
        let held = heldEvents
        heldEvents = []
        for event in held { apply(event) }
    }

    private func apply(_ event: GatewayEvent) {
        // Seq gate (runtime-session events only — that's the id the replay
        // ring is keyed by): drop anything at or below the watermark, so a
        // replay batch overlapping the live stream can't double-apply deltas.
        if let seq = event.seq, event.sessionID == sessionBox.runtimeID {
            if let last = lastSeenSeq, seq <= last { return }
            lastSeenSeq = seq
        }

        switch event.type {
        case GatewayEvent.Kind.messageStart,
            GatewayEvent.Kind.messageDelta,
            GatewayEvent.Kind.messageInterim,
            GatewayEvent.Kind.messageComplete,
            GatewayEvent.Kind.error:
            trackerEventContinuation?.yield(event)
            if event.type == GatewayEvent.Kind.messageComplete {
                appendDevMessage(
                    role: "assistant", text: event.payload["text"]?.stringValue ?? "")
                toolTicker = nil
                // End-of-turn usage is authoritative; the server guarantees no
                // stale session.usage tick lands after this event.
                if let complete = event.payload["usage"].flatMap(SessionUsage.init(json:)) {
                    usage = complete
                }
            }

        case GatewayEvent.Kind.sessionUsage:
            if let tick = event.payload["usage"].flatMap(SessionUsage.init(json:)) {
                usage = tick
            }

        case GatewayEvent.Kind.toolStart:
            let name = event.payload["name"]?.stringValue ?? "tool"
            toolTicker = "Running: \(name)…"

        case GatewayEvent.Kind.toolComplete:
            toolTicker = nil

        case GatewayEvent.Kind.approvalRequest:
            if let request = ApprovalRequest(event: event) {
                present(approval: request)
            }

        case GatewayEvent.Kind.clarifyRequest:
            if let request = ClarifyRequest(event: event) {
                present(clarify: request)
            }

        case GatewayEvent.Kind.clarifyExpire:
            if clarify?.requestID == event.payload["request_id"]?.stringValue {
                clarify = nil
                promptSendError = nil
                resumeIfUnprompted()
            }

        case GatewayEvent.Kind.sessionTitle:
            sessionTitle =
                event.payload["title"]?.stringValue
                ?? event.payload["text"]?.stringValue ?? sessionTitle

        case GatewayEvent.Kind.sessionInfo:
            // Ignore lazy placeholders; adopt real info fields.
            if event.payload["lazy"]?.truthy != true {
                if let title = event.payload["title"]?.stringValue, !title.isEmpty {
                    sessionTitle = title
                }
                if let project = event.payload["project"]?["name"]?.stringValue {
                    projectName = project
                }
                if let profile = event.payload["profile_name"]?.stringValue, !profile.isEmpty {
                    profileName = profile
                }
            }

        case GatewayEvent.Kind.sessionResumeProgress:
            switch event.payload["status"]?.stringValue {
            case "complete":
                if notice == Self.hydrationNotice { notice = nil }
            case "failed":
                // The gateway discards the session on hydration failure; the
                // setup-error alert offers the way back to the session list.
                setupError =
                    event.payload["message"]?.stringValue
                    ?? "Resuming the session's history failed."
            default:
                break  // "loading" — the resume handle already set the notice
            }

        case GatewayEvent.Kind.notificationShow:
            notice = event.payload["text"]?.stringValue ?? event.payload["message"]?.stringValue

        case GatewayEvent.Kind.sessionReclaimed:
            // Broadcast (no session_id on the frame): the server reaped a
            // session out from under its client — idle TTL, LRU cap, or the
            // WS-orphan reap. Without this, the next prompt just fails
            // against an id the backend has forgotten.
            let runtime = event.payload["session_id"]?.stringValue
            let stored = event.payload["stored_session_id"]?.stringValue
            let isOurs =
                (runtime != nil && runtime == sessionBox.runtimeID)
                || (stored != nil && stored == sessionBox.storedID)
            if isOurs {
                let reason = event.payload["reason"]?.stringValue ?? "reclaimed"
                setupError =
                    "The backend reclaimed this session (\(reason)). Go back and resume it to continue."
            }

        default:
            break
        }
    }

    /// Bumped each time an approval sheet is presented. Approvals are
    /// session-keyed (no request_id), so a late confirmation for A must not
    /// dismiss B (issue #39).
    private var approvalEpoch = 0

    private func present(approval request: ApprovalRequest) {
        approvalEpoch += 1
        approval = request
        promptSendError = nil
        Task {
            await engine?.setPaused(true)
            _ = await speech.playFallback(
                text: "Hermes is asking for approval to run a command.")
        }
    }

    private func present(clarify request: ClarifyRequest) {
        clarify = request
        promptSendError = nil
        Task {
            await engine?.setPaused(true)
            _ = await speech.playFallback(text: "Hermes has a question for you.")
        }
    }

    /// Adopt the `pending_approval` / `pending_clarify` replay fields of a
    /// `session.resume` result: a prompt that arrived while this client was
    /// detached would otherwise never be seen — the agent thread stays parked
    /// on it until timeout. On a re-resume (`clearStale`), the registry is
    /// authoritative the other way too: an absent field means the prompt was
    /// answered elsewhere, expired, or died with the backend, so the stale
    /// sheet is cleared and listening resumes.
    private func adoptPendingPrompts(from handle: SessionHandle, clearStale: Bool) {
        if let payload = handle.raw["pending_approval"],
            let request = ApprovalRequest(payload: payload, sessionID: handle.runtimeID)
        {
            present(approval: request)
        } else if clearStale, approval != nil {
            // Invalidate error ownership too: a late failure for A must not
            // write into the next sheet (clarify B) via the shared footer.
            approval = nil
            approvalEpoch += 1
        }

        if let payload = handle.raw["pending_clarify"],
            let request = ClarifyRequest(payload: payload, sessionID: handle.runtimeID)
        {
            present(clarify: request)
        } else if clearStale, clarify != nil {
            clarify = nil
        }

        if clearStale { resumeIfUnprompted() }
    }

    /// After a reconnect, re-resume by stored id. When the gateway kept the
    /// session alive (same runtime id back, same replay epoch), the missed
    /// events are replayed through `session.events.since` so a reply that
    /// streamed while we were away is spoken from where it left off; anything
    /// else (cold resume, backend restart, replay ring overrun, old backend)
    /// falls back to the tracker reset.
    func connectionBecameReady(isReconnect: Bool) async {
        guard !isTornDown else { return }
        connectionHealthy = true
        guard isReconnect else { return }
        guard let storedID = sessionBox.storedID else { return }
        let previousRuntimeID = sessionBox.runtimeID
        let previousEpoch = replayEpoch
        let watermark = lastSeenSeq
        holdingEvents = true
        defer {
            if isTornDown {
                holdingEvents = false
                heldEvents.removeAll()
            } else {
                drainHeldEvents()
            }
        }
        do {
            let handle = try await connection.resumeSession(
                storedID: storedID, profile: profile)
            guard !isTornDown else {
                // Teardown owns the old runtime; consume it only if it has
                // not already been closed. A cold resume returned a new
                // runtime that teardown never saw, so close it directly.
                if handle.runtimeID == previousRuntimeID {
                    await closeSessionIfOpen()
                } else {
                    await connection.closeSession(sessionID: handle.runtimeID)
                }
                return
            }
            self.handle = handle
            sessionBox.runtimeID = handle.runtimeID
            sessionBox.storedID = handle.storedID
            let currentEpoch = await connection.replayEpoch
            guard !isTornDown else {
                await closeSessionIfOpen()
                return
            }
            replayEpoch = currentEpoch
            let replayed = await replayMissedEvents(
                handle: handle,
                previousRuntimeID: previousRuntimeID,
                previousEpoch: previousEpoch,
                watermark: watermark)
            guard !isTornDown else {
                await closeSessionIfOpen()
                return
            }
            if !replayed {
                lastSeenSeq = nil
                let running = handle.raw["running"]?.truthy ?? false
                await tracker.reset(busy: running)
                guard !isTornDown else {
                    await closeSessionIfOpen()
                    return
                }
            }
            adoptPendingPrompts(from: handle, clearStale: true)
            notice = "Reconnected."
            noteHydration(from: handle)
        } catch {
            guard !isTornDown else { return }
            setupError = "Reconnected, but resuming the session failed: \(error.localizedDescription)"
        }
    }

    /// Lossless-reconnect attempt. True only when every gap-safety check
    /// passes AND the buffered frames were applied — the caller then skips
    /// the tracker reset because the replay reconstructs the exact state.
    private func replayMissedEvents(
        handle: SessionHandle,
        previousRuntimeID: String?,
        previousEpoch: String?,
        watermark: Int?
    ) async -> Bool {
        guard let watermark, let previousEpoch,
            handle.runtimeID == previousRuntimeID,
            await connection.replayEpoch == previousEpoch,
            !isTornDown
        else { return false }
        guard
            let batch = try? await connection.eventsSince(
                sessionID: handle.runtimeID, lastSeen: watermark),
            !isTornDown,
            !batch.truncated,
            batch.epoch == nil || batch.epoch == previousEpoch
        else { return false }
        for event in batch.events { apply(event) }
        return true
    }

    func connectionLost() {
        connectionHealthy = false
    }

    // MARK: User controls

    func toggleMute() {
        Task { await engine?.toggleMute() }
    }

    func endTurnNow() {
        Task { await engine?.stopTurnNow() }
    }

    func stopSpeech() {
        Task { await engine?.stopSpeech() }
    }

    /// The Listen button doubles as the manual escape hatch from a stranded
    /// interruption pause (a phone call whose `.ended` never arrived): clear
    /// the interruption state, revive the capture engine if the system
    /// killed it, unpause, and re-arm.
    func listenNow() {
        #if os(iOS)
            audioInterrupted = false
            parkedForBackground = false
            capture.ensureRunning()
        #endif
        Task {
            guard let engine else { return }
            if approval == nil, clarify == nil {
                await engine.setPaused(false)
            }
            await engine.listenNow()
        }
    }

    /// The backend stays blocked until a prompt response actually arrives, so
    /// the prompt is kept (and the sheet stays up) until the RPC confirms —
    /// a transient send failure surfaces in the sheet and the same request
    /// can be retried (issue #40). While a send is in flight this flag blocks
    /// duplicate submissions, which the old clear-before-send did implicitly.
    private(set) var promptResponseInFlight = false
    /// Non-nil after a response failed to send; shown inside the prompt sheet.
    private(set) var promptSendError: String?

    func respondApproval(choice: String) {
        guard let request = approval, !promptResponseInFlight else { return }
        let epoch = approvalEpoch
        sendPromptResponse {
            try await $0.respondApproval(sessionID: request.sessionID, choice: choice)
        } onConfirmed: { [weak self] in
            guard let self, self.approvalEpoch == epoch else { return }
            self.approval = nil
        } applyError: { [weak self] in
            guard let self else { return false }
            return self.approval != nil && self.approvalEpoch == epoch
        }
    }

    func respondClarify(answer: String) {
        guard let request = clarify, !promptResponseInFlight else { return }
        let requestID = request.requestID
        sendPromptResponse {
            try await $0.respondClarify(requestID: requestID, answer: answer)
        } onConfirmed: { [weak self] in
            guard let self, self.clarify?.requestID == requestID else { return }
            self.clarify = nil
        } applyError: { [weak self] in
            self?.clarify?.requestID == requestID
        }
    }

    private func sendPromptResponse(
        _ send: @escaping (HermesConnection) async throws -> Void,
        onConfirmed: @escaping @MainActor () -> Void,
        applyError: @escaping @MainActor () -> Bool
    ) {
        promptResponseInFlight = true
        promptSendError = nil
        Task {
            defer { promptResponseInFlight = false }
            do {
                try await send(connection)
                onConfirmed()
                if applyError() { promptSendError = nil }
                resumeIfUnprompted()
            } catch {
                guard applyError() else { return }
                promptSendError =
                    (error as? HermesError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func resumeIfUnprompted() {
        guard approval == nil, clarify == nil else { return }
        #if os(iOS)
            guard !audioInterrupted else { return }
            parkedForBackground = false
        #endif
        Task { await engine?.setPaused(false) }
    }

    func clearNotice() {
        notice = nil
    }

    /// Show an out-of-band notice from outside the engine (the Live
    /// Activity controller reports a failed request this way).
    func showNotice(_ message: String) {
        notice = message
    }

    /// Try the microphone again after a permission denial (the user may
    /// have flipped the switch in system settings). `start()` clears the
    /// denied state and re-runs the permission check before arming.
    func retryMicrophone() {
        Task { await engine?.start() }
    }

    func clearSetupError() {
        setupError = nil
    }

    // MARK: Dev text path

    func submitTextPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appendDevMessage(role: "user", text: trimmed)
        Task {
            try? await tracker.submit(text: trimmed, interrupted: false)
        }
    }

    private func appendDevMessage(role: String, text: String) {
        guard !text.isEmpty else { return }
        devMessages.append(DevMessage(role: role, text: text))
        if devMessages.count > 100 { devMessages.removeFirst(devMessages.count - 100) }
    }
}

#if os(iOS)
    /// CXCallObserver delegate reporting the moment no system call remains
    /// (phone, FaceTime, or VoIP). Observation-only CallKit — review-safe,
    /// no entitlement. Delegate callbacks arrive on the queue given to
    /// setDelegate (main).
    private final class CallEndWatcher: NSObject, CXCallObserverDelegate {
        private let onAllCallsEnded: () -> Void

        init(onAllCallsEnded: @escaping () -> Void) {
            self.onAllCallsEnded = onAllCallsEnded
        }

        func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
            guard call.hasEnded, callObserver.calls.allSatisfy(\.hasEnded) else { return }
            onAllCallsEnded()
        }
    }
#endif
