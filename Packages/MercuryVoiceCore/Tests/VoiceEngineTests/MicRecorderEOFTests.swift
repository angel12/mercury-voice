import Foundation
import Testing

@testable import VoiceEngine

private final class AutoStopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    func fire() {
        lock.lock()
        _count += 1
        lock.unlock()
    }
}

private func loudChunk(rate: Double = 16_000) -> AudioChunk {
    AudioChunk(samples: [Float](repeating: 0.5, count: 1600), sampleRate: rate)
}

@Suite("MicRecorder unexpected capture EOF")
struct MicRecorderEOFTests {

    @Test func unexpectedCurrentStreamEOFNotifiesAndClosesOnce() async throws {
        let capture = FakeAudioCapture()
        let recorder = MicRecorder(capture: capture)
        let autoStop = AutoStopCounter()
        try await recorder.start(vad: VADParameters(), onAutoStop: { autoStop.fire() })
        #expect(capture.activeCount == 1)
        #expect(capture.closeCount == 0)

        capture.finishUnexpectedly()
        #expect(await eventually { autoStop.count == 1 })
        #expect(autoStop.count == 1)
        #expect(capture.closeCount == 1)

        let utterance = await recorder.stop()
        #expect(utterance == nil)
        #expect(autoStop.count == 1)
        #expect(capture.closeCount == 1)
    }

    @Test func intentionalCancelDoesNotNotify() async throws {
        let capture = FakeAudioCapture()
        let recorder = MicRecorder(capture: capture)
        let autoStop = AutoStopCounter()
        try await recorder.start(vad: VADParameters(), onAutoStop: { autoStop.fire() })
        await recorder.cancel()
        #expect(capture.closeCount == 1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(autoStop.count == 0)
    }

    @Test func intentionalStopDoesNotNotify() async throws {
        let capture = FakeAudioCapture()
        let recorder = MicRecorder(capture: capture)
        let autoStop = AutoStopCounter()
        try await recorder.start(vad: VADParameters(), onAutoStop: { autoStop.fire() })
        capture.emit(loudChunk())
        try? await Task.sleep(for: .milliseconds(50))
        let utterance = await recorder.stop()
        #expect(utterance != nil)
        #expect(autoStop.count == 0)
        #expect(capture.closeCount == 1)
    }

    @Test func obsoleteStreamEOFDoesNotNotifyTheReplacement() async throws {
        let capture = FakeAudioCapture()
        let recorder = MicRecorder(capture: capture)
        let autoStop = AutoStopCounter()
        try await recorder.start(vad: VADParameters(), onAutoStop: { autoStop.fire() })
        let firstID = try #require(capture.openedIDs.last)
        try await recorder.start(vad: VADParameters(), onAutoStop: { autoStop.fire() })
        #expect(capture.openedIDs.count == 2)
        #expect(capture.closeCount == 1)

        capture.finish(firstID)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(autoStop.count == 0)

        capture.finishUnexpectedly()
        #expect(await eventually { autoStop.count == 1 })
        #expect(autoStop.count == 1)
        #expect(capture.closeCount == 2)
    }

    @Test func unexpectedEOFRearmsTheEngineWithoutTheHardCap() async throws {
        let capture = FakeAudioCapture()
        let recorder = MicRecorder(capture: capture)
        let clock = TestClock()
        let barge = FakeBargeMonitor()
        let transcriber = FakeTranscriber()
        let speech = FakeSpeech()
        let agent = FakeAgent()
        let engine = ConversationEngine(
            recorder: recorder,
            bargeMonitor: barge,
            transcriber: transcriber,
            speech: speech,
            agent: agent,
            clock: clock)
        await engine.start()
        #expect(await eventually { await engine.status == .listening })
        #expect(capture.openCount == 1)

        capture.finishUnexpectedly()
        #expect(await eventually { capture.openCount == 2 })
        #expect(await engine.status == .listening)
        #expect(clock.now.offset == .zero)
    }
}
