import Foundation
import Network

/// Loopback HTTP/1.1 responder for production-path tests. Ignores the request
/// line and serves one scripted body per connection.
///
/// Peer-close observation is the TCP connection this request used going away
/// (`receive` complete/error or `.failed`). It does not speak to URLSession's
/// internal buffering.
final class ScriptedHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let closeState: CloseState
    let port: UInt16

    var peerClosed: Bool { closeState.peerClosed }
    var requestReceived: Bool { closeState.requestReceived }
    var responseSent: Bool { closeState.responseSent }

    static func start(
        status: Int = 500,
        body: Data,
        contentType: String = "application/json",
        declaredLength: Int? = nil,
        stallSeconds: TimeInterval = 0
    ) async throws -> ScriptedHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let closeState = CloseState()

        let length = declaredLength ?? body.count
        let head =
            "HTTP/1.1 \(status) Error\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(length)\r\n"
            + "Connection: keep-alive\r\n\r\n"
        let payload = Data(head.utf8) + body

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        once.resume(returning: port)
                    }
                case .failed(let error):
                    once.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.stateUpdateHandler = { state in
                    if case .failed = state { closeState.markPeerClosed() }
                }
                connection.start(queue: .global(qos: .userInitiated))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                    closeState.markRequestReceived()
                    connection.send(
                        content: payload,
                        completion: .contentProcessed { _ in
                            closeState.markResponseSent()
                            Self.watchPeerClose(connection, state: closeState)
                            if stallSeconds <= 0 {
                                connection.cancel()
                            } else {
                                DispatchQueue.global().asyncAfter(deadline: .now() + stallSeconds) {
                                    connection.cancel()
                                }
                            }
                        })
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }

        return ScriptedHTTPServer(listener: listener, port: port, closeState: closeState)
    }

    private static func watchPeerClose(_ connection: NWConnection, state: CloseState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if isComplete || error != nil {
                state.markPeerClosed()
                return
            }
            watchPeerClose(connection, state: state)
        }
    }

    private init(listener: NWListener, port: UInt16, closeState: CloseState) {
        self.listener = listener
        self.port = port
        self.closeState = closeState
    }

    func stop() { listener.cancel() }
    deinit { listener.cancel() }
}

/// Shared flags for the connection this request used. Not a claim about
/// Foundation's internal socket buffer.
private final class CloseState: @unchecked Sendable {
    private let lock = NSLock()
    private var _peerClosed = false
    private var _requestReceived = false
    private var _responseSent = false

    var peerClosed: Bool { locked { _peerClosed } }
    var requestReceived: Bool { locked { _requestReceived } }
    var responseSent: Bool { locked { _responseSent } }

    func markPeerClosed() { locked { _peerClosed = true } }
    func markRequestReceived() { locked { _requestReceived = true } }
    func markResponseSent() { locked { _responseSent = true } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}
