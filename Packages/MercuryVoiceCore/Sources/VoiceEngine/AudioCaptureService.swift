import AVFoundation
import Foundation

public struct AudioChunk: Sendable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

/// Normalized level math shared by the recorder, barge monitor, and UI meter.
///
/// The desktop computes RMS over 8-bit-centered samples with `min(1, rms/42)`;
/// over float samples the equivalent divisor is 42/128, so conversational
/// speech lands around 0.1–0.4 and the shared 0.075 threshold works unchanged.
public enum AudioLevel {
    public static func normalizedRMS(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples { sum += Double(sample) * Double(sample) }
        let rms = (sum / Double(samples.count)).squareRoot()
        return min(1, rms / VoiceConstants.rmsNormalizationDivisor)
    }
}

/// Capture consumer API used by the recorder and barge monitor. Extracted so
/// tests can inject a fake without starting `AVAudioEngine`.
protocol AudioCaptureStreaming: Sendable {
    func openStream() throws -> (id: UUID, stream: AsyncStream<AudioChunk>)
    func closeStream(_ id: UUID)
}

/// The only things the capture lifecycle does with a built engine. Abstracted
/// so the publish/discard ordering can be exercised without starting real
/// hardware (issue #64); in production this is always `AVAudioEngine`.
protocol CaptureEngine: AnyObject {
    var isRunning: Bool { get }
    /// Remove the input tap and stop.
    func stopCapture()
}

extension AVAudioEngine: CaptureEngine {
    func stopCapture() {
        inputNode.removeTap(onBus: 0)
        stop()
    }
}

/// Builds a capture engine on the current input route and starts it, tapping
/// buffers to `onBuffer`. Everything hardware lives behind this; whether the
/// result is published is decided separately, under the lock.
typealias CaptureEngineFactory =
    @Sendable (_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws -> CaptureEngine

/// One shared microphone: an AVAudioEngine input tap broadcasting mono float
/// chunks to any number of consumers (the recorder while listening, the barge
/// monitor while thinking/speaking — never both at once, but the service
/// doesn't care). The engine runs only while consumers exist.
public final class AudioCaptureService: AudioCaptureStreaming, @unchecked Sendable {
    public static let shared = AudioCaptureService()

    private let lock = NSLock()
    private var engine: CaptureEngine?
    private var streams: [UUID: AsyncStream<AudioChunk>.Continuation] = [:]
    private var levelHandler: (@Sendable (Double) -> Void)?
    private let makeEngine: CaptureEngineFactory
    /// Advances on every rebuild request. An engine is built outside the
    /// lock, so it compares this against the value it started with and
    /// discards itself rather than publishing onto a route that has already
    /// been superseded (issue #64).
    private var generation: UInt64 = 0
    /// A build is between its claim and its publish-or-discard. `building` and
    /// a non-nil `engine` are mutually exclusive.
    private var building = false
    #if os(iOS)
        // Input port UID the running engine was built on, to detect real
        // input switches among the route-change noise.
        private var engineInputUID: String?
    #endif

    public convenience init() {
        self.init(makeEngine: AudioCaptureService.startLiveEngine)
    }

    init(makeEngine: @escaping CaptureEngineFactory) {
        self.makeEngine = makeEngine
        #if os(iOS)
            // The input route moves when a device appears/vanishes (e.g. a
            // Bluetooth headset) or when the user picks another mic
            // (`setPreferredInput` applies asynchronously, announced as
            // `.routeConfigurationChange`). The running tap keeps the old
            // device and format unless the engine is rebuilt on the new
            // route — but only rebuild when the input port actually changed:
            // enabling voice processing at engine start emits route churn of
            // its own, and restarting on that would loop.
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil, queue: nil
            ) { [weak self] notification in
                guard
                    let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
                        as? UInt,
                    let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                    reason == .newDeviceAvailable || reason == .oldDeviceUnavailable
                        || reason == .override || reason == .routeConfigurationChange
                else { return }
                self?.restartIfInputRouteChanged()
            }
            // An interruption (call, Siri, another app's session) stops the
            // running engine silently — the object survives but no audio
            // flows (issue #31). Rebuild for the attached consumers when the
            // interruption ends; if the rebuild is refused (still
            // backgrounded), the streams finish and consumers end their
            // turn instead of hanging on a dead mic.
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil, queue: nil
            ) { [weak self] notification in
                guard
                    let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                        as? UInt,
                    AVAudioSession.InterruptionType(rawValue: raw) == .ended
                else { return }
                self?.restartEngineIfRunning()
            }
        #endif
    }

    #if os(iOS)
        /// Known limitation (issue #64): the `engine != nil` guard is false for
        /// the whole of a build, so a real input switch that lands inside one
        /// is not seen here and does not supersede it. `reconfigure()`,
        /// `ensureRunning()` and the interruption observer all reach
        /// `restartEngineIfRunning()` and advance the generation whether or not
        /// an engine is published; this path does not. The build then publishes
        /// on the old route while `engineInputUID` records the *new* one, read
        /// after the engine started, so the next notification sees no change.
        /// Base behaves identically. Loosening the guard would reintroduce the
        /// voice-processing route churn described above, so it needs its own
        /// reproduction and design rather than a change here.
        private func restartIfInputRouteChanged() {
            let currentUID = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
            lock.lock()
            let changed = engine != nil && engineInputUID != currentUID
            lock.unlock()
            if changed { restartEngineIfRunning() }
        }
    #endif

    /// Live input level for the UI meter — set/cleared by the app.
    public func setLevelHandler(_ handler: (@Sendable (Double) -> Void)?) {
        lock.lock()
        levelHandler = handler
        lock.unlock()
    }

    /// Open a consumer stream, starting the engine if needed.
    public func openStream() throws -> (id: UUID, stream: AsyncStream<AudioChunk>) {
        let id = UUID()
        var continuation: AsyncStream<AudioChunk>.Continuation!
        let stream = AsyncStream<AudioChunk>(bufferingPolicy: .bufferingNewest(64)) {
            continuation = $0
        }

        lock.lock()
        streams[id] = continuation
        // A build already in flight picks this consumer up; starting a second
        // engine would put two of them on the same microphone.
        let needsStart = engine == nil && !building
        if needsStart { building = true }
        lock.unlock()

        // A failed start finishes every attached stream; the caller that asked
        // for the engine also gets the reason.
        if needsStart { try buildUntilPublished() }
        return (id, stream)
    }

    public func closeStream(_ id: UUID) {
        lock.lock()
        let continuation = streams.removeValue(forKey: id)
        let stopEngine = streams.isEmpty
        let engine = stopEngine ? self.engine : nil
        // A build still in flight sees the empty `streams` at its publication
        // check and discards its engine there; there is nothing to stop here.
        if stopEngine { self.engine = nil }
        lock.unlock()

        continuation?.finish()
        engine?.stopCapture()
    }

    /// The selected input device changed: rebuild a running engine on it.
    /// No-op when idle — the next start picks up the new selection anyway.
    public func reconfigure() {
        restartEngineIfRunning()
    }

    /// Recover from a silently-dead engine: an interruption stops audio I/O
    /// without any promise of an `.ended` notification (issue #31 follow-up).
    /// Rebuilds when the engine object exists but is no longer running;
    /// no-op otherwise. Call on any "the app is usable again" signal.
    public func ensureRunning() {
        lock.lock()
        let engine = self.engine
        lock.unlock()
        guard let engine, !engine.isRunning else { return }
        restartEngineIfRunning()
    }

    /// Tear down and rebuild the engine on the current route, keeping every
    /// consumer stream attached. Consumers see a brief gap and then chunks in
    /// the new route's format (they already track sampleRate per chunk).
    ///
    /// A rebuild arriving while an engine is still being built is not dropped:
    /// it advances the generation, so the build in flight discards the engine
    /// it made for the route that just changed and starts again on the new one.
    private func restartEngineIfRunning() {
        lock.lock()
        let engine = self.engine
        self.engine = nil
        let handledByBuildInFlight = building
        if engine != nil || handledByBuildInFlight { generation &+= 1 }
        if engine != nil { building = true }
        lock.unlock()

        engine?.stopCapture()
        // Idle, or a build already in flight owns the rebuild.
        guard engine != nil else { return }

        // Best-effort: if the new route can't start (e.g. no input mid-swap),
        // the streams are finished so consumers end their turn instead of
        // hanging, and there is no caller here to surface the error to.
        try? buildUntilPublished()
    }

    /// Build engines for the current consumers until one is published or none
    /// is wanted any more.
    ///
    /// Starting hardware can block, so the build runs outside the lock — which
    /// means the state it was started for can move underneath it. The publish
    /// step re-reads that state under the lock and publishes only an engine
    /// that is still the right one: no rebuild may have been requested since
    /// it started, and a consumer must still be attached. Anything else and
    /// the engine is stopped instead, which is what keeps a started
    /// microphone from outliving the consumers that asked for it. Each extra
    /// pass corresponds to an invalidating event that landed during the
    /// previous build.
    ///
    /// The caller claims the build by setting `building` under the lock; this
    /// method always clears it.
    /// - Throws: a *current* build's failure, after finishing every consumer
    ///   stream so callers end their turn instead of waiting on a microphone
    ///   that never starts. A superseded build's failure is not thrown: it is
    ///   reconciled like any other supersession.
    private func buildUntilPublished() throws {
        while true {
            lock.lock()
            let generationAtStart = generation
            let wanted = !streams.isEmpty
            if !wanted { building = false }
            lock.unlock()
            guard wanted else { return }

            let engine: CaptureEngine
            do {
                engine = try makeEngine { [weak self] buffer in
                    self?.deliver(buffer: buffer)
                }
            } catch {
                lock.lock()
                // A failure is evidence about the generation it was building
                // for and about no other. If a rebuild was requested while
                // this one ran, the failure describes a route nobody wants
                // any more: keep the consumers, hold the build claim, and
                // reconcile again -- the same answer the discard path gives a
                // superseded engine that succeeded. Only a failure that is
                // still current ends the attached turns.
                let obsolete = generation != generationAtStart
                let continuations = obsolete ? [] : Array(streams.values)
                if !obsolete {
                    building = false
                    streams.removeAll()
                }
                lock.unlock()

                for continuation in continuations {
                    continuation.finish()
                }
                if obsolete { continue }
                throw error
            }

            #if os(iOS)
                let inputUID = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
            #endif
            lock.lock()
            let publish = generation == generationAtStart && !streams.isEmpty
            if publish {
                self.engine = engine
                building = false
                #if os(iOS)
                    engineInputUID = inputUID
                #endif
            }
            lock.unlock()

            if publish { return }
            engine.stopCapture()
        }
    }

    /// Production build: an `AVAudioEngine` tapping the current input route,
    /// already started and delivering buffers.
    private static func startLiveEngine(
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws -> CaptureEngine {
        #if os(iOS)
            try AudioSessionManager.activateForVoice()
        #endif

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Echo cancellation + noise suppression (mirrors the desktop's
        // getUserMedia constraints). Best-effort — barge-in never trusts it.
        try? input.setVoiceProcessingEnabled(true)

        #if os(macOS)
            // Pin the capture unit to the user-selected mic before the tap
            // format is read; on iOS the session's preferred input routes it.
            MacAudioDevices.applyPreferredInput(to: engine)
        #endif

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MercuryAudioError.noInputDevice
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            onBuffer(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        return engine
    }

    private func deliver(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        let chunk = AudioChunk(samples: samples, sampleRate: buffer.format.sampleRate)

        lock.lock()
        let continuations = Array(streams.values)
        let levelHandler = levelHandler
        lock.unlock()

        for continuation in continuations {
            continuation.yield(chunk)
        }
        levelHandler?(AudioLevel.normalizedRMS(samples))
    }
}

public enum MercuryAudioError: Error, LocalizedError {
    case noInputDevice
    case playbackSetupFailed

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input is available."
        case .playbackSetupFailed: return "Audio playback could not be started."
        }
    }
}
