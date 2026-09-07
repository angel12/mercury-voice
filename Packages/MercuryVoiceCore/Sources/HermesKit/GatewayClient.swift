import Foundation

/// The socket surface `GatewayClient` drives. `URLSessionWebSocketTask` is the
/// only production conformer; tests script one so a reply, a close, a write
/// completion and a caller's cancellation can be ordered against each other
/// exactly instead of hoped for.
protocol GatewaySocket: AnyObject, Sendable {
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    /// The HTTP response to the upgrade handshake, when there was one. A
    /// server that refuses the upgrade answers 401/403 here and no WebSocket
    /// close code is ever produced, so this is the only signal that
    /// distinguishes a refusal from a dropped dial (see `closeOutcome`).
    var upgradeResponse: HTTPURLResponse? { get }
    func resume()
    func receiveFrame() async throws -> URLSessionWebSocketTask.Message
    func sendText(_ text: String, completion: @escaping @Sendable (Error?) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: GatewaySocket {
    func receiveFrame() async throws -> Message { try await receive() }

    var upgradeResponse: HTTPURLResponse? { response as? HTTPURLResponse }

    func sendText(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        send(.string(text), completionHandler: completion)
    }
}

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

    /// Why the socket closed, for callers that must react differently. Two
    /// of the three are terminal, for different reasons:
    ///
    /// - `unauthorized` (WS 4401 / HTTP 401 on the upgrade): the server
    ///   rejected these credentials, so redialing with them can only fail
    ///   the same way — fresh credentials are the fix.
    /// - `forbidden` (WS 4403 / HTTP 403 on the upgrade): the server refused
    ///   this client's access. The credentials are not the problem, so a
    ///   re-login fixes nothing; every redial is refused identically.
    /// - `other`: transport failure or an ordinary close — retryable.
    public enum CloseCause: Sendable, Equatable {
        case unauthorized
        case forbidden
        case other
    }

    private let endpoint: ServerEndpoint
    private let authenticator: HermesAuthenticator
    private let urlSession: URLSession
    private let makeSocket: @Sendable (URL) -> any GatewaySocket
    private var task: (any GatewaySocket)?
    private var receiveLoop: Task<Void, Never>?

    private var nextRequestID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var subscribers: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]

    public private(set) var state: State = .idle
    public private(set) var closeCause: CloseCause = .other
    /// `replay_epoch` from this socket's `gateway.ready` (nil on old backends).
    public private(set) var replayEpoch: String?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    /// Request-lifecycle probes for tests: whatever ends a request — reply,
    /// error, close, timeout, caller cancellation — must leave behind neither
    /// a suspended continuation nor a running timeout timer.
    var pendingRequestCount: Int { pending.count }
    private(set) var liveRequestTimeouts = 0

    /// Backend contract version reported in gateway payloads (session.info's
    /// `desktop_contract`); the app warns when older than what it was built
    /// against.
    public static let builtAgainstDesktopContract = 6

    public init(endpoint: ServerEndpoint, authenticator: HermesAuthenticator) {
        let config = URLSessionConfiguration.ephemeral
        // Long agent turns stall frames for minutes; never let URLSession
        // kill the socket for resource-timeout reasons under us.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 3600
        let session = URLSession(configuration: config)

        self.init(endpoint: endpoint, authenticator: authenticator, urlSession: session) { url in
            let task = session.webSocketTask(with: url)
            // Tolerate large inbound frames (session.info / transcripts).
            task.maximumMessageSize = 64 * 1024 * 1024
            return task
        }
    }

    /// Socket-injecting initializer (tests). Everything else — connect,
    /// receive loop, request bookkeeping — is the production path.
    init(
        endpoint: ServerEndpoint,
        authenticator: HermesAuthenticator,
        urlSession: URLSession = URLSession(configuration: .ephemeral),
        makeSocket: @escaping @Sendable (URL) -> any GatewaySocket
    ) {
        self.endpoint = endpoint
        self.authenticator = authenticator
        self.urlSession = urlSession
        self.makeSocket = makeSocket
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

        let task = makeSocket(url)
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
    ///
    /// Cancellation is local and immediate: a cancelled caller stops waiting
    /// with `CancellationError` and its continuation is dropped, rather than
    /// staying suspended until a reply, a close, or the timeout — which for
    /// `prompt.submit` is 1,800 seconds. Two things it deliberately does NOT
    /// do:
    ///
    /// - It never interrupts the backend. A frame already handed to the
    ///   socket cannot be unsent, so the turn it started keeps running;
    ///   whoever wants it stopped must say so with `session.interrupt`.
    /// - It never closes the socket. Other requests and the event stream
    ///   share it.
    ///
    /// A request whose cancellation is seen *before* the frame reaches the
    /// socket is never sent at all — the actor step that registers the
    /// continuation and hands the text to the socket is the linearization
    /// point, and cancellation observed before it wins.
    public func request(
        _ method: String,
        params: JSONValue? = nil,
        timeout: TimeInterval = 60
    ) async throws -> JSONValue {
        // Before anything else: an abandoned call must not reach the wire.
        // A `prompt.submit` nobody is waiting for still starts a turn.
        try Task.checkCancellation()
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

        liveRequestTimeouts += 1
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            self.timeOutRequest(id: id, method: method)
        }
        defer {
            timeoutTask.cancel()
            liveRequestTimeouts -= 1
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // This closure runs synchronously on the actor as part of the
                // calling task, so registering the continuation and handing
                // the frame to the socket are one indivisible step, and
                // `Task.isCancelled` here is this caller's own flag.
                if Task.isCancelled {
                    // Cancelled while this call waited its turn on the actor
                    // (or during the hop into the handler above): nothing has
                    // been sent yet, so nothing needs unsending.
                    cont.resume(throwing: CancellationError())
                    return
                }
                if case .closed(let reason) = state {
                    // The socket went away while we hopped; answer exactly as
                    // close()'s sweep would have, instead of registering a
                    // continuation nobody will ever resume.
                    cont.resume(throwing: HermesError.connectionClosed(reason))
                    return
                }
                pending[id] = cont
                task.sendText(text) { [weak self] error in
                    guard let error else { return }
                    Task { await self?.failRequest(id: id, error: error) }
                }
            }
        } onCancel: {
            // The handler cannot touch actor state directly; it hops. If a
            // reply, a close or the timeout got there first the entry is
            // already gone and this is a no-op — whoever removes the
            // continuation is the one that resumes it, exactly once.
            Task { await self.cancelRequest(id: id) }
        }
    }

    /// Cancellation seen after the request registered: forget it and release
    /// the caller. The frame stays sent — see `request(_:params:timeout:)`.
    private func cancelRequest(id: Int) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: CancellationError())
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

    private func runReceiveLoop(_ task: any GatewaySocket) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receiveFrame()
                switch message {
                case .string(let text):
                    handleFrame(text)
                case .data:
                    break  // /api/ws is text-only; ignore stray binary frames
                @unknown default:
                    break
                }
            } catch {
                let outcome = Self.closeOutcome(
                    closeCode: task.closeCode,
                    upgradeStatus: task.upgradeResponse?.statusCode,
                    error: error)
                close(reason: outcome.reason, cause: outcome.cause)
                return
            }
        }
    }

    /// Close code + upgrade status → user-facing reason and the cause the
    /// supervisor branches on. Pure so it can be tested without standing up
    /// a server; `GatewayRefusalTests` pins the inputs to what Apple's
    /// transport actually reports.
    ///
    /// A refused upgrade never reaches WebSocket close codes: the server
    /// answers the HTTP handshake with 401 (credentials) or 403 (access) and
    /// URLSession surfaces `.invalid` plus a generic "bad response", so the
    /// handshake response's status is the only signal. A dial that died
    /// before any response carries neither, and stays retryable — guessing
    /// would strand the app on a transient failure.
    static func closeOutcome(
        closeCode: URLSessionWebSocketTask.CloseCode,
        upgradeStatus: Int?,
        error: Error
    ) -> (reason: String, cause: CloseCause) {
        let refusedUpgrade = closeCode == .invalid ? upgradeStatus : nil
        if closeCode.rawValue == 4401 || refusedUpgrade == 401 {
            return ("unauthorized (4401) — the server rejected the credentials", .unauthorized)
        }
        if closeCode.rawValue == 4403 || refusedUpgrade == 403 {
            return (
                "refused (4403) — the server refused this connection; dial it by exactly the address it bound to, or check its access rules",
                .forbidden
            )
        }
        if closeCode == .invalid {
            // No close frame and no refusal — a transport error (unreachable,
            // reset, TLS, a handshake that died before any response).
            return (error.localizedDescription, .other)
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
                    message: error["message"]?.stringValue ?? "unknown error",
                    data: error["data"]))
        } else {
            cont.resume(returning: frame["result"] ?? .null)
        }
    }
}
