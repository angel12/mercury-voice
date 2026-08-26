import Foundation

/// One live JSON-RPC 2.0 connection to `/api/ws`.
///
/// Single-connection lifetime: dial once, use until it drops, then discard.
/// Reconnection (with a fresh instance) is `HermesConnection`'s job.
///
/// Keepalive expectation: the server disables WS pings on loopback binds and
/// a busy agent turn can legitimately go minutes without a frame — quiet is
/// NOT dead here, so no read timeout is applied.
public actor GatewayClient {
    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case ready
        case closed(reason: String?)
    }

    /// Why the socket closed, for callers that must react differently.
    /// `unauthorized` is terminal: the server rejected these credentials, so
    /// redialing with them can only fail the same way.
    public enum CloseCause: Sendable, Equatable {
        case unauthorized
        case other
    }

    private let endpoint: ServerEndpoint
    private let authenticator: HermesAuthenticator
    private let urlSession: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?

    private var nextRequestID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var subscribers: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]

    public private(set) var state: State = .idle
    public private(set) var closeCause: CloseCause = .other
    /// `replay_epoch` from this socket's `gateway.ready` (nil on old backends).
    public private(set) var replayEpoch: String?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    /// Backend contract version reported in gateway payloads (session.info's
    /// `desktop_contract`); the app warns when older than what it was built
    /// against.
    public static let builtAgainstDesktopContract = 6

    public init(endpoint: ServerEndpoint, authenticator: HermesAuthenticator) {
        self.endpoint = endpoint
        self.authenticator = authenticator

        let config = URLSessionConfiguration.ephemeral
        // Long agent turns stall frames for minutes; never let URLSession
        // kill the socket for resource-timeout reasons under us.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 3600
        self.urlSession = URLSession(configuration: config)
    }

    public init(endpoint: ServerEndpoint, token: String?) {
        self.init(
            endpoint: endpoint,
            authenticator: HermesAuthenticator(
                endpoint: endpoint,
                credentials: token.map { .sessionToken($0) }))
    }

    deinit {
        urlSession.invalidateAndCancel()
    }

    // MARK: Connect

    /// Dial and wait for the server's `gateway.ready` event (sent immediately
    /// after accept; no client hello is required).
    public func connect(timeout: TimeInterval = 10) async throws {
        guard state == .idle else { return }
        state = .connecting

        // The auth query is minted per dial: gated mode uses a single-use
        // 30s `?ticket=`, so the URL from a previous attempt is never valid.
        let query: [URLQueryItem]
        do {
            query = try await authenticator.webSocketAuthQuery()
        } catch {
            state = .idle
            throw error
        }
        let url = endpoint.webSocketURL("/api/ws", query: query)

        let task = urlSession.webSocketTask(with: url)
        // Tolerate large inbound frames (session.info / transcripts).
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        task.resume()

        receiveLoop = Task { await self.runReceiveLoop(task) }

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            self.failReady(with: HermesError.timeout("gateway.ready"))
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            switch state {
            case .ready: cont.resume()
            case .closed(let reason):
                cont.resume(throwing: HermesError.connectionClosed(reason))
            default: readyWaiters.append(cont)
            }
        }
    }

    private func failReady(with error: Error) {
        guard state == .connecting else { return }
        close(reason: (error as? HermesError)?.errorDescription ?? "\(error)")
    }

    // MARK: Requests

    /// Send a JSON-RPC request and await its response.
    public func request(
        _ method: String,
        params: JSONValue? = nil,
        timeout: TimeInterval = 60
    ) async throws -> JSONValue {
        guard state == .ready, let task else { throw HermesError.notConnected }

        nextRequestID += 1
        let id = nextRequestID

        var frame: [String: JSONValue] = [
            "jsonrpc": "2.0",
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params { frame["params"] = params }
        let data = try JSONEncoder().encode(JSONValue.object(frame))
        guard let text = String(data: data, encoding: .utf8) else {
            throw HermesError.malformedResponse("could not encode request")
        }

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            self.timeOutRequest(id: id, method: method)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            task.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { await self?.failRequest(id: id, error: error) }
            }
        }
    }

    private func timeOutRequest(id: Int, method: String) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: HermesError.timeout(method))
        }
    }

    private func failRequest(id: Int, error: Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    // MARK: Events

    /// Subscribe to server-push events. The stream finishes when the
    /// connection closes — a finished stream is the disconnect signal.
    public func events() -> AsyncStream<GatewayEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            if case .closed = state {
                continuation.finish()
                return
            }
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    // MARK: Close

    public func close(reason: String? = nil, cause: CloseCause = .other) {
        if case .closed = state { return }
        state = .closed(reason: reason)
        closeCause = cause

        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil

        let closeError = HermesError.connectionClosed(reason)
        for cont in pending.values { cont.resume(throwing: closeError) }
        pending.removeAll()
        for cont in readyWaiters { cont.resume(throwing: closeError) }
        readyWaiters.removeAll()
        for sub in subscribers.values { sub.finish() }
        subscribers.removeAll()
    }

    // MARK: Receive loop

    private func runReceiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleFrame(text)
                case .data:
                    break  // /api/ws is text-only; ignore stray binary frames
                @unknown default:
                    break
                }
            } catch {
                let outcome = Self.closeOutcome(closeCode: task.closeCode, error: error)
                close(reason: outcome.reason, cause: outcome.cause)
                return
            }
        }
    }

    /// Socket-close code → user-facing reason + the cause the supervisor
    /// branches on. Pure so it can be tested without standing up a server.
    static func closeOutcome(
        closeCode: URLSessionWebSocketTask.CloseCode, error: Error
    ) -> (reason: String, cause: CloseCause) {
        if closeCode == .invalid {
            // No close frame — a transport error (unreachable, reset, TLS).
            return (error.localizedDescription, .other)
        }
        if closeCode.rawValue == 4401 {
            return ("unauthorized (4401) — the server rejected the credentials", .unauthorized)
        }
        return ("socket closed (code \(closeCode.rawValue))", .other)
    }

    private func handleFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
            let frame = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return }

        // Only frames with method == "event" and params.type are events;
        // everything else is a response.
        if frame["method"]?.stringValue == "event",
            let params = frame["params"], let event = GatewayEvent(eventParams: params)
        {
            if event.type == GatewayEvent.Kind.gatewayReady {
                // Seq numbering identity for the WS replay contract; a later
                // mismatch on session.events.since means the backend restarted.
                replayEpoch = event.payload["replay_epoch"]?.stringValue
                if state == .connecting {
                    state = .ready
                    for cont in readyWaiters { cont.resume() }
                    readyWaiters.removeAll()
                }
            }
            for sub in subscribers.values { sub.yield(event) }
            return
        }

        guard let id = frame["id"]?.intValue, let cont = pending.removeValue(forKey: id) else {
            return
        }
        if let error = frame["error"] {
            cont.resume(
                throwing: HermesError.rpcError(
                    code: error["code"]?.intValue ?? -1,
                    message: error["message"]?.stringValue ?? "unknown error"))
        } else {
            cont.resume(returning: frame["result"] ?? .null)
        }
    }
}
