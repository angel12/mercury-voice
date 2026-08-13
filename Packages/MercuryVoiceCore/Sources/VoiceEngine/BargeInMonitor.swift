import Foundation

/// Full-duplex interrupt monitor: watches the mic during thinking/speaking,
/// trips on sustained speech, and captures the interrupting utterance with
/// pre-roll so the first syllable survives.
public actor BargeInMonitor: BargeMonitoring {
    private let capture: AudioCaptureService

    private var streamID: UUID?
    private var pump: Task<Void, Never>?
    private var suspended = false

    public init(capture: AudioCaptureService = .shared) {
        self.capture = capture
    }

    public func start(
        isPlaying: @escaping @Sendable () async -> Bool,
        onSpeech: @escaping @Sendable () -> Void,
        onUtterance: @escaping @Sendable (RecordedUtterance?) -> Void
    ) async throws {
        await stop()
        suspended = false

        let (id, stream) = try capture.openStream()
        streamID = id
        pump = Task {
            await self.run(
                stream: stream, isPlaying: isPlaying, onSpeech: onSpeech,
                onUtterance: onUtterance)
        }
    }

    public func stop() async {
        detach()
    }

    public func setSuspended(_ newValue: Bool) {
        suspended = newValue
    }

    private func detach() {
        if let id = streamID {
            streamID = nil
            capture.closeStream(id)
        }
        pump?.cancel()
        pump = nil
    }

    private func run(
        stream: AsyncStream<AudioChunk>,
        isPlaying: @escaping @Sendable () async -> Bool,
        onSpeech: @escaping @Sendable () -> Void,
        onUtterance: @escaping @Sendable (RecordedUtterance?) -> Void
    ) async {
        var detector = BargeDetector(utteranceSilence: TurnSilencePreference.duration)
        var preRoll: [Float] = []
        var captured: [Float] = []
        var sampleRate: Double = 48000
        var elapsedSamples = 0
        var tripped = false

        for await chunk in stream {
            if Task.isCancelled { return }
            sampleRate = chunk.sampleRate
            if suspended {
                // Deaf but attached: drop the audio and any half-built
                // capture so nothing heard while muted can ever trip or
                // be delivered.
                detector = BargeDetector(utteranceSilence: TurnSilencePreference.duration)
                preRoll.removeAll()
                captured.removeAll()
                tripped = false
                elapsedSamples += chunk.samples.count
                continue
            }
            let now = Duration.seconds(Double(elapsedSamples) / sampleRate)
            elapsedSamples += chunk.samples.count

            let playing = await isPlaying()
            let level = AudioLevel.normalizedRMS(chunk.samples)
            let verdict = detector.process(level: level, at: now, playing: playing)

            switch verdict {
            case .quiet:
                preRoll.append(contentsOf: chunk.samples)
                // Bounded pre-roll: keep the trailing window only while quiet
                // (trimming mid-speech would lose the onset — the loudness
                // check keeps loud-but-not-yet-tripped audio intact).
                let maxPreRoll = Int(
                    VoiceConstants.bargePreRollRestart.asSeconds * sampleRate)
                if level < VoiceConstants.bargeMinTriggerLevel, preRoll.count > maxPreRoll {
                    preRoll.removeFirst(preRoll.count - maxPreRoll)
                }

            case .tripped:
                tripped = true
                onSpeech()
                captured = preRoll + chunk.samples
                preRoll.removeAll()

            case .capturing:
                captured.append(contentsOf: chunk.samples)

            case .captureEnded:
                captured.append(contentsOf: chunk.samples)
                detach()  // clean up before delivering, like the reference
                let utterance = RecordedUtterance(
                    audio: WAVEncoder.encode(samples: captured, sampleRate: sampleRate),
                    mimeType: WAVEncoder.mimeType,
                    duration: .seconds(Double(captured.count) / sampleRate),
                    heardSpeech: true)
                onUtterance(utterance)
                return
            }
        }

        // Stream ended without an endpoint (external stop): if we had tripped
        // deliver what we have, else vanish silently.
        if tripped, !captured.isEmpty, !Task.isCancelled {
            let utterance = RecordedUtterance(
                audio: WAVEncoder.encode(samples: captured, sampleRate: sampleRate),
                mimeType: WAVEncoder.mimeType,
                duration: .seconds(Double(captured.count) / sampleRate),
                heardSpeech: true)
            onUtterance(utterance)
        }
    }
}
