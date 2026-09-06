import Foundation

/// iOS hardware-mute must release the barge monitor's capture consumer so
/// `AudioCaptureService` can stop the engine (and the privacy indicator).
/// macOS keeps the voice-processing input attached during playback — stopping
/// it mid-TTS kills output.
func shouldDetachBargeCaptureWhileMuted(isIOS: Bool) -> Bool {
    isIOS
}

#if os(iOS)
    let bargeMuteRunsOnIOS = true
#else
    let bargeMuteRunsOnIOS = false
#endif

/// Full-duplex interrupt monitor: watches the mic during thinking/speaking,
/// trips on sustained speech, and captures the interrupting utterance with
/// pre-roll so the first syllable survives.
public actor BargeInMonitor: BargeMonitoring {
    private let capture: any AudioCaptureStreaming
    /// Testable hook: when true, `setSuspended(true)` closes the capture
    /// stream instead of only discarding samples (issue #40).
    let detachCaptureOnSuspend: Bool

    private var streamID: UUID?
    private var pump: Task<Void, Never>?
    private var suspended = false

    public init(capture: AudioCaptureService = .shared) {
        self.capture = capture
        self.detachCaptureOnSuspend = shouldDetachBargeCaptureWhileMuted(
            isIOS: bargeMuteRunsOnIOS)
    }

    init(capture: any AudioCaptureStreaming, detachCaptureOnSuspend: Bool) {
        self.capture = capture
        self.detachCaptureOnSuspend = detachCaptureOnSuspend
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
                streamID: id, stream: stream, isPlaying: isPlaying, onSpeech: onSpeech,
                onUtterance: onUtterance)
        }
    }

    public func stop() async {
        detach()
    }

    public func setSuspended(_ newValue: Bool) {
        suspended = newValue
        if newValue, detachCaptureOnSuspend {
            // iOS: release the consumer so the capture engine can stop.
            // macOS keeps the stream and only discards samples below.
            detach()
        }
    }

    private func detach() {
        if let id = streamID {
            streamID = nil
            capture.closeStream(id)
        }
        pump?.cancel()
        pump = nil
    }

    /// `id` is the stream this run was born with: the pump keeps it so it can
    /// tell, after a suspension, whether it is still the live run.
    private func run(
        streamID id: UUID,
        stream: AsyncStream<AudioChunk>,
        isPlaying: @escaping @Sendable () async -> Bool,
        onSpeech: @escaping @Sendable () -> Void,
        onUtterance: @escaping @Sendable (RecordedUtterance?) -> Void
    ) async {
        var detector = BargeDetector(utteranceSilence: TurnSilencePreference.duration)
        var preRoll: [Float] = []
        var captured: [Float] = []
        // Locks to the first chunk's rate; route-change chunks at other rates
        // are resampled into it so the sample-count timeline stays monotonic
        // and the capture buffer holds one format (issue #43).
        var resampler = RateLockedResampler()
        var elapsedSamples = 0
        var tripped = false

        // Drop the audio and any half-built capture so nothing heard while
        // muted can ever trip or be delivered.
        func discardHeardAudio() {
            detector = BargeDetector(utteranceSilence: TurnSilencePreference.duration)
            preRoll.removeAll()
            captured.removeAll()
            tripped = false
        }

        for await chunk in stream {
            if Task.isCancelled { return }
            let samples = resampler.normalize(chunk)
            let sampleRate = resampler.sampleRate
            guard sampleRate > 0 else { continue }
            if suspended {
                // Deaf but attached.
                discardHeardAudio()
                elapsedSamples += samples.count
                continue
            }
            let now = Duration.seconds(Double(elapsedSamples) / sampleRate)
            elapsedSamples += samples.count

            let playing = await isPlaying()
            // `isPlaying` is the only suspension point inside the loop body,
            // so Stop, a restart and mute all land here — after the checks at
            // the top of the loop have already passed. Re-read them before
            // anything observable happens: a run that is no longer the live
            // one must neither fire callbacks nor tear down the stream that
            // replaced it, and audio heard once muted must still be dropped.
            guard !Task.isCancelled, streamID == id else { return }
            if suspended {
                discardHeardAudio()
                continue
            }
            let level = AudioLevel.normalizedRMS(samples)
            let verdict = detector.process(level: level, at: now, playing: playing)

            switch verdict {
            case .quiet:
                preRoll.append(contentsOf: samples)
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
                captured = preRoll + samples
                preRoll.removeAll()

            case .capturing:
                captured.append(contentsOf: samples)

            case .captureEnded:
                captured.append(contentsOf: samples)
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
        if tripped, !captured.isEmpty, !Task.isCancelled, resampler.sampleRate > 0 {
            let utterance = RecordedUtterance(
                audio: WAVEncoder.encode(samples: captured, sampleRate: resampler.sampleRate),
                mimeType: WAVEncoder.mimeType,
                duration: .seconds(Double(captured.count) / resampler.sampleRate),
                heardSpeech: true)
            onUtterance(utterance)
        }
    }
}
