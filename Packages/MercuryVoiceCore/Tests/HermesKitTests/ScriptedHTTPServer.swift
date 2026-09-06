import Foundation
import Network

/// Loopback HTTP/1.1 responder for production-path tests. Ignores the request
/// line and serves one scripted body per connection.
final class ScriptedHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

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
                connection.start(queue: .global(qos: .userInitiated))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                    connection.send(
                        content: payload,
                        completion: .contentProcessed { _ in
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

        return ScriptedHTTPServer(listener: listener, port: port)
    }

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    func stop() { listener.cancel() }
    deinit { listener.cancel() }
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
