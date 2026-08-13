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
        self.speech = HermesSpeechOutput(rest: connection.rest, profile: profile)

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
        await tracker.reset(busy: running)
    }

    private func startVoiceLoop() async {
        let engine = ConversationEngine(
            recorder: MicRecorder(capture: capture),
            bargeMonitor: BargeInMonitor(capture: capture),
            transcriber: RestTranscriber(rest: connection.rest, profile: profile),
            speech: speech,
            agent: tracker,
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
                self.voiceState = state
            }
        }
        capture.setLevelHandler { [weak self] level in
            Task { @MainActor in self?.micLevel = level }
        }
        #if os(iOS)
            startAudioKeepalive()
            observeAudioInterruptions()
        #endif

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

    /// Called by AppModel's pump for every gateway event.
    func handle(event: GatewayEvent) {
        // Session-scoped events only, except title/info which some backends
        // emit with the stored id.
        let ours =
            event.sessionID == nil
            || event.sessionID == sessionBox.runtimeID
            || event.sessionID == sessionBox.storedID
        guard ours else { return }

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
            }

        case GatewayEvent.Kind.toolStart:
            let name = event.payload["name"]?.stringValue ?? "tool"
            toolTicker = "Running: \(name)…"

        case GatewayEvent.Kind.toolComplete:
            toolTicker = nil

        case GatewayEvent.Kind.approvalRequest:
            if let request = ApprovalRequest(event: event) {
                approval = request
                Task {
                    await engine?.setPaused(true)
                    _ = await speech.playFallback(
                        text: "Hermes is asking for approval to run a command.")
                }
            }

        case GatewayEvent.Kind.clarifyRequest:
            if let request = ClarifyRequest(event: event) {
                clarify = request
                Task {
                    await engine?.setPaused(true)
                    _ = await speech.playFallback(text: "Hermes has a question for you.")
                }
            }

        case GatewayEvent.Kind.clarifyExpire:
            if clarify?.requestID == event.payload["request_id"]?.stringValue {
                clarify = nil
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

        case GatewayEvent.Kind.notificationShow:
            notice = event.payload["text"]?.stringValue ?? event.payload["message"]?.stringValue

        default:
            break
        }
    }

    /// After a reconnect, runtime ids are dead — re-resume by stored id.
    func connectionBecameReady(isReconnect: Bool) async {
        connectionHealthy = true
        guard isReconnect else { return }
        guard let storedID = sessionBox.storedID else { return }
        do {
            let handle = try await connection.resumeSession(
                storedID: storedID, profile: profile)
            self.handle = handle
            sessionBox.runtimeID = handle.runtimeID
            sessionBox.storedID = handle.storedID
            let running = handle.raw["running"]?.truthy ?? false
            await tracker.reset(busy: running)
            notice = "Reconnected."
        } catch {
            setupError = "Reconnected, but resuming the session failed: \(error.localizedDescription)"
        }
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

    func respondApproval(choice: String) {
        guard let request = approval else { return }
        approval = nil
        Task {
            try? await connection.respondApproval(
                sessionID: request.sessionID, choice: choice)
            resumeIfUnprompted()
        }
    }

    func respondClarify(answer: String) {
        guard let request = clarify else { return }
        clarify = nil
        Task {
            try? await connection.respondClarify(requestID: request.requestID, answer: answer)
            resumeIfUnprompted()
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
