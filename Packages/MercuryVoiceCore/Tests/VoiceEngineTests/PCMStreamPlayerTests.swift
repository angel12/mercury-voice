import AVFoundation
import Foundation
import Testing

@testable import VoiceEngine

// MARK: - Fakes

/// A stand-in for the player node that keeps the two completion events Apple
/// distinguishes apart: the player *consuming* the bytes, and the device
/// *finishing playing* them. A handler scheduled `.dataConsumed` fires at the
/// first, one scheduled `.dataPlayedBack` at the second — which is the whole
/// of issue #67, since only the second reflects audio the listener has heard.
///
/// `AVAudioPlayerNode.h` also documents both variants as firing every
/// outstanding handler when the player is stopped, so `stop()` does that by
/// default; `deliversPendingOnStop` turns it off to model a sink that goes
/// silent instead. No handler is ever invoked while the lock is held, and
/// `stop` is never called from inside one — the header warns that a player
/// stopped from within a completion handler can deadlock.
final class FakePlaybackSink: PCMBufferScheduling, @unchecked Sendable {
    private struct Pending {
        let type: AVAudioPlayerNodeCompletionCallbackType
        let handler: @Sendable () -> Void
        var consumed = false
    }

    private let lock = NSLock()
    private var pending: [Pending] = []
    private var _scheduled: [AVAudioPCMBuffer] = []
    private var _requestedTypes: [AVAudioPlayerNodeCompletionCallbackType] = []
    private var _startedFormats: [AVAudioFormat] = []
    private var _stopCount = 0

    /// Whether `stop()` honours the header's "or the player is stopped"
    /// clause. Off models an output that never reports again.
    var deliversPendingOnStop = true

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var scheduled: [AVAudioPCMBuffer] { locked { _scheduled } }
    var requestedTypes: [AVAudioPlayerNodeCompletionCallbackType] { locked { _requestedTypes } }
    var startedFormats: [AVAudioFormat] { locked { _startedFormats } }
    var stopCount: Int { locked { _stopCount } }
    var pendingCount: Int { locked { pending.count } }

    /// Set to make `start` throw, the way a real engine does when it cannot
    /// open the output.
    var startError: (any Error)?

    // MARK: PCMBufferScheduling

    func start(format: AVAudioFormat) throws {
        if let startError { throw startError }
        locked { _startedFormats.append(format) }
    }

    func schedule(
        _ buffer: AVAudioPCMBuffer,
        completionType: AVAudioPlayerNodeCompletionCallbackType,
        onCompletion: @escaping @Sendable () -> Void
    ) {
        locked {
            _scheduled.append(buffer)
            _requestedTypes.append(completionType)
            pending.append(Pending(type: completionType, handler: onCompletion))
        }
    }

    func stop() {
        let due: [Pending] = locked {
            _stopCount += 1
            guard deliversPendingOnStop else { return [] }
            let all = pending
            pending.removeAll()
            return all
        }
        for item in due { item.handler() }
    }

    // MARK: Driving the two events

    /// The player has swallowed every queued buffer. Releases only the
    /// handlers that asked for `.dataConsumed`.
    func consumeAll() {
        let due: [Pending] = locked {
            for index in pending.indices { pending[index].consumed = true }
            let ready = pending.filter { $0.type == .dataConsumed }
            pending.removeAll { $0.type == .dataConsumed }
            return ready
        }
        for item in due { item.handler() }
    }

    /// Harness escape hatch, not part of the modelled node: hand back every
    /// handler still held, whatever its type and whether or not it was
    /// consumed, and ignoring `deliversPendingOnStop`. `withDrainScope` uses
    /// it so a mutation that breaks the stop latch fails one test instead of
    /// hanging the suite on a `drain()` that can never see `isPlaying` go
    /// false.
    func releaseAll() {
        let due: [Pending] = locked {
            let all = pending
            pending.removeAll()
            return all
        }
        for item in due { item.handler() }
    }

    /// The device has finished emitting everything the player consumed.
    /// Releases the `.dataPlayedBack` (and `.dataRendered`) handlers.
    func playBackConsumed() {
        let due: [Pending] = locked {
            let ready = pending.filter(\.consumed)
            pending.removeAll(where: \.consumed)
            return ready
        }
        for item in due { item.handler() }
    }
}

/// Watches an `AVAudioPlayerNode` scheduling call without an engine behind it,
/// so the production adapter's own request is checkable rather than asserted.
final class SpyPlayerNode: AVAudioPlayerNode, @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [AVAudioPlayerNodeCompletionCallbackType] = []
    /// Set when the adapter used the legacy handler variant, which
    /// `AVAudioPlayerNode.h` documents as equivalent to `.dataConsumed`.
    private var _usedLegacyVariant = false

    var seen: [AVAudioPlayerNodeCompletionCallbackType] {
        lock.lock()
        defer { lock.unlock() }
        return _seen
    }
    var usedLegacyVariant: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _usedLegacyVariant
    }

    override func scheduleBuffer(
        _ buffer: AVAudioPCMBuffer,
        completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
        completionHandler: AVAudioPlayerNodeCompletionHandler? = nil
    ) {
        lock.lock()
        _seen.append(completionCallbackType)
        lock.unlock()
    }

    override func scheduleBuffer(
        _ buffer: AVAudioPCMBuffer,
        completionHandler: AVAudioNodeCompletionHandler? = nil
    ) {
        lock.lock()
        _usedLegacyVariant = true
        lock.unlock()
    }
}

/// Runs `drain()` on its own task and records whether it has returned.
final class DrainProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _returned = false
    private var task: Task<Void, Never>?

    var returned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _returned
    }

    private func markReturned() {
        lock.lock()
        _returned = true
        lock.unlock()
    }

    func start(_ player: PCMStreamPlayer) {
        task = Task {
            await player.drain()
            self.markReturned()
        }
    }

    /// Let the drain end however the test finished. `drain()` polls
    /// `isPlaying` and swallows cancellation, so cancelling alone would spin;
    /// the outstanding handlers are released and the player stopped first, so
    /// `isPlaying` cannot stay true.
    func release(player: PCMStreamPlayer, sink: FakePlaybackSink) async {
        sink.releaseAll()
        player.stop()
        _ = await eventually { self.returned }
        task?.cancel()
        task = nil
    }
}

// MARK: - Helpers

/// `frames` little-endian int16 samples, ascending so the conversion is
/// checkable.
private func pcmBytes(frames: Int, first: Int16 = 1) -> Data {
    var data = Data()
    for index in 0..<frames {
        let sample = first &+ Int16(index)
        data.append(UInt8(truncatingIfNeeded: sample))
        data.append(UInt8(truncatingIfNeeded: sample >> 8))
    }
    return data
}

private func preparedPlayer(_ sink: FakePlaybackSink) throws -> PCMStreamPlayer {
    let player = PCMStreamPlayer(sink: sink)
    try player.prepare(sampleRate: VoiceConstants.defaultTTSSampleRate)
    return player
}

/// Runs a drain test with a guarantee that no `drain()` is left looping,
/// however the body exits — `#expect` does not throw, but `try #require`
/// does, and a broken stop latch would otherwise hang the whole suite instead
/// of failing one test.
private func withDrainScope(
    _ sink: FakePlaybackSink,
    _ body: (PCMStreamPlayer, DrainProbe) async throws -> Void
) async throws {
    let player = try preparedPlayer(sink)
    let probe = DrainProbe()
    do {
        try await body(player, probe)
    } catch {
        await probe.release(player: player, sink: sink)
        throw error
    }
    await probe.release(player: player, sink: sink)
}

/// A bounded negative: nothing became true within `window`.
private func stayedFalse(
    for window: Duration = .milliseconds(300), _ condition: @escaping () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + window
    while ContinuousClock.now < deadline {
        if condition() { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return !condition()
}

// MARK: - Completion semantics (#67)

@Suite("PCMStreamPlayer completion semantics")
struct PCMStreamPlayerCompletionTests {
    /// The defect, at its smallest: the player having swallowed the bytes is
    /// not the listener having heard them.
    @Test func consumptionAloneLeavesPlaybackActive() throws {
        let sink = FakePlaybackSink()
        let player = try preparedPlayer(sink)

        player.schedule(pcmBytes(frames: 240))
        player.schedule(pcmBytes(frames: 240))
        #expect(player.isPlaying)

        sink.consumeAll()
        #expect(player.isPlaying)

        sink.playBackConsumed()
        #expect(!player.isPlaying)
    }

    /// The truncation itself. `drain()` is what `SpeakStreamSession` waits on
    /// before it settles the turn and stops the engine, so a drain that
    /// returns on consumption cuts whatever the output device has not emitted.
    @Test func drainWaitsForTheDeviceNotThePlayer() async throws {
        let sink = FakePlaybackSink()
        try await withDrainScope(sink) { player, probe in
            player.schedule(pcmBytes(frames: 240))
            probe.start(player)

            sink.consumeAll()
            #expect(await stayedFalse { probe.returned })

            sink.playBackConsumed()
            #expect(await eventually { probe.returned })
        }
    }

    /// The player names the completion point; the adapter only forwards it.
    @Test func thePlayerAsksTheSinkForPlayedBackCompletions() throws {
        let sink = FakePlaybackSink()
        let player = try preparedPlayer(sink)

        player.schedule(pcmBytes(frames: 240))

        #expect(sink.requestedTypes == [.dataPlayedBack])
        #expect(PCMStreamPlayer.completionType == .dataPlayedBack)
    }

    /// The other half of that chain, against the real `AVAudioPlayerNode` API
    /// and with no engine behind it: the adapter passes the caller's type
    /// through to the callback-type variant, and never falls back to the
    /// legacy handler the header calls equivalent to `.dataConsumed`.
    @Test func theProductionSinkForwardsTheRequestedTypeToTheNode() throws {
        let node = SpyPlayerNode()
        let sink = AVPlayerNodeSink(node: node)
        let format = try #require(
            AVAudioFormat(
                standardFormatWithSampleRate: VoiceConstants.defaultTTSSampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        buffer.frameLength = 240

        sink.schedule(buffer, completionType: PCMStreamPlayer.completionType) {}
        sink.schedule(buffer, completionType: .dataConsumed) {}

        #expect(node.seen == [.dataPlayedBack, .dataConsumed])
        #expect(!node.usedLegacyVariant)
    }
}

// MARK: - Stop (#67)

@Suite("PCMStreamPlayer stop handling")
struct PCMStreamPlayerStopTests {
    /// Stop must end a pending drain on its own, without leaning on the
    /// header's promise that a stopped node fires its outstanding handlers —
    /// so the sink here delivers nothing at all.
    @Test func stopReleasesAPendingDrainWithNoCallbacksAtAll() async throws {
        let sink = FakePlaybackSink()
        sink.deliversPendingOnStop = false
        try await withDrainScope(sink) { player, probe in
            player.schedule(pcmBytes(frames: 240))
            probe.start(player)
            #expect(await stayedFalse(for: .milliseconds(150)) { probe.returned })

            player.stop()

            #expect(!player.isPlaying)
            #expect(await eventually { probe.returned })
            #expect(sink.pendingCount == 1)  // the handler never arrived
        }
    }

    /// The documented path: a stopped node does fire its outstanding
    /// handlers. Arriving late they must not revive the player, reopen a
    /// finished drain, or let anything else be scheduled.
    @Test func lateCallbacksAfterStopCannotReviveThePlayer() async throws {
        let sink = FakePlaybackSink()
        try await withDrainScope(sink) { player, probe in
            player.schedule(pcmBytes(frames: 240))
            player.schedule(pcmBytes(frames: 240))

            player.stop()  // delivers both pending handlers
            #expect(sink.pendingCount == 0)
            #expect(!player.isPlaying)

            // A straggler from a buffer that finished during the stop.
            sink.playBackConsumed()
            #expect(!player.isPlaying)

            player.schedule(pcmBytes(frames: 240))
            #expect(sink.scheduled.count == 2)

            probe.start(player)
            #expect(await eventually { probe.returned })
        }
    }

    /// `SpeakStreamSession.stopNow()` stops the player and then `settle()`
    /// stops it again; the sink must see that once.
    @Test func stopIsNotRepeatedOnTheSink() throws {
        let sink = FakePlaybackSink()
        let player = try preparedPlayer(sink)
        player.schedule(pcmBytes(frames: 240))

        player.stop()
        player.stop()

        #expect(sink.stopCount == 1)
    }
}

// MARK: - Preserved behaviour

@Suite("PCMStreamPlayer scheduling")
struct PCMStreamPlayerSchedulingTests {
    @Test func preparesTheSinkOnceAtTheAdvertisedRate() throws {
        let sink = FakePlaybackSink()
        let player = PCMStreamPlayer(sink: sink)

        try player.prepare(sampleRate: 16000)
        try player.prepare(sampleRate: 48000)

        #expect(sink.startedFormats.count == 1)
        #expect(sink.startedFormats.first?.sampleRate == 16000)
    }

    /// A sink that cannot open the output leaves the player closed rather
    /// than half-open: `SpeakStreamSession` catches this and settles
    /// `.fallback` so the reply is spoken another way, and any PCM that
    /// arrives before that lands is dropped instead of queued against a
    /// format the sink never accepted.
    @Test func aSinkThatCannotStartLeavesThePlayerUnprepared() {
        let sink = FakePlaybackSink()
        sink.startError = MercuryAudioError.playbackSetupFailed
        let player = PCMStreamPlayer(sink: sink)

        #expect(throws: MercuryAudioError.self) {
            try player.prepare(sampleRate: VoiceConstants.defaultTTSSampleRate)
        }
        #expect(!player.isPlaying)

        player.schedule(pcmBytes(frames: 240))
        #expect(sink.scheduled.isEmpty)
    }

    @Test func audioBeforePrepareIsDropped() {
        let sink = FakePlaybackSink()
        let player = PCMStreamPlayer(sink: sink)

        player.schedule(pcmBytes(frames: 240))

        #expect(sink.scheduled.isEmpty)
        #expect(!player.isPlaying)
    }

    @Test func scheduleAfterStopIsIgnored() throws {
        let sink = FakePlaybackSink()
        let player = try preparedPlayer(sink)

        player.stop()
        player.schedule(pcmBytes(frames: 240))

        #expect(sink.scheduled.isEmpty)
        #expect(!player.isPlaying)
    }

    /// int16 little-endian in, normalised float32 out, with the odd trailing
    /// byte held back for the next frame rather than shifting every sample.
    @Test func oddTrailingByteIsCarriedIntoTheNextBuffer() throws {
        let sink = FakePlaybackSink()
        let player = try preparedPlayer(sink)

        // Three bytes: one whole sample (0x0001) plus a dangling 0x02.
        player.schedule(Data([0x01, 0x00, 0x02]))
        // 0x0003 completes the carried byte into 0x0302, then 0x0004.
        player.schedule(Data([0x03, 0x04, 0x00]))

        #expect(sink.scheduled.count == 2)
        let first = try #require(sink.scheduled.first)
        #expect(first.frameLength == 1)
        #expect(first.floatChannelData![0][0] == Float(1) / 32768)

        let second = try #require(sink.scheduled.last)
        #expect(second.frameLength == 2)
        #expect(second.floatChannelData![0][0] == Float(0x0302) / 32768)
        #expect(second.floatChannelData![0][1] == Float(4) / 32768)
    }

    @Test func aLoneOddByteSchedulesNothing() throws {
        let sink = FakePlaybackSink()
        let player = try preparedPlayer(sink)

        player.schedule(Data([0x07]))

        #expect(sink.scheduled.isEmpty)
        #expect(!player.isPlaying)
    }
}
