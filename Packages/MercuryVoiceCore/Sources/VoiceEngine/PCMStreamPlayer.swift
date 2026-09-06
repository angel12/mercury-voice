import AVFoundation
import Foundation

/// The scheduling sink beneath `PCMStreamPlayer`: PCM buffers in, completion
/// callbacks out. `AVPlayerNodeSink` in production; tests substitute a fake so
/// the two completion events Apple distinguishes — the player consuming the
/// bytes, and the device finishing playing them — can be driven apart without
/// an audio device (issue #67).
protocol PCMBufferScheduling: AnyObject, Sendable {
    /// Build and start the output graph for `format`. Idempotent.
    func start(format: AVAudioFormat) throws
    /// Schedule `buffer` behind whatever is already queued, calling
    /// `onCompletion` at the point named by `completionType`.
    func schedule(
        _ buffer: AVAudioPCMBuffer,
        completionType: AVAudioPlayerNodeCompletionCallbackType,
        onCompletion: @escaping @Sendable () -> Void)
    func stop()
}

/// Production sink: an `AVAudioPlayerNode` on its own `AVAudioEngine`.
final class AVPlayerNodeSink: PCMBufferScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private let node: AVAudioPlayerNode
    private var engine: AVAudioEngine?

    /// The node is injectable so a test can watch which completion type the
    /// adapter asks the real API for; production always gets a fresh one.
    init(node: AVAudioPlayerNode = AVAudioPlayerNode()) {
        self.node = node
    }

    func start(format: AVAudioFormat) throws {
        lock.lock()
        defer { lock.unlock() }
        guard engine == nil else { return }

        let engine = AVAudioEngine()
        engine.attach(node)
        // The engine resamples from the stream rate to the hardware rate.
        engine.connect(node, to: engine.mainMixerNode, format: format)
        #if os(macOS)
            // Pin playback to the user-selected output; on iOS the system
            // route (or the route picker) decides.
            MacAudioDevices.applyPreferredOutput(to: engine)
        #endif
        engine.prepare()
        try engine.start()
        node.play()

        self.engine = engine
    }

    func schedule(
        _ buffer: AVAudioPCMBuffer,
        completionType: AVAudioPlayerNodeCompletionCallbackType,
        onCompletion: @escaping @Sendable () -> Void
    ) {
        // `completionType` is forwarded verbatim — the choice belongs to
        // `PCMStreamPlayer`. The handler deliberately does no more than hand
        // control back: `AVAudioPlayerNode.h` warns that stopping a player
        // from inside a completion handler can deadlock while it unschedules.
        node.scheduleBuffer(buffer, completionCallbackType: completionType) { _ in
            onCompletion()
        }
    }

    func stop() {
        lock.lock()
        let engine = engine
        self.engine = nil
        lock.unlock()

        node.stop()
        engine?.stop()
    }
}

/// Gap-free playback of streamed raw int16 mono PCM: converts frames to
/// float32 `AVAudioPCMBuffer`s at the advertised sample rate and schedules
/// them back-to-back on an `AVAudioPlayerNode`. Carries an odd trailing byte
/// across frames.
final class PCMStreamPlayer: @unchecked Sendable {
    /// The completion point `buffersInFlight` counts down from.
    ///
    /// `.dataPlayedBack` is the only one that accounts for output-device
    /// latency: `AVAudioPlayerNode.h` describes it as "the buffer or file has
    /// finished playing … accounts for both (small) signal processing
    /// latencies downstream of the player in the engine, as well as (possibly
    /// significant) latency in the audio playback device". The plain
    /// `scheduleBuffer(_:completionHandler:)` this used to call is documented
    /// as equivalent to `.dataConsumed`, which reports done while the tail is
    /// still in the output pipeline — so `isPlaying` went false, `drain()`
    /// returned, and the caller stopped the engine mid-tail (issue #67).
    static let completionType: AVAudioPlayerNodeCompletionCallbackType = .dataPlayedBack

    private let lock = NSLock()
    private let sink: any PCMBufferScheduling
    private var format: AVAudioFormat?
    private var carry = Data()
    private var buffersInFlight = 0
    private var stopped = false

    init(sink: any PCMBufferScheduling = AVPlayerNodeSink()) {
        self.sink = sink
    }

    func prepare(sampleRate: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        guard format == nil else { return }

        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate, channels: 1)
        else { throw MercuryAudioError.playbackSetupFailed }

        try sink.start(format: format)
        self.format = format
    }

    var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return buffersInFlight > 0 && !stopped
    }

    func schedule(_ data: Data) {
        lock.lock()
        guard !stopped, let format else {
            lock.unlock()
            return
        }
        var bytes = carry + data
        let usable = bytes.count - (bytes.count % 2)
        carry = usable < bytes.count ? bytes.suffix(from: usable) : Data()
        bytes = bytes.prefix(usable)
        let frameCount = usable / 2
        guard frameCount > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else {
            lock.unlock()
            return
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let out = buffer.floatChannelData![0]
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let pcm = raw.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                out[i] = Float(Int16(littleEndian: pcm[i])) / 32768
            }
        }

        buffersInFlight += 1
        lock.unlock()

        sink.schedule(buffer, completionType: Self.completionType) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.buffersInFlight -= 1
            self.lock.unlock()
        }
    }

    /// Wait for the scheduled tail to finish playing, plus a small pad.
    func drain() async {
        while isPlaying {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: VoiceConstants.playbackDrainPad)
    }

    /// Barge-in, or the end of a turn once `drain()` has returned.
    ///
    /// The node fires every outstanding handler when it is stopped, but this
    /// must not depend on that: `stopped` closes the player under the lock
    /// before the sink is touched, so `isPlaying` is false and any pending
    /// `drain()` ends on its next poll whether or not a single completion ever
    /// arrives. Late callbacks that do arrive only decrement a count nothing
    /// reads again. The sink is stopped once — `SpeakStreamSession.stopNow()`
    /// calls this and then `settle()` calls it a second time.
    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()

        guard !alreadyStopped else { return }
        sink.stop()
    }
}
