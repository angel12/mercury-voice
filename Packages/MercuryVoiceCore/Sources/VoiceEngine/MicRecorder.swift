import Foundation

/// Listening-phase recorder: accumulates mic samples, runs the VAD, and
/// encodes the utterance as WAV 16 kHz mono for `/api/audio/transcribe`.
///
/// Time is measured in sample counts (deterministic; no wall-clock races with
/// the audio callback cadence).
public actor MicRecorder: VoiceRecording {
    private let capture: AudioCaptureService

    private var streamID: UUID?
    private var pump: Task<Void, Never>?

    private var samples: [Float] = []
    /// Rate is locked by the first chunk; route-change chunks at other rates
    /// are resampled into it (issue #43). Falls back to 48 kHz only for the
    /// degenerate no-chunks case, where the buffer is empty anyway.
    private var resampler = RateLockedResampler()
    private var sampleRate: Double {
        resampler.sampleRate > 0 ? resampler.sampleRate : 48000
    }
    private var heardSpeech = false
    private var silenceStartedAtSample: Int?
    private var autoStopFired = false
    private var vad = VADParameters()
    private var onAutoStop: (@Sendable () -> Void)?

    public init(capture: AudioCaptureService = .shared) {
        self.capture = capture
    }

    public func start(
        vad: VADParameters, onAutoStop: @escaping @Sendable () -> Void
    ) async throws {
        discard()
        self.vad = vad
        self.onAutoStop = onAutoStop

        let (id, stream) = try capture.openStream()
        streamID = id
        pump = Task {
            for await chunk in stream {
                self.process(chunk)
            }
        }
    }

    public func stop() async -> RecordedUtterance? {
        detach()
        defer { resetBuffers() }
        guard !samples.isEmpty else { return nil }
        let duration = Duration.seconds(Double(samples.count) / sampleRate)
        let wav = WAVEncoder.encode(samples: samples, sampleRate: sampleRate)
        return RecordedUtterance(
            audio: wav,
            mimeType: WAVEncoder.mimeType,
            duration: duration,
            heardSpeech: heardSpeech)
    }

    public func cancel() async {
        discard()
    }

    // MARK: Internals

    private func process(_ chunk: AudioChunk) {
        guard streamID != nil else { return }
        let normalized = resampler.normalize(chunk)
        samples.append(contentsOf: normalized)

        let level = AudioLevel.normalizedRMS(chunk.samples)
        let elapsed = seconds(samples.count)

        if !autoStopFired {
            if level >= vad.speechLevel {
                heardSpeech = true
                silenceStartedAtSample = nil
            } else if heardSpeech {
                if silenceStartedAtSample == nil { silenceStartedAtSample = samples.count }
                if let start = silenceStartedAtSample,
                    seconds(samples.count - start) >= vad.endOfTurnSilence.asSeconds
                {
                    fireAutoStop()
                }
            } else if elapsed >= vad.idleGiveUp.asSeconds {
                fireAutoStop()
            }
            if elapsed >= vad.maxRecording.asSeconds {
                fireAutoStop()
            }
        }
    }

    private func seconds(_ sampleCount: Int) -> Double {
        Double(sampleCount) / sampleRate
    }

    private func fireAutoStop() {
        guard !autoStopFired else { return }
        autoStopFired = true
        onAutoStop?()
    }

    private func discard() {
        detach()
        resetBuffers()
    }

    private func detach() {
        if let id = streamID {
            streamID = nil
            capture.closeStream(id)
        }
        pump?.cancel()
        pump = nil
    }

    private func resetBuffers() {
        samples.removeAll()
        resampler.reset()
        heardSpeech = false
        silenceStartedAtSample = nil
        autoStopFired = false
        onAutoStop = nil
    }
}

extension Duration {
    var asSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
