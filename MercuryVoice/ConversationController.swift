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

    /// The hardware-facing engine inputs, grouped behind one seam so an
    /// app-level test can drive the real `begin()` — session open, the
    /// torn-down interleaving, and `startVoiceLoop` itself — without arming
    /// the microphone (issue #77). Production passes nil and gets
    /// `liveAudioStack()`, which is the construction `startVoiceLoop` used
    /// inline before; the engine, its callbacks and its clock are the same on
    /// both paths.
    struct AudioStack {
        var recorder: any VoiceRecording
        var bargeMonitor: any BargeMonitoring
        var transcriber: any Transcribing
        var microphone: any MicrophoneAuthorizing
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
    /// Session RPCs, seamed for the reconnect-ordering tests. Defaults to
    /// `connection`; nothing else about the connection is abstracted.
    private let sessionService: any SessionServicing
    /// Replaces the microphone/transcription half of the engine under test.
    /// nil in production: `startVoiceLoop` builds the live stack.
    private let audio: AudioStack?
    private let profile: String?
    private var handle: SessionHandle?
    private var mode: Mode?

    private let tracker: AgentTurnTracker
    private var engine: ConversationEngine<ContinuousClock>?
    private let speech: any SpeechPlaying
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
        private(set) var audioInterrupted = false
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

    init(
        connection: HermesConnection,
        profile: String?,
        sessionService: (any SessionServicing)? = nil,
        speech: (any SpeechPlaying)? = nil,
        audio: AudioStack? = nil
    ) {
        self.connection = connection
        self.sessionService = sessionService ?? connection
        self.audio = audio
        self.profile = profile
        self.profileName = profile
        // One client-direct voice-config cache per conversation: STT and TTS
        // share the fetch, and its keys die with the controller (memory only).
        let voiceStore = VoiceConfigStore(rest: connection.rest, profile: profile)
        self.voiceStore = voiceStore
        self.speech =
            speech
            ?? HermesSpeechOutput(
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

    /// True once this controller has been dropped. begin() re-checks it after
    /// every suspension point: the conversation can be ended (issue #38) or
    /// superseded by a newer launch (issue #77) while session opening is
    /// still in flight, and nothing may start after that — the drop happened
    /// against a controller with no engine or session yet, so a resumed
    /// begin() would otherwise arm the mic and hold a backend session that
    /// nobody can reach anymore.
    private var isTornDown = false

    /// Drop this controller *synchronously*, without waiting for the async
    /// teardown below. `AppModel` calls this the moment a newer launch (or
    /// the end button) takes ownership, so a `begin()` suspended inside
    /// `session.create`/`session.resume` bails at its next resume rather than
    /// opening its engine — the flag has to be set before the caller's first
    /// await, which a `Task { await teardown() }` cannot promise. Every
    /// caller still follows with `teardown()` to end the engine and close the
    /// session (issue #77).
    func supersede() { isTornDown = true }

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

    func openSession(mode: Mode) async throws {
        let handle: SessionHandle
        switch mode {
        case .create(let cwd, let title):
            handle = try await sessionService.createSession(
                cwd: cwd, profile: profile, title: title)
        case .resume(let storedID):
            handle = try await sessionService.resumeSession(storedID: storedID, profile: profile)
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
        replayEpoch = await sessionService.replayEpoch
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

    // MARK: Shared capture level meter

    /// The controller that currently owns the shared mic-level meter.
    ///
    /// `AudioCaptureService.shared.setLevelHandler` is process-global and
    /// last-writer-wins, and a superseded controller's `teardown()` is
    /// asynchronous — so an unconditional clear there can in principle land
    /// after the replacement has already installed its handler and leave the
    /// live conversation's meter dead. The launch path happens to enqueue the
    /// outgoing teardown before the replacement can install, but that is
    /// scheduler behaviour, not a contract, so ownership is checked rather
    /// than assumed (issue #77).
    ///
    /// One isolation boundary: this static and both operations below are
    /// main-actor state on a `@MainActor` type, and every install and clear in
    /// the app goes through them, so no ordering between two teardowns can
    /// take the meter from its owner.
    ///
    /// Weak: the owner is always the controller `AppModel.conversation` holds,
    /// and that is only released after a teardown which clears this, so it does
    /// not dangle in practice — weak just guarantees the static can never keep
    /// a dead controller alive.
    private(set) static weak var levelMeterOwner: ConversationController?

    private func takeLevelMeter() {
        Self.levelMeterOwner = self
        capture.setLevelHandler { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }
    }

    /// Clear the shared meter only while this controller still owns it. A
    /// superseded controller reaching here after the replacement installed
    /// must leave the replacement's handler alone.
    private func releaseLevelMeterIfOwned() {
        guard Self.levelMeterOwner === self else { return }
        Self.levelMeterOwner = nil
        capture.setLevelHandler(nil)
    }

    /// The production audio stack: the shared capture service's recorder and
    /// barge monitor, REST transcription, and the system permission.
    private func liveAudioStack() -> AudioStack {
        AudioStack(
            recorder: MicRecorder(capture: capture),
            bargeMonitor: BargeInMonitor(capture: capture),
            transcriber: RestTranscriber(
                rest: connection.rest, profile: profile, voiceConfig: voiceStore),
            microphone: SystemMicrophoneAuthorization())
    }

    private func startVoiceLoop() async {
        let audio = self.audio ?? liveAudioStack()
        let engine = ConversationEngine(
            recorder: audio.recorder,
            bargeMonitor: audio.bargeMonitor,
            transcriber: audio.transcriber,
            speech: speech,
            agent: tracker,
            microphone: audio.microphone,
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
        takeLevelMeter()
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
        supersede()
        trackerEventContinuation?.finish()
        trackerEventPump?.cancel()
        stateTask?.cancel()
        captionTask?.cancel()
        releaseLevelMeterIfOwned()
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
        await sessionService.closeSession(sessionID: sid)
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
        ///
        /// Both callbacks target `self`, not `AppModel.shared.conversation`.
        /// Every controller installs its own pair in `startVoiceLoop`, so the
        /// live conversation still hears the system exactly once — but a
        /// superseded controller can no longer reach into whatever
        /// conversation is current now. Removing the observers in `teardown()`
        /// is not enough on its own: these are delivered on `OperationQueue`
        /// `.main`, so a callback enqueued before the removal still runs after
        /// it. The `isTornDown` checks in the two handlers are what make that
        /// late delivery inert (issue #77).
        private func observeAudioInterruptions() {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil, queue: .main
            ) { [weak self] notification in
                guard
                    let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                        as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: raw)
                else { return }
                MainActor.assumeIsolated {
                    self?.audioInterruption(began: type == .began)
                }
            }

            let watcher = CallEndWatcher { [weak self] in
                MainActor.assumeIsolated {
                    self?.systemCallsEnded()
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
            guard !isTornDown else { return }
            audioInterrupted = false
            capture.ensureRunning()
            resumeIfUnprompted()
        }

        private func audioInterruption(began: Bool) {
            guard !isTornDown else { return }
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

    /// The event families whose state a post-batch prompt read owns.
    private static let promptFamilyEvents: Set<String> = [
        GatewayEvent.Kind.approvalRequest,
        GatewayEvent.Kind.clarifyRequest,
        GatewayEvent.Kind.clarifyExpire,
    ]

    /// `skippingPromptFamilies` is set while applying a replay batch: the
    /// sheets are decided afterwards by a read that is newer than every frame
    /// in the batch, so re-deciding them here would only flash a prompt (and
    /// speak its announcement) on its way to being overwritten. The frames
    /// still pass the seq gate first, so the watermark advances exactly as if
    /// they had been applied in full.
    private func apply(_ event: GatewayEvent, skippingPromptFamilies: Bool = false) {
        // Seq gate (runtime-session events only — that's the id the replay
        // ring is keyed by): drop anything at or below the watermark, so a
        // replay batch overlapping the live stream can't double-apply deltas.
        if let seq = event.seq, event.sessionID == sessionBox.runtimeID {
            if let last = lastSeenSeq, seq <= last { return }
            lastSeenSeq = seq
        }
        if skippingPromptFamilies, Self.promptFamilyEvents.contains(event.type) { return }

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
        // Idempotent by request id. On a reconnect the same approval can
        // arrive twice — once in the post-batch prompt read and once as the
        // live frame that was held while that read was in flight — and
        // presenting it again would bump `approvalEpoch` (discarding an
        // answer the user may already have sent) and re-speak the
        // announcement. Only a gateway-stamped id establishes sameness: two
        // approvals that both lack one are not assumed to be the same
        // approval, so a backend that does not stamp ids keeps today's
        // behaviour.
        if let requestID = request.requestID, approval?.requestID == requestID { return }
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
        // Idempotent by request id, for the same reason as the approval
        // sheet; clarify requests always carry one.
        if clarify?.requestID == request.requestID { return }
        clarify = request
        promptSendError = nil
        Task {
            await engine?.setPaused(true)
            _ = await speech.playFallback(text: "Hermes has a question for you.")
        }
    }

    /// Adopt the `pending_approval` / `pending_clarify` fields of a
    /// live-session payload: a prompt that arrived while this client was
    /// detached would otherwise never be seen — the agent thread stays parked
    /// on it until timeout. On a re-read (`clearStale`), the registry is
    /// authoritative the other way too: an absent field means the prompt was
    /// answered elsewhere, expired, or died with the backend, so the stale
    /// sheet is cleared and listening resumes.
    ///
    /// Absent is the only "nothing pending" encoding the builder produces
    /// (`if value: payload[key] = value`), so nil here is a real answer and
    /// not a missing one — with the caveat recorded on `LiveSessionSnapshot`
    /// that a backend omitting the fields entirely reads the same way.
    private func adoptPendingPrompts(
        sessionID: String,
        approvalPayload: JSONValue?,
        clarifyPayload: JSONValue?,
        clearStale: Bool
    ) {
        if let approvalPayload,
            let request = ApprovalRequest(payload: approvalPayload, sessionID: sessionID)
        {
            present(approval: request)
        } else if clearStale, approval != nil {
            // Invalidate error ownership too: a late failure for A must not
            // write into the next sheet (clarify B) via the shared footer.
            approval = nil
            approvalEpoch += 1
        }

        if let clarifyPayload,
            let request = ClarifyRequest(payload: clarifyPayload, sessionID: sessionID)
        {
            present(clarify: request)
        } else if clearStale, clarify != nil {
            clarify = nil
        }

        if clearStale { resumeIfUnprompted() }
    }

    /// The `session.resume` snapshot as prompt authority — the first read of
    /// the reconnect, and the only one on any path where the replay is not
    /// usable.
    private func adoptPendingPrompts(from handle: SessionHandle, clearStale: Bool) {
        adoptPendingPrompts(
            sessionID: handle.runtimeID,
            approvalPayload: handle.raw["pending_approval"],
            clarifyPayload: handle.raw["pending_clarify"],
            clearStale: clearStale)
    }

    /// The post-batch `session.activate` read as prompt authority. Its
    /// payload is used for the sheets and nothing else: the session handle,
    /// the hydration notice and the busy flag all stay owned by the resume.
    private func adoptPendingPrompts(from snapshot: LiveSessionSnapshot, clearStale: Bool) {
        adoptPendingPrompts(
            sessionID: snapshot.runtimeID,
            approvalPayload: snapshot.pendingApproval,
            clarifyPayload: snapshot.pendingClarify,
            clearStale: clearStale)
    }

    /// After a reconnect, re-resume by stored id. When the gateway kept the
    /// session alive (same runtime id back, same replay epoch), the missed
    /// events are replayed through `session.events.since` so a reply that
    /// streamed while we were away is spoken from where it left off; anything
    /// else (cold resume, backend restart, replay ring overrun, old backend)
    /// falls back to the tracker reset.
    ///
    /// ## Read order (issue #75)
    ///
    /// The prompt sheets are decided by a read taken *after* the replay
    /// batch, not by the resume snapshot the batch is newer than. The
    /// original bug was the reverse order: the resume snapshot was
    /// reconciled after every replayed frame had been applied, so the older
    /// fact won — a question raised during the outage was cleared as "no
    /// longer pending", and one answered during it was put back on screen.
    ///
    /// Reordering rather than merging is deliberate. The snapshot carries
    /// resolutions but no seq, the frames carry seq but never a resolution
    /// (nothing is emitted when an approval or clarify is answered), so the
    /// two cannot be placed on one axis at all; taking the last read as the
    /// whole answer needs no ordering rule.
    ///
    /// The batch is fetched before that read but applied only after it
    /// succeeds, so a failure leaves the watermark and every sheet exactly
    /// where the un-replayed path would have them.
    ///
    /// **Known residual, tracked separately.** A prompt whose frame is
    /// emitted before the read and resolved by another client before the
    /// read still resurrects: the frame is held, drains after the sheets are
    /// adopted, and no resolution frame exists to clear it. That is the
    /// silent-resolution defect, and it reproduces with no reconnect at all —
    /// a continuously connected client shows the same dead sheet from the
    /// same server history. It needs `approval.resolved` / `clarify.resolved`
    /// on the gateway, and no read order can substitute for them.
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
            let handle = try await sessionService.resumeSession(
                storedID: storedID, profile: profile)
            guard !isTornDown else {
                // Teardown owns the old runtime; consume it only if it has
                // not already been closed. A cold resume returned a new
                // runtime that teardown never saw, so close it directly.
                if handle.runtimeID == previousRuntimeID {
                    await closeSessionIfOpen()
                } else {
                    await sessionService.closeSession(sessionID: handle.runtimeID)
                }
                return
            }
            self.handle = handle
            sessionBox.runtimeID = handle.runtimeID
            sessionBox.storedID = handle.storedID
            let currentEpoch = await sessionService.replayEpoch
            guard !isTornDown else {
                await closeSessionIfOpen()
                return
            }
            replayEpoch = currentEpoch

            // Nothing below touches applied state until both reads are in.
            let batch = await fetchMissedEvents(
                handle: handle,
                previousRuntimeID: previousRuntimeID,
                previousEpoch: previousEpoch,
                watermark: watermark)
            guard !isTornDown else {
                await closeSessionIfOpen()
                return
            }
            let prompts =
                batch == nil
                ? nil
                : await readPromptState(handle: handle, previousEpoch: previousEpoch)
            guard !isTornDown else {
                await closeSessionIfOpen()
                return
            }

            if let batch, let prompts {
                for event in batch { apply(event, skippingPromptFamilies: true) }
                adoptPendingPrompts(from: prompts, clearStale: true)
            } else {
                // No usable replay: the batch (if one was fetched) is
                // discarded unapplied, so the watermark never advanced past
                // it and no prompt frame in it was seen. Dropping the
                // watermark is what makes the drain safe — a restarted
                // backend numbers from 1 again, and a retained watermark
                // would swallow every frame after it.
                lastSeenSeq = nil
                let running = handle.raw["running"]?.truthy ?? false
                await tracker.reset(busy: running)
                guard !isTornDown else {
                    await closeSessionIfOpen()
                    return
                }
                adoptPendingPrompts(from: handle, clearStale: true)
            }
            notice = "Reconnected."
            noteHydration(from: handle)
        } catch {
            guard !isTornDown else { return }
            setupError = "Reconnected, but resuming the session failed: \(error.localizedDescription)"
        }
    }

    /// Fetch the frames missed during the outage, or nil when a lossless
    /// replay is not available (no watermark, a recycled runtime id, a
    /// changed replay epoch, a backend without the method, or a batch that
    /// overran the ring). Applies nothing: the caller decides that after the
    /// prompt read, so a fetch that turns out to be unusable costs one
    /// discarded round trip and no state.
    private func fetchMissedEvents(
        handle: SessionHandle,
        previousRuntimeID: String?,
        previousEpoch: String?,
        watermark: Int?
    ) async -> [GatewayEvent]? {
        guard let watermark, let previousEpoch,
            handle.runtimeID == previousRuntimeID,
            await sessionService.replayEpoch == previousEpoch,
            !isTornDown
        else { return nil }
        guard
            let batch = try? await sessionService.eventsSince(
                sessionID: handle.runtimeID, lastSeen: watermark),
            !isTornDown,
            !batch.truncated,
            batch.epoch == nil || batch.epoch == previousEpoch
        else { return nil }
        return batch.events
    }

    /// Re-read the prompt registry after the batch, and validate that it
    /// describes the same session the batch was fetched for.
    ///
    /// `session.activate` resolves a live runtime id only, so a session that
    /// went away answers 4001 and lands here as nil. The identity check
    /// closes the case a live answer cannot: a runtime id reaped and reminted
    /// inside one process would answer for a different session, and applying
    /// the earlier runtime's batch to it would be a gap, not a replay. The
    /// epoch is re-read afterwards for the same reason — nothing may be
    /// applied across a restart the fetch-time checks could not see.
    ///
    /// nil for any of it (including a backend without the method) means the
    /// batch is discarded and the caller takes the un-replayed path.
    private func readPromptState(
        handle: SessionHandle, previousEpoch: String?
    ) async -> LiveSessionSnapshot? {
        guard
            let snapshot = try? await sessionService.activateSession(
                sessionID: handle.runtimeID),
            !isTornDown,
            snapshot.describesSameSession(as: handle)
        else { return nil }
        guard await sessionService.replayEpoch == previousEpoch, !isTornDown else { return nil }
        return snapshot
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
