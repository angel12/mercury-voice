import Foundation
import Testing

@testable import HermesKit
@testable import VoiceEngine

// MARK: - Support

private let ttsConfig: DirectTTSConfig = {
    let json = try! JSONDecoder().decode(
        JSONValue.self,
        from: Data(
            """
            {"mode": "direct", "wire": "openai-speech", "provider": "openai",
             "base_url": "https://api.example.com/v1/", "api_key": "sk-t"}
            """.utf8))
    return DirectTTSConfig(json: json)!
}()

private let oneSentence = "A sentence that is long enough to be spoken aloud. "
private let twoSentences = oneSentence + "And a second one, also long enough. "

/// Parks each `synthesize` so Stop can land while the request is still in
/// flight. `respectsCancellation` is the URLSession.data path (the await
/// throws). The other path still returns bytes after the pump task is
/// cancelled: cancellation requested is not the same as the HTTP call aborting.
private final class GatedSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private let respectsCancellation: Bool
    private var _texts: [String] = []
    private var _cancelCount = 0
    private var _waiting = false
    private var throwingWaiter: CheckedContinuation<Data, Error>?
    private var returningWaiter: CheckedContinuation<Data, Never>?
    private var cancelBeforePark = false

    init(respectsCancellation: Bool) {
        self.respectsCancellation = respectsCancellation
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var texts: [String] { locked { _texts } }
    var isWaiting: Bool { locked { _waiting } }
    var cancelCount: Int { locked { _cancelCount } }

    func synthesize(config: DirectTTSConfig, text: String) async throws -> Data {
        locked { _texts.append(text) }
        if respectsCancellation {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (cont: CheckedContinuation<Data, Error>) in
                    self.lock.lock()
                    if self.cancelBeforePark {
                        self.cancelBeforePark = false
                        self.lock.unlock()
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    self._waiting = true
                    self.throwingWaiter = cont
                    self.lock.unlock()
                }
            } onCancel: {
                self.lock.lock()
                self._cancelCount += 1
                if let waiter = self.throwingWaiter {
                    self.throwingWaiter = nil
                    self._waiting = false
                    self.lock.unlock()
                    waiter.resume(throwing: CancellationError())
                } else {
                    self.cancelBeforePark = true
                    self.lock.unlock()
                }
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
                self.lock.lock()
                self._waiting = true
                self.returningWaiter = cont
                self.lock.unlock()
            }
        } onCancel: {
            // Record that cancellation was requested; do not resume. The
            // provider still returns when `release` is called.
            self.lock.lock()
            self._cancelCount += 1
            self.lock.unlock()
        }
    }

    func release(_ data: Data) {
        lock.lock()
        _waiting = false
        let throwing = throwingWaiter
        throwingWaiter = nil
        let returning = returningWaiter
        returningWaiter = nil
        lock.unlock()
        throwing?.resume(returning: data)
        returning?.resume(returning: data)
    }
}

// MARK: - Stop during in-flight direct TTS (issue #72)

@Suite("Stop during in-flight direct TTS synthesis")
struct DirectSpeechCancelTests {

    @Test func stopNowCancelsInFlightCancellationAwareSynthesis() async {
        let synth = GatedSynthesizer(respectsCancellation: true)
        let player = RecordingClipPlayer()
        let session = DirectSpeechSession(
            config: ttsConfig, client: synth, makePlayer: { player })

        let outcome = Task { await session.waitDone() }
        await session.append(twoSentences)
        #expect(await eventually { synth.isWaiting })
        #expect(synth.texts.count == 1)

        await session.stopNow()
        #expect(await eventually { synth.cancelCount == 1 })
        #expect(synth.cancelCount == 1)
        #expect(await outcome.value == .done)
        #expect(player.plays.isEmpty)
        #expect(synth.texts.count == 1)
    }

    @Test func stopNowDropsLateResultFromUncancellableSynthesis() async {
        let synth = GatedSynthesizer(respectsCancellation: false)
        let player = RecordingClipPlayer()
        let session = DirectSpeechSession(
            config: ttsConfig, client: synth, makePlayer: { player })

        let outcome = Task { await session.waitDone() }
        await session.append(twoSentences)
        #expect(await eventually { synth.isWaiting })
        #expect(synth.texts.count == 1)

        await session.stopNow()
        #expect(await eventually { synth.cancelCount == 1 })
        #expect(synth.cancelCount == 1)
        #expect(await outcome.value == .done)

        synth.release(Data([0x01]))
        #expect(await eventually { !synth.isWaiting })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(player.plays.isEmpty)
        #expect(synth.texts.count == 1)
    }
}
