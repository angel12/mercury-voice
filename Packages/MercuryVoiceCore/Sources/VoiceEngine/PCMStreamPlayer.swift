import AVFoundation
import Foundation

/// Gap-free playback of streamed raw int16 mono PCM: converts frames to
/// float32 `AVAudioPCMBuffer`s at the advertised sample rate and schedules
/// them back-to-back on an `AVAudioPlayerNode`. Carries an odd trailing byte
/// across frames.
final class PCMStreamPlayer: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var carry = Data()
    private var buffersInFlight = 0
    private var stopped = false

    func prepare(sampleRate: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        guard engine == nil else { return }

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate, channels: 1)
        else { throw MercuryAudioError.playbackSetupFailed }

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
        self.node = node
        self.format = format
    }

    var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return buffersInFlight > 0 && !stopped
    }

    func schedule(_ data: Data) {
        lock.lock()
        guard !stopped, let node, let format else {
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

        node.scheduleBuffer(buffer) { [weak self] in
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

    func stop() {
        lock.lock()
        let node = node
        let engine = engine
        stopped = true
        self.node = nil
        self.engine = nil
        lock.unlock()

        node?.stop()
        engine?.stop()
    }
}
