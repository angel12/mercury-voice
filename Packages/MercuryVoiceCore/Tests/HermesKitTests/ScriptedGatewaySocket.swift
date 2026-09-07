import Foundation

@testable import HermesKit

/// A gateway socket a test drives frame by frame.
///
/// Every hand-off is explicit, so reply / close / write-completion /
/// cancellation can be ordered against each other instead of hoped for:
/// inbound frames are delivered only when queued, writes are recorded (and
/// optionally left un-acknowledged, standing in for a frame handed to the
/// transport whose completion has not fired yet), and `awaitSend(count:)` is
/// the barrier meaning "the client has handed that many frames to the socket".
final class ScriptedGatewaySocket: GatewaySocket, @unchecked Sendable {
    /// A frame the client handed us, with the completion handler it is
    /// waiting on (URLSession calls that once the write is flushed or fails).
    struct PendingWrite {
        let text: String
        let completion: @Sendable (Error?) -> Void
    }

    struct Closed: Error {}

    /// A transport drop, worded the way URLSession words one — the client
    /// puts this text into its close reason.
    struct Dropped: LocalizedError {
        var errorDescription: String? { "The network connection was lost." }
    }

    private let lock = NSLock()
    private var inbound: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var receiveWaiter: CheckedContinuation<Result<URLSessionWebSocketTask.Message, Error>, Never>?
    private var writes: [PendingWrite] = []
    private var unacknowledged: [Int: PendingWrite] = [:]
    private var sendWaiters: [(count: Int, cont: CheckedContinuation<Void, Never>)] = []
    private var _closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    private var _cancelCount = 0

    /// When false, `sendText` keeps the completion handler so a test can
    /// decide when (and whether) the write is reported as flushed or failed.
    private var acknowledgesWrites = true

    init(acknowledgesWrites: Bool = true) {
        self.acknowledgesWrites = acknowledgesWrites
    }

    // MARK: GatewaySocket

    var closeCode: URLSessionWebSocketTask.CloseCode {
        lock.withLock { _closeCode }
    }

    func resume() {}

    func receiveFrame() async throws -> URLSessionWebSocketTask.Message {
        let next: Result<URLSessionWebSocketTask.Message, Error> = await withCheckedContinuation {
            cont in
            lock.lock()
            if inbound.isEmpty {
                receiveWaiter = cont
                lock.unlock()
            } else {
                let head = inbound.removeFirst()
                lock.unlock()
                cont.resume(returning: head)
            }
        }
        return try next.get()
    }

    func sendText(_ text: String, completion: @escaping @Sendable (Error?) -> Void) {
        let write = PendingWrite(text: text, completion: completion)
        lock.lock()
        writes.append(write)
        let index = writes.count - 1
        if !acknowledgesWrites { unacknowledged[index] = write }
        let ready = sendWaiters.filter { $0.count <= writes.count }
        sendWaiters.removeAll { $0.count <= writes.count }
        let ack = acknowledgesWrites
        lock.unlock()

        for waiter in ready { waiter.cont.resume() }
        if ack { completion(nil) }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        _cancelCount += 1
        _closeCode = closeCode
        lock.unlock()
        // URLSession stops the read side on cancel; unblock the receive loop
        // so its task can finish instead of parking on a dead socket.
        deliver(.failure(Closed()))
    }

    // MARK: Test control — inbound

    /// Queue `gateway.ready` (what the server sends immediately after accept).
    func queueReady(replayEpoch: String = "epoch-1") {
        deliverText(
            """
            {"method":"event","params":{"type":"gateway.ready",\
            "payload":{"replay_epoch":"\(replayEpoch)"}}}
            """)
    }

    func deliverReply(id: Int, result: String) {
        deliverText("""
            {"jsonrpc":"2.0","id":\(id),"result":\(result)}
            """)
    }

    func deliverErrorReply(id: Int, code: Int, message: String) {
        deliverText("""
            {"jsonrpc":"2.0","id":\(id),"error":{"code":\(code),"message":"\(message)"}}
            """)
    }

    func deliverText(_ text: String) {
        deliver(.success(.string(text)))
    }

    /// Make the client's next read fail — the socket dropping under it.
    func failReceive(
        closeCode: URLSessionWebSocketTask.CloseCode = .invalid, error: Error = Dropped()
    ) {
        lock.lock()
        _closeCode = closeCode
        lock.unlock()
        deliver(.failure(error))
    }

    private func deliver(_ item: Result<URLSessionWebSocketTask.Message, Error>) {
        lock.lock()
        if let waiter = receiveWaiter {
            receiveWaiter = nil
            lock.unlock()
            waiter.resume(returning: item)
        } else {
            inbound.append(item)
            lock.unlock()
        }
    }

    // MARK: Test control — outbound

    var sentFrames: [String] {
        lock.withLock { writes.map(\.text) }
    }

    var cancelCount: Int {
        lock.withLock { _cancelCount }
    }

    /// The JSON-RPC `method` of every frame the client sent, in order.
    var sentMethods: [String] {
        sentFrames.compactMap { frame in
            guard let data = frame.data(using: .utf8),
                let json = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { return nil }
            return json["method"]?.stringValue
        }
    }

    /// The `id` the client stamped on its `index`-th frame.
    func sentRequestID(at index: Int) -> Int? {
        let frames = sentFrames
        guard index < frames.count, let data = frames[index].data(using: .utf8),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return json["id"]?.intValue
    }

    /// Barrier: resumes once the client has handed `count` frames to the
    /// socket. Nothing else in the test can observe that moment reliably.
    func awaitSend(count: Int) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if writes.count >= count {
                lock.unlock()
                cont.resume()
            } else {
                sendWaiters.append((count, cont))
                lock.unlock()
            }
        }
    }

    /// Report a held write as flushed (`nil`) or failed, the way URLSession's
    /// completion handler eventually does.
    func completeWrite(at index: Int, error: Error?) {
        lock.lock()
        let write = unacknowledged.removeValue(forKey: index)
        lock.unlock()
        write?.completion(error)
    }
}

// MARK: - Test scaffolding

/// One-shot async gate. `wait()` ignores its waiter's cancellation on purpose:
/// a test needs an already-cancelled task to still reach the call under test.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if open {
                lock.unlock()
                cont.resume()
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    func openGate() {
        lock.lock()
        open = true
        let waiting = waiters
        waiters.removeAll()
        lock.unlock()
        for cont in waiting { cont.resume() }
    }
}

/// How one `request` call ended. Sendable so a test can hand it out of the
/// task that made the call, and comparable so "exactly one outcome" is a
/// plain equality check.
enum RPCOutcome: Sendable, Equatable {
    case value(JSONValue)
    case cancelled
    case failure(String)
}

func rpcOutcome(_ body: @Sendable () async throws -> JSONValue) async -> RPCOutcome {
    do {
        return .value(try await body())
    } catch is CancellationError {
        return .cancelled
    } catch {
        return .failure((error as? HermesError)?.errorDescription ?? "\(error)")
    }
}

/// Await a call's outcome under a deadline. A request that stays suspended —
/// the bug under test — reports `nil` instead of hanging the suite.
func settled(
    _ call: Task<RPCOutcome, Never>, within seconds: Double = 2
) async -> RPCOutcome? {
    await withCheckedContinuation { (cont: CheckedContinuation<RPCOutcome?, Never>) in
        let once = ResumeOnceBox(cont)
        Task { once.resume(await call.value) }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.resume(nil)
        }
    }
}

private final class ResumeOnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<RPCOutcome?, Never>?

    init(_ cont: CheckedContinuation<RPCOutcome?, Never>) {
        self.cont = cont
    }

    func resume(_ value: RPCOutcome?) {
        lock.lock()
        let waiting = cont
        cont = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}

/// A `GatewayClient` wired to a scripted socket and already `ready`, i.e. past
/// the real `connect()` handshake and running the real receive loop.
func readyGatewayClient(
    acknowledgesWrites: Bool = true
) async throws -> (client: GatewayClient, socket: ScriptedGatewaySocket) {
    let socket = ScriptedGatewaySocket(acknowledgesWrites: acknowledgesWrites)
    let endpoint = ServerEndpoint(baseURL: URL(string: "http://127.0.0.1:8080")!)
    let client = GatewayClient(
        endpoint: endpoint,
        // No credentials: the WS auth query is answered locally, so the
        // handshake never touches the network.
        authenticator: HermesAuthenticator(endpoint: endpoint, credentials: nil),
        makeSocket: { _ in socket })
    socket.queueReady()
    try await client.connect(timeout: 5)
    return (client, socket)
}
