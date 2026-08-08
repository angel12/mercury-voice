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

/// One shared microphone: an AVAudioEngine input tap broadcasting mono float
/// chunks to any number of consumers (the recorder while listening, the barge
/// monitor while thinking/speaking — never both at once, but the service
/// doesn't care). The engine runs only while consumers exist.
public final class AudioCaptureService: @unchecked Sendable {
    public static let shared = AudioCaptureService()

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var streams: [UUID: AsyncStream<AudioChunk>.Continuation] = [:]
    private var levelHandler: (@Sendable (Double) -> Void)?
    #if os(iOS)
        // Input port UID the running engine was built on, to detect real
        // input switches among the route-change noise.
        private var engineInputUID: String?
    #endif

    public init() {
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
        #endif
    }

    #if os(iOS)
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
        let needsStart = engine == nil
        lock.unlock()

        if needsStart {
            do {
                try startEngine()
            } catch {
                closeStream(id)
                throw error
            }
        }
        return (id, stream)
    }

    public func closeStream(_ id: UUID) {
        lock.lock()
        let continuation = streams.removeValue(forKey: id)
        let stopEngine = streams.isEmpty
        let engine = stopEngine ? self.engine : nil
        if stopEngine { self.engine = nil }
        lock.unlock()

        continuation?.finish()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    /// The selected input device changed: rebuild a running engine on it.
    /// No-op when idle — the next start picks up the new selection anyway.
    public func reconfigure() {
        restartEngineIfRunning()
    }

    /// Tear down and rebuild the engine on the current route, keeping every
    /// consumer stream attached. Consumers see a brief gap and then chunks in
    /// the new route's format (they already track sampleRate per chunk).
    private func restartEngineIfRunning() {
        lock.lock()
        let engine = self.engine
        self.engine = nil
        lock.unlock()
        guard let engine else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let hasConsumers = !streams.isEmpty
        lock.unlock()
        guard hasConsumers else { return }
        // Best-effort: if the new route can't start (e.g. no input mid-swap),
        // finish the streams so consumers end their turn instead of hanging.
        do {
            try startEngine()
        } catch {
            lock.lock()
            let continuations = Array(streams.values)
            streams.removeAll()
            lock.unlock()
            for continuation in continuations {
                continuation.finish()
            }
        }
    }

    private func startEngine() throws {
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
            throw HermesAudioError.noInputDevice
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.deliver(buffer: buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        #if os(iOS)
            let inputUID = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
        #endif
        lock.lock()
        // A route-change restart can race openStream's start; keep whichever
        // engine won and discard the loser.
        if self.engine == nil {
            self.engine = engine
            #if os(iOS)
                engineInputUID = inputUID
            #endif
            lock.unlock()
        } else {
            lock.unlock()
            input.removeTap(onBus: 0)
            engine.stop()
        }
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

public enum HermesAudioError: Error, LocalizedError {
    case noInputDevice
    case playbackSetupFailed

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input is available."
        case .playbackSetupFailed: return "Audio playback could not be started."
        }
    }
}
