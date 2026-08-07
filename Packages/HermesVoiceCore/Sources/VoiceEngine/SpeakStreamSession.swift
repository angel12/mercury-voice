import Foundation

/// One `/api/audio/speak-stream` socket: one spoken reply.
///
/// Client frames: `{"text": delta}` incrementally, `{"done": true}` when the
/// reply is complete. Server: `{"type":"start",...}` → binary int16 PCM
/// frames → `{"type":"end"}`, or `{"type":"fallback"}` when the provider has
/// no chunked API. Closing the socket is barge-in — the server aborts.
public actor SpeakStreamSession: SpeechStreaming {
    private let task: URLSessionWebSocketTask
    private let urlSession: URLSession
    private let player = PCMStreamPlayer()

    private var started = false  // any PCM arrived
    private var finished = false  // done sent
    private var outcome: SpeechStreamOutcome?
    private var waiters: [CheckedContinuation<SpeechStreamOutcome, Never>] = []
    private var receiveTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    /// Max silence tolerated after `{"done": true}` before declaring the peer
    /// wedged. Armed only post-`finish()` — mid-reply gaps are legitimate
    /// (the agent may pause between sentences), but once the full text is in,
    /// the server owes us frames until `end`.
    private static let completionGrace: Duration = .seconds(30)

    public init(url: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 3600
        urlSession = URLSession(configuration: config)
        task = urlSession.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
    }

    /// Must be called once after init (actors can't start their own tasks in
    /// init under strict concurrency).
    public func begin() {
        guard receiveTask == nil, outcome == nil else { return }
        receiveTask = Task { await self.runReceiveLoop() }
    }

    public var isAudiblyPlaying: Bool { player.isPlaying }

    // MARK: SpeechStreaming

    public func append(_ text: String) {
        guard !text.isEmpty, !finished, outcome == nil else { return }
        send(#"{"text": \#(Self.jsonString(text))}"#)
    }

    public func finish() {
        guard !finished, outcome == nil else { return }
        finished = true
        send(#"{"done": true}"#)
        armWatchdog()
    }

    public func waitDone() async -> SpeechStreamOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Barge-in / user stop: abort synthesis and playback immediately.
    public func stopNow() {
        player.stop()
        settle(.done)
    }

    // MARK: Internals

    private func send(_ text: String) {
        task.send(.string(text)) { _ in }
    }

    private func runReceiveLoop() async {
        while outcome == nil {
            do {
                let message = try await task.receive()
                if finished { armWatchdog() }  // any frame counts as liveness
                switch message {
                case .data(let data):
                    if !started { started = true }
                    player.schedule(data)
                case .string(let text):
                    handleControl(text)
                @unknown default:
                    break
                }
            } catch {
                // Socket error/close before `end`: if audio already flowed,
                // let it drain and call it done; otherwise ask for fallback.
                if started {
                    await player.drain()
                    settle(.done)
                } else {
                    settle(.fallback)
                }
                return
            }
        }
    }

    private func handleControl(_ text: String) {
        guard let data = text.data(using: .utf8),
            let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = frame["type"] as? String
        else { return }

        switch type {
        case "start":
            let sampleRate =
                (frame["sample_rate"] as? Double)
                ?? (frame["sample_rate"] as? Int).map(Double.init)
                ?? VoiceConstants.defaultTTSSampleRate
            do {
                try player.prepare(sampleRate: sampleRate)
            } catch {
                settle(.fallback)
            }
        case "end":
            // Synthesis is complete; draining queued audio may legitimately
            // outlast the grace window, so the watchdog stands down here.
            watchdog?.cancel()
            watchdog = nil
            Task {
                await self.player.drain()
                self.settleAfterDrain()
            }
        case "fallback":
            settle(started ? .done : .fallback)
        default:
            break
        }
    }

    private func settleAfterDrain() {
        settle(.done)
    }

    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task {
            try? await Task.sleep(for: Self.completionGrace)
            guard !Task.isCancelled else { return }
            self.watchdogFired()
        }
    }

    private func watchdogFired() {
        guard outcome == nil else { return }
        // The peer went silent after `done`: salvage what played, or report
        // fallback so the engine can speak the reply another way.
        settle(started ? .done : .fallback)
    }

    private func settle(_ result: SpeechStreamOutcome) {
        guard outcome == nil else { return }
        outcome = result
        watchdog?.cancel()
        watchdog = nil
        receiveTask?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        urlSession.invalidateAndCancel()
        player.stop()
        for waiter in waiters { waiter.resume(returning: result) }
        waiters.removeAll()
    }

    static func jsonString(_ text: String) -> String {
        let data = (try? JSONEncoder().encode([text])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}
