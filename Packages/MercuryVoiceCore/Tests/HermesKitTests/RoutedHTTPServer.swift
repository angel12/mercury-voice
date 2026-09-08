import Foundation
import Network

/// Loopback HTTP/1.1 server that answers per request and records what it was
/// asked. The existing `ScriptedHTTPServer` replies with one canned body
/// regardless of the request line; proving what a 401 or a 403 does to the
/// credential lifecycle needs the *sequence* of requests — specifically
/// whether `/auth/native/refresh` was ever attempted.
final class RoutedHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var body: Data
    }

    struct Response: Sendable {
        var status: Int
        var body: String

        init(_ status: Int, _ body: String = "{}") {
            self.status = status
            self.body = body
        }
    }

    private let listener: NWListener
    private let lock = NSLock()
    private let handler: @Sendable (Request) -> Response
    private var recorded: [Request] = []
    private(set) var port: UInt16 = 0

    /// Requests in arrival order. `path` keeps its query string.
    var requests: [Request] { lock.withLock { recorded } }

    /// Paths (without query) in arrival order — what most assertions need.
    var paths: [String] {
        requests.map { $0.path.components(separatedBy: "?").first ?? $0.path }
    }

    func requestCount(forPath path: String) -> Int {
        paths.filter { $0 == path }.count
    }

    static func start(
        handler: @escaping @Sendable (Request) -> Response
    ) async throws -> RoutedHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let server = RoutedHTTPServer(listener: listener, handler: handler)
        try await server.waitUntilReady()
        return server
    }

    private init(
        listener: NWListener, handler: @escaping @Sendable (Request) -> Response
    ) {
        self.listener = listener
        self.handler = handler
        // Installed before start(): see LoopbackGatewayServer.
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: DispatchQueue(label: "test.routed-http-connection"))
            self?.receive(connection, buffer: Data())
        }
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let box = PortResumeOnce(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let self, let port = self.listener.port?.rawValue, port != 0 {
                        self.lock.withLock { self.port = port }
                        box.resume(returning: ())
                    } else {
                        box.resume(throwing: URLError(.cannotConnectToHost))
                    }
                case .failed(let error):
                    box.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "test.routed-http"))
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var next = buffer
            if let data { next.append(data) }
            if let request = Self.parse(next) {
                self.lock.withLock { self.recorded.append(request) }
                self.respond(connection, with: self.handler(request))
            } else if isComplete {
                connection.cancel()
            } else {
                self.receive(connection, buffer: next)
            }
        }
    }

    /// Returns the request once the head AND its Content-Length body have
    /// arrived; nil means keep reading.
    private static func parse(_ raw: Data) -> Request? {
        guard let headEnd = raw.range(of: Data("\r\n\r\n".utf8)),
            let head = String(data: raw[..<headEnd.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = (lines.first ?? "").components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let body = raw[headEnd.upperBound...]
        guard body.count >= contentLength else { return nil }

        return Request(
            method: requestLine[0], path: requestLine[1],
            body: Data(body.prefix(contentLength)))
    }

    private func respond(_ connection: NWConnection, with response: Response) {
        let text =
            "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(response.body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n\(response.body)"
        // Flush before cancelling, or URLSession sees a lost connection
        // instead of the status code (verified against this transport).
        connection.send(
            content: Data(text.utf8), isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
    }

    func stop() { listener.cancel() }

    deinit { listener.cancel() }
}
