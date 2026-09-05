import AVFoundation
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

private struct SynthesisRefused: Error {}

/// Hands back one byte of "audio" per sentence, or refuses from the `failFrom`
/// call onwards — the provider rejecting mid-reply.
private final class ScriptedSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var _calls = 0
    private let failFrom: Int

    init(failFrom: Int = .max) { self.failFrom = failFrom }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var calls: Int { locked { _calls } }

    func synthesize(config: DirectTTSConfig, text: String) async throws -> Data {
        let n = locked { () -> Int in
            _calls += 1
            return _calls
        }
        if n >= failFrom { throw SynthesisRefused() }
        return Data([0x01])
    }
}

/// Plays nothing; answers from a script, one entry per clip. Runs off the end
/// as `.completed`. `park` holds the nth play open so a stop can land mid-clip.
private final class ScriptedPlayer: FallbackClipPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var script: [ClipPlayback]
    private nonisolated(unsafe) var _plays = 0
    private nonisolated(unsafe) var _stops = 0
    private nonisolated(unsafe) var parked: CheckedContinuation<ClipPlayback, Never>?
    private let parkAt: Int?

    init(_ script: [ClipPlayback] = [], parkAt: Int? = nil) {
        self.script = script
        self.parkAt = parkAt
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var plays: Int { locked { _plays } }
    var stops: Int { locked { _stops } }
    var isPlaying: Bool { locked { parked != nil } }

    func play(data: Data) async -> ClipPlayback {
        let n = locked { () -> Int in
            _plays += 1
            return _plays
        }
        let result = locked { () -> ClipPlayback in
            script.isEmpty ? .completed : script.removeFirst()
        }
        guard n == parkAt else { return result }
        return await withCheckedContinuation { continuation in
            locked { parked = continuation }
        }
    }

    func stop() {
        let continuation = locked { () -> CheckedContinuation<ClipPlayback, Never>? in
            _stops += 1
            let held = parked
            parked = nil
            return held
        }
        // A stopped clip was audible and was cut short.
        continuation?.resume(returning: .interrupted)
    }
}

private func run(
    _ reply: String,
    synth: ScriptedSynthesizer = ScriptedSynthesizer(),
    player: ScriptedPlayer
) async -> SpeechStreamOutcome {
    let session = DirectSpeechSession(config: ttsConfig, client: synth, makePlayer: { player })
    await session.append(reply)
    await session.finish()
    return await session.waitDone()
}

private let oneSentence = "A sentence that is long enough to be spoken aloud. "
private let twoSentences = oneSentence + "And a second one, also long enough. "

// MARK: - The outcome contract

/// Issue #69. `.fallback` means nothing was audible, so the engine re-speaks
/// the whole reply through the gateway (`ConversationEngine.swift:583`).
/// `started` decided that, and it was set before the clip was even handed to
/// the player — so an unplayable first clip claimed it had spoken.
@Suite("Direct speech session outcome")
struct DirectSpeechOutcomeTests {
    /// The reported defect. Pre-fix this settles `.done` and the user hears
    /// silence for the whole turn.
    @Test func anUnplayableFirstClipFallsBackInsteadOfClaimingItSpoke() async {
        let player = ScriptedPlayer([.neverStarted])
        #expect(await run(oneSentence, player: player) == .fallback)
        #expect(player.plays == 1)
    }

    /// The other side of the distinction, and the reason `started` cannot
    /// simply move after a *successful* play: audio the user already heard
    /// must not be re-spoken from the beginning.
    @Test func aClipCutShortAfterItStartedKeepsWhatPlayed() async {
        #expect(await run(oneSentence, player: ScriptedPlayer([.interrupted])) == .done)
    }

    /// Nothing audible on the second clip either, but the first one played,
    /// so this is still "keep what played".
    @Test func anUnplayableClipAfterOneThatPlayedSettlesDone() async {
        let player = ScriptedPlayer([.completed, .neverStarted])
        #expect(await run(twoSentences, player: player) == .done)
        #expect(player.plays == 2)
    }

    /// Preserved: the provider refusing before any audio is the original
    /// `.fallback` case and is unaffected.
    @Test func aProviderRejectionBeforeAnyAudioFallsBack() async {
        let synth = ScriptedSynthesizer(failFrom: 1)
        let player = ScriptedPlayer()
        #expect(await run(oneSentence, synth: synth, player: player) == .fallback)
        #expect(player.plays == 0)
    }

    /// Preserved: the provider refusing after a clip played settles `.done`.
    @Test func aProviderRejectionAfterAudioPlayedSettlesDone() async {
        let synth = ScriptedSynthesizer(failFrom: 2)
        #expect(await run(twoSentences, synth: synth, player: ScriptedPlayer()) == .done)
    }

    /// Preserved: a user stop settles first, so the playback result never
    /// decides the outcome.
    @Test func aUserStopMidClipSettlesDoneAndSpeaksNoMore() async {
        let synth = ScriptedSynthesizer()
        let player = ScriptedPlayer(parkAt: 1)
        let session = DirectSpeechSession(
            config: ttsConfig, client: synth, makePlayer: { player })

        await session.append(twoSentences)
        await session.finish()
        while player.plays < 1 { await Task.yield() }
        await session.stopNow()

        #expect(await session.waitDone() == .done)
        #expect(player.plays == 1)
        // `stopNow()` stops the clip and `settle()` stops it again; the real
        // player is idempotent, so this is >= 1 rather than a pin on the
        // pre-existing double stop.
        #expect(player.stops >= 1)
    }

    /// Preserved: with nothing failing, every sentence is played and the turn
    /// is `.done`.
    @Test func everySentenceIsPlayedWhenNothingFails() async {
        let player = ScriptedPlayer()
        #expect(await run(twoSentences, player: player) == .done)
        #expect(player.plays == 2)
    }
}

// MARK: - The gateway fallback path

/// `HermesSpeechOutput.playFallback` answers a `Bool` meaning "spoke the whole
/// clip", and `ConversationEngine.awaitFallbackSpeech` retries while it is
/// false. Widening the player's result must not quietly promote a clip that
/// merely started into a success.
@Suite("Whole-clip fallback result")
struct FallbackSpeechResultTests {
    private func speech(_ player: ScriptedPlayer) -> HermesSpeechOutput {
        let rest = HermesRESTClient(
            endpoint: ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:1")!), token: nil)
        return HermesSpeechOutput(
            rest: rest, profile: nil, voiceConfig: nil,
            synthesize: { _ in Data([1, 2, 3]) },
            makeFallbackPlayer: { player })
    }

    @Test func anInterruptedClipIsNotReportedAsSpoken() async {
        let player = ScriptedPlayer([.interrupted])
        #expect(await speech(player).playFallback(text: "A reply completed") == false)
        #expect(player.plays == 1)
    }

    @Test func anUnplayableClipIsNotReportedAsSpoken() async {
        #expect(
            await speech(ScriptedPlayer([.neverStarted]))
                .playFallback(text: "A reply completed") == false)
    }

    @Test func aCompletedClipIsReportedAsSpoken() async {
        #expect(
            await speech(ScriptedPlayer([.completed]))
                .playFallback(text: "A reply completed") == true)
    }
}

// MARK: - The real player

/// The fake cannot carry the distinction alone: the shipping player has to
/// report `neverStarted` for the data a provider actually sends when it
/// returns an error body instead of audio.
@Suite("Fallback clip player result")
struct FallbackClipPlayerResultTests {
    @Test(arguments: [
        Data([0x00]),
        Data("{\"error\":\"nope\"}".utf8),
        Data(repeating: 0, count: 4096),
    ])
    func undecodableDataNeverStarts(_ data: Data) async {
        #expect(await FallbackClipPlayer().play(data: data) == .neverStarted)
    }

    /// The `began` latch on the shipping player, driven for real: a clip that
    /// was audible and then stopped is an interruption, not a failure to
    /// start. Without this only the fake would carry that mapping.
    @Test func stoppingARealClipMidPlaybackReportsInterrupted() async {
        let player = FallbackClipPlayer()
        let twoSeconds = WAVEncoder.encode(
            samples: [Float](repeating: 0, count: 48000), sampleRate: 24000)

        async let result = player.play(data: twoSeconds)
        // Bounded, so a machine that cannot play fails the test rather than
        // hanging the suite.
        let deadline = Date().addingTimeInterval(2)
        while !player.isPlaying, Date() < deadline { await Task.yield() }
        #expect(player.isPlaying, "the clip never became audible")
        player.stop()

        #expect(await result == .interrupted)
    }

    /// And it must still report a real clip as completed, or the fix would
    /// turn every reply into a fallback.
    @Test func aDecodableClipCompletes() async {
        let silence = WAVEncoder.encode(samples: [Float](repeating: 0, count: 480), sampleRate: 24000)
        #expect(await FallbackClipPlayer().play(data: silence) == .completed)
    }
}
