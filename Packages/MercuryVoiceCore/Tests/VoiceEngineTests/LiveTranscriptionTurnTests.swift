import Foundation
import Testing

@testable import HermesKit
@testable import VoiceEngine

/// Issue #150: `/api/audio/transcribe-stream` for one listening turn, and the
/// fallback to the recorded utterance whenever the live path has nothing
/// usable.
@Suite("Live transcription turn")
struct LiveTranscriptionTurnTests {
    private static let header = #"{"sample_rate": 16000}"#
    private static let eos = #"{"eos": true}"#

    private final class Fallback: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        func run() -> String {
            lock.withLock { _calls += 1 }
            return "from the recording"
        }
    }

    private struct Fixture {
        let capture = FakeAudioCapture()
        let socket = ScriptedLiveSocket()
        let fallback = Fallback()
        let turn: LiveTranscriptionTurn

        init(
            connect: (@Sendable (ScriptedLiveSocket) async -> (any LiveSTTSocket)?)? = nil,
            filter: STTHallucinationFilter? = nil,
            finalTimeout: Duration = .seconds(5)
        ) {
            let socket = socket
            let fallback = fallback
            turn = LiveTranscriptionTurn(
                capture: capture,
                connect: {
                    guard let connect else { return socket }
                    return await connect(socket)
                },
                filter: { filter },
                fallback: { _ in fallback.run() },
                finalTimeout: finalTimeout)
        }
    }

    private func chunk(_ count: Int = 4800, rate: Double = 48000) -> AudioChunk {
        AudioChunk(samples: Array(repeating: 0.5, count: count), sampleRate: rate)
    }

    @Test func streamsHeaderAudioAndEosThenReturnsTheFinal() async throws {
        let f = Fixture()
        await f.turn.begin()
        #expect(await eventually { f.capture.activeCount == 1 })
        f.capture.emit(chunk())
        #expect(await eventually { f.socket.sent.count == 2 })

        let result = Task { try await f.turn.finish(makeUtterance()) }
        #expect(await eventually { f.socket.sentTexts.contains(Self.eos) })
        f.socket.reply(#"{"type":"partial","text":"hel"}"#)
        f.socket.reply(#"{"type":"final","transcript":" hello there ","provider":"openai"}"#)

        #expect(try await result.value == "hello there")
        #expect(f.fallback.calls == 0)
        #expect(f.capture.activeCount == 0)
        #expect(f.socket.closed)
        let sent = f.socket.sent
        #expect(sent.first == .string(Self.header))
        // 48 kHz → 16 kHz, s16le: 4800 samples become 1600 × 2 bytes.
        #expect(sent[1].byteCount == 3200)
        #expect(sent.last == .string(Self.eos))
    }

    @Test func audioCapturedBeforeTheDialLandsIsSentInOrder() async throws {
        let gate = AsyncGate()
        let f = Fixture(connect: { socket in
            await gate.wait()
            return socket
        })
        await f.turn.begin()
        #expect(await eventually { f.capture.activeCount == 1 })
        f.capture.emit(chunk(1600, rate: 16000))
        f.capture.emit(chunk(800, rate: 16000))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(f.socket.sent.isEmpty)

        await gate.open()
        #expect(await eventually { f.socket.sent.count == 3 })
        #expect(f.socket.sent.map(\.byteCount) == [Self.header.utf8.count, 3200, 1600])
        await f.turn.cancel()
    }

    @Test func noSocketFallsBackToTheRecording() async throws {
        let f = Fixture(connect: { _ in nil })
        await f.turn.begin()
        #expect(await eventually { f.capture.streamClosed })

        #expect(try await f.turn.finish(makeUtterance()) == "from the recording")
        #expect(f.fallback.calls == 1)
    }

    @Test(arguments: [
        #"{"type":"error","message":"no live STT for the configured provider"}"#,
        #"{"type":"final","transcript":"  ","provider":"xai"}"#,
    ])
    func anErrorOrEmptyFinalFallsBackToTheRecording(frame: String) async throws {
        let f = Fixture()
        await f.turn.begin()
        f.capture.emit(chunk())
        f.socket.reply(frame)

        #expect(try await f.turn.finish(makeUtterance()) == "from the recording")
        #expect(f.fallback.calls == 1)
        #expect(f.socket.closed)
    }

    @Test func aDroppedSocketFallsBackToTheRecording() async throws {
        let f = Fixture()
        await f.turn.begin()
        f.socket.drop()

        #expect(try await f.turn.finish(makeUtterance()) == "from the recording")
    }

    @Test func noFinalInTimeFallsBackToTheRecording() async throws {
        let f = Fixture(finalTimeout: .milliseconds(100))
        await f.turn.begin()
        f.capture.emit(chunk())

        #expect(try await f.turn.finish(makeUtterance()) == "from the recording")
        #expect(f.socket.closed)
    }

    @Test func aFilteredHallucinationIsSilence() async throws {
        let filter = try #require(STTHallucinationFilter(json: ["phrases": ["thank you"]]))
        let f = Fixture(filter: filter)
        await f.turn.begin()
        f.capture.emit(chunk())
        let result = Task { try await f.turn.finish(makeUtterance()) }
        #expect(await eventually { f.socket.sentTexts.contains(Self.eos) })
        f.socket.reply(#"{"type":"final","transcript":"Thank you.","provider":"openai"}"#)

        #expect(try await result.value == "")
        #expect(f.fallback.calls == 0)
    }

    @Test func tooMuchAudioBeforeTheDialGivesUpOnLive() async throws {
        let gate = AsyncGate()
        let f = Fixture(connect: { socket in
            await gate.wait()
            return socket
        })
        await f.turn.begin()
        #expect(await eventually { f.capture.activeCount == 1 })
        f.capture.emit(chunk(31 * 16000, rate: 16000))
        #expect(await eventually { f.capture.streamClosed })

        await gate.open()
        #expect(try await f.turn.finish(makeUtterance()) == "from the recording")
        // A dial landing after the turn gave up is closed on arrival.
        #expect(await eventually { f.socket.closed })
        #expect(f.socket.sent.isEmpty)
    }

    @Test func cancelClosesTheMicAndSocketWithoutATranscript() async {
        let f = Fixture()
        await f.turn.begin()
        f.capture.emit(chunk())
        #expect(await eventually { f.socket.sent.count == 2 })

        await f.turn.cancel()

        #expect(f.capture.streamClosed)
        #expect(f.socket.closed)
        #expect(!f.socket.sentTexts.contains(Self.eos))
        #expect(f.fallback.calls == 0)
    }

    // MARK: Wiring

    @Test func voiceConfigCarriesTheStreamingCapability() {
        #expect(VoiceClientConfig(json: ["stt": ["mode": "relay", "streaming": true]]).sttStreaming)
        #expect(!VoiceClientConfig(json: ["stt": ["mode": "relay"]]).sttStreaming)
        #expect(!VoiceClientConfig(json: [:]).sttStreaming)
    }

    @Test func noMicMeansNoLiveTurn() async {
        let transcriber = RestTranscriber(
            rest: HermesRESTClient(
                endpoint: ServerEndpoint(baseURL: URL(string: "http://10.0.0.5:9119")!),
                token: nil),
            profile: nil)
        #expect(await transcriber.startLive() == nil)
    }
}

extension URLSessionWebSocketTask.Message {
    fileprivate var byteCount: Int {
        switch self {
        case .data(let data): return data.count
        case .string(let text): return text.utf8.count
        @unknown default: return -1
        }
    }
}

extension URLSessionWebSocketTask.Message: @retroactive Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.data(let a), .data(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        default: return false
        }
    }
}

final class ScriptedLiveSocket: LiveSTTSocket, @unchecked Sendable {
    private enum Inbound {
        case message(URLSessionWebSocketTask.Message)
        case failure(any Error)
    }

    private let lock = NSLock()
    private var _sent: [URLSessionWebSocketTask.Message] = []
    private var _closed = false
    private var inbox: [Inbound] = []
    private var receivers: [CheckedContinuation<Inbound, Never>] = []

    var sent: [URLSessionWebSocketTask.Message] { lock.withLock { _sent } }
    var sentTexts: [String] {
        sent.compactMap { if case .string(let text) = $0 { return text } else { return nil } }
    }
    var closed: Bool { lock.withLock { _closed } }

    func reply(_ text: String) { deliver(.message(.string(text))) }
    func drop() { deliver(.failure(URLError(.networkConnectionLost))) }

    private func deliver(_ inbound: Inbound) {
        let receiver: CheckedContinuation<Inbound, Never>? = lock.withLock {
            if receivers.isEmpty {
                inbox.append(inbound)
                return nil
            }
            return receivers.removeFirst()
        }
        receiver?.resume(returning: inbound)
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try lock.withLock {
            if _closed { throw URLError(.cancelled) }
            _sent.append(message)
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let inbound = await withCheckedContinuation { continuation in
            let ready: Inbound? = lock.withLock {
                if !inbox.isEmpty { return inbox.removeFirst() }
                receivers.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        switch inbound {
        case .message(let message): return message
        case .failure(let error): throw error
        }
    }

    func close() {
        let pending: [CheckedContinuation<Inbound, Never>] = lock.withLock {
            _closed = true
            defer { receivers.removeAll() }
            return receivers
        }
        for receiver in pending { receiver.resume(returning: .failure(URLError(.cancelled))) }
    }
}

actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
