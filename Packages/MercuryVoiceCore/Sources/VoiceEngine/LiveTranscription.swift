import Foundation
import HermesKit

/// One listening turn transcribed while the user speaks (issue #150,
/// upstream 00adf69d92). The engine starts it when the mic opens and either
/// finishes it with the recorder's capture of the same turn or cancels it.
public protocol LiveTranscribing: Sendable {
    /// The turn's transcript; empty means silence. `utterance` is the
    /// recorder's capture of this turn — transcribed the ordinary way
    /// whenever the live path has nothing usable.
    func finish(_ utterance: RecordedUtterance) async throws -> String
    /// Drop the turn: no transcript, mic consumer and socket closed.
    func cancel() async
}

/// The live socket's surface, so tests can script the server.
protocol LiveSTTSocket: Sendable {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func close()
}

final class URLSessionLiveSTTSocket: LiveSTTSocket, @unchecked Sendable {
    private let urlSession: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        urlSession = URLSession(configuration: .ephemeral)
        task = urlSession.webSocketTask(with: url)
        task.resume()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        urlSession.invalidateAndCancel()
    }
}

/// `/api/audio/transcribe-stream` for one turn. Client frames:
/// `{"sample_rate": 16000}`, binary s16le mono PCM, `{"eos": true}`. Server:
/// `partial` frames while speech is recognised, then `final {transcript}` or
/// `error {message}` — the latter also when the host has no live wire.
///
/// The mic is tapped as its own capture consumer from the moment the turn
/// opens. Frames queue in order (header first) until the socket is ready, so
/// the first words are not lost to the dial. Any failure — no `stt.streaming`,
/// a mint or socket error, an `error` frame, too much audio queued before the
/// dial landed, no final in time, or an empty final (desktop parity) — falls
/// back to transcribing the recorded utterance, never to a half transcript.
actor LiveTranscriptionTurn: LiveTranscribing {
    static let sampleRate = 16_000
    /// Audio queued while the socket is still dialling, at most. Past this
    /// the dial is too slow to be worth it; the recording is the fallback.
    static let maxQueuedBytes = 30 * sampleRate * 2
    /// Audio streamed at most — a backstop so a turn the engine never
    /// finishes cannot hold the mic forever. Past the recorder's own cap.
    static let maxStreamedBytes =
        Int(VoiceConstants.maxRecording.asSeconds + 30) * sampleRate * 2

    private enum Outcome {
        case final(String)
        case failed
    }

    private let capture: any AudioCaptureStreaming
    private let connect: @Sendable () async -> (any LiveSTTSocket)?
    private let filter: @Sendable () async -> STTHallucinationFilter?
    private let fallback: @Sendable (RecordedUtterance) async throws -> String
    private let finalTimeout: Duration

    private let outbox: AsyncStream<URLSessionWebSocketTask.Message>
    private let outboxContinuation: AsyncStream<URLSessionWebSocketTask.Message>.Continuation
    private var captureID: UUID?
    private var pump: Task<Void, Never>?
    private var dial: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var socket: (any LiveSTTSocket)?
    private var queuedBytes = 0
    private var streamedBytes = 0
    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []
    private var closed = false

    init(
        capture: any AudioCaptureStreaming,
        connect: @escaping @Sendable () async -> (any LiveSTTSocket)?,
        filter: @escaping @Sendable () async -> STTHallucinationFilter?,
        fallback: @escaping @Sendable (RecordedUtterance) async throws -> String,
        finalTimeout: Duration = .seconds(15)
    ) {
        self.capture = capture
        self.connect = connect
        self.filter = filter
        self.fallback = fallback
        self.finalTimeout = finalTimeout
        (outbox, outboxContinuation) = AsyncStream.makeStream()
        outboxContinuation.yield(.string(#"{"sample_rate": \#(Self.sampleRate)}"#))
    }

    /// Must be called once after init. Returns promptly: the dial runs in
    /// the background while audio queues.
    func begin() {
        guard dial == nil, !closed else { return }
        do {
            let (id, stream) = try capture.openStream()
            captureID = id
            pump = Task {
                for await chunk in stream { self.ingest(chunk) }
            }
        } catch {
            settle(.failed)
            return
        }
        dial = Task {
            let socket = await connect()
            self.attach(socket)
        }
    }

    func finish(_ utterance: RecordedUtterance) async throws -> String {
        closeCapture()
        if outcome == nil {
            outboxContinuation.yield(.string(#"{"eos": true}"#))
        }
        outboxContinuation.finish()
        let result = await awaitOutcome()
        shutDown()

        if case .final(let transcript) = result {
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let filter = await filter(), filter.matches(trimmed) { return "" }
                return trimmed
            }
        }
        return try await fallback(utterance)
    }

    func cancel() {
        settle(.failed)
        shutDown()
    }

    // MARK: Internals

    private func ingest(_ chunk: AudioChunk) {
        guard outcome == nil, captureID != nil, chunk.sampleRate > 0 else { return }
        let samples = WAVEncoder.resample(
            chunk.samples, from: chunk.sampleRate, to: Double(Self.sampleRate))
        guard !samples.isEmpty else { return }
        let pcm = WAVEncoder.pcm16LE(samples)
        streamedBytes += pcm.count
        if socket == nil { queuedBytes += pcm.count }
        guard queuedBytes <= Self.maxQueuedBytes, streamedBytes <= Self.maxStreamedBytes else {
            closeCapture()
            settle(.failed)
            return
        }
        outboxContinuation.yield(.data(pcm))
    }

    private func attach(_ socket: (any LiveSTTSocket)?) {
        guard let socket else {
            settle(.failed)
            return
        }
        guard outcome == nil, !closed else {
            socket.close()
            return
        }
        self.socket = socket
        let outbox = outbox
        writer = Task {
            for await message in outbox {
                do {
                    try await socket.send(message)
                } catch {
                    self.settle(.failed)
                    return
                }
            }
        }
        reader = Task {
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    if case .string(let text) = message { self.handle(text) }
                } catch {
                    self.settle(.failed)
                    return
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
            let frame = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return }
        switch frame["type"]?.stringValue {
        case "final": settle(.final(frame["transcript"]?.stringValue ?? ""))
        case "error": settle(.failed)
        default: break  // partials: no live caption yet
        }
    }

    private func awaitOutcome() async -> Outcome {
        if let outcome { return outcome }
        let timeout = finalTimeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self.settle(.failed)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func settle(_ result: Outcome) {
        guard outcome == nil else { return }
        outcome = result
        if case .failed = result {
            // Nothing more to send; the recording is the fallback.
            closeCapture()
            outboxContinuation.finish()
        }
        for waiter in waiters { waiter.resume(returning: result) }
        waiters.removeAll()
    }

    private func closeCapture() {
        if let id = captureID {
            captureID = nil
            capture.closeStream(id)
        }
        pump?.cancel()
        pump = nil
    }

    private func shutDown() {
        closed = true
        closeCapture()
        outboxContinuation.finish()
        dial?.cancel()
        writer?.cancel()
        reader?.cancel()
        socket?.close()
        socket = nil
    }
}
