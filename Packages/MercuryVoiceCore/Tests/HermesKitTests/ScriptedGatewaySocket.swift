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
///
/// It models `URLSessionWebSocketTask`'s documented contract, not a friendlier
/// one (`NSURLSession.h:647–657` in the MacOSX26.5 SDK):
///
/// - A successful write completion means the bytes reached the kernel — never
///   that the server saw them.
/// - A failed write or read is terminal for the whole task: it fails all other
///   outstanding work, so the failure of one frame is the loss of the socket,
///   and no later send is accepted.
/// - `cancel(with:reason:)` ends the task the same way.
///
/// So `failWrite`/`failReceive` are transport losses, and a healthy socket is
/// exercised with `flushWrite` instead.
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
    private var receiveWaiter:
        CheckedContinuation<Result<URLSessionWebSocketTask.Message, Error>, Never>?
    private var writes: [PendingWrite] = []
    private var unacknowledged: [Int: PendingWrite] = [:]
    private var sendWaiters: [(count: Int, cont: CheckedContinuation<Void, Never>)] = []
    private var _closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    private var _cancelCount = 0
    /// Set once the task has ended, which in URLSession is a property of the
    /// whole task rather than of one message: after it, reads fail and sends
    /// are refused.
    private var terminalError: Error?

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

    /// Always nil: a scripted socket cannot fabricate URLSession's upgrade
    /// response, and pretending otherwise would "prove" a transport mapping
    /// this type never exercises. The 401/403 upgrade classification is
    /// tested against the real transport in `GatewayRefusalTests`.
    var upgradeResponse: HTTPURLResponse? { nil }

    func resume() {}

    func receiveFrame() async throws -> URLSessionWebSocketTask.Message {
        let next: Result<URLSessionWebSocketTask.Message, Error> = await withCheckedContinuation {
            cont in
            lock.lock()
            if inbound.isEmpty {
                if let terminalError {
                    // There is no reading from a task that has ended.
                    lock.unlock()
                    cont.resume(returning: .failure(terminalError))
                    return
                }
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
        let refusal = terminalError
        if refusal == nil, !acknowledgesWrites { unacknowledged[index] = write }
        let ready = sendWaiters.filter { $0.count <= writes.count }
        sendWaiters.removeAll { $0.count <= writes.count }
        let ack = acknowledgesWrites
        lock.unlock()

        for waiter in ready { waiter.cont.resume() }
        if let refusal {
            // A dead task takes no more traffic. The frame is still recorded,
            // so a test can assert what the client tried to hand over.
            completion(refusal)
        } else if ack {
            completion(nil)
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        _cancelCount += 1
        _closeCode = closeCode
        lock.unlock()
        // Cancelling ends the task: the read side stops and outstanding writes
        // fail, so unblock the receive loop and settle every held write rather
        // than leaving completions that can never fire.
        terminate(with: Closed())
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
        deliverText(
            """
            {"jsonrpc":"2.0","id":\(id),"result":\(result)}
            """)
    }

    func deliverErrorReply(id: Int, code: Int, message: String) {
        deliverText(
            """
            {"jsonrpc":"2.0","id":\(id),"error":{"code":\(code),"message":"\(message)"}}
            """)
    }

    func deliverText(_ text: String) {
        deliver(.success(.string(text)))
    }

    /// Make the client's read fail — the socket dropping under it. That ends
    /// the task, so held writes fail with it and no later send is accepted.
    func failReceive(
        closeCode: URLSessionWebSocketTask.CloseCode = .invalid, error: Error = Dropped()
    ) {
        lock.lock()
        _closeCode = closeCode
        lock.unlock()
        terminate(with: error)
    }

    /// End the task the way URLSession ends one: `NSURLSession.h:647` and
    /// `:655` both say a failing send or receive fails *all* outstanding work.
    /// So every held write's completion fires with `error`, the parked receive
    /// fails with it, and `sendText` refuses from here on. `first` names the
    /// write that caused it, so its completion is the first to fire.
    private func terminate(with error: Error, first: Int? = nil) {
        lock.lock()
        if terminalError == nil { terminalError = error }
        let failure = terminalError ?? error
        var settling: [PendingWrite] = []
        if let first, let target = unacknowledged.removeValue(forKey: first) {
            settling.append(target)
        }
        for index in unacknowledged.keys.sorted() {
            if let held = unacknowledged.removeValue(forKey: index) { settling.append(held) }
        }
        lock.unlock()

        for write in settling { write.completion(failure) }
        deliver(.failure(failure))
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

    /// Report a held write as flushed, the way URLSession's completion handler
    /// does once the bytes reach the kernel — which, per `NSURLSession.h:648`,
    /// says nothing about the server having received them. Returns false if
    /// `index` does not name a write we are still holding.
    @discardableResult
    func flushWrite(at index: Int) -> Bool {
        lock.lock()
        let write = unacknowledged.removeValue(forKey: index)
        lock.unlock()
        write?.completion(nil)
        return write != nil
    }

    /// Fail a held write, which per `NSURLSession.h:647` is terminal for the
    /// whole task: see `terminate(with:first:)`. There is no such thing as a
    /// per-message write error a socket recovers from. Returns false if
    /// `index` does not name a write we are still holding.
    @discardableResult
    func failWrite(at index: Int, error: Error = Dropped()) -> Bool {
        let held = lock.withLock { unacknowledged[index] != nil }
        guard held else { return false }
        terminate(with: error, first: index)
        return true
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

/// The message of a failed outcome, so a test can accept one of several
/// permitted errors without re-deriving the enum shape each time.
func failureText(_ outcome: RPCOutcome?) -> String? {
    if case .failure(let message) = outcome { return message }
    return nil
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

/// Barrier: true once the client has run its close sweep. `events()` finishes
/// exactly there, so this is the client's own signal rather than a poll — and
/// false (instead of a hang) if the sweep never happens.
func closed(_ client: GatewayClient, within seconds: Double = 2) async -> Bool {
    let events = await client.events()
    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        let once = ResumeOnceBox(cont)
        Task {
            for await _ in events {}
            once.resume(true)
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.resume(false)
        }
    }
}

private final class ResumeOnceBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Value, Never>?

    init(_ cont: CheckedContinuation<Value, Never>) {
        self.cont = cont
    }

    func resume(_ value: Value) {
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
