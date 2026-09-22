import CryptoKit
import Foundation
import Network

@testable import HermesKit

/// A real WebSocket gateway on 127.0.0.1 with an OS-assigned port, so
/// `GatewayClient` is exercised over an actual `URLSessionWebSocketTask`
/// against actual bytes.
///
/// It exists because the interesting refusals are *transport* facts no
/// injected socket can prove: a gateway that rejects the HTTP upgrade with
/// 401/403 never produces a WebSocket close code at all, and an application
/// close code (4401/4403) only reaches the client if URLSession surfaces it.
/// Both are Apple behaviors, so they get tested against Apple's transport.
///
/// The RFC 6455 handshake and framing are done by hand (NWListener's
/// `NWProtocolWebSocket` options fail to start on this macOS), which also
/// makes the server scriptable enough to refuse an upgrade outright.
final class LoopbackGatewayServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    /// Non-nil: refuse every upgrade with this HTTP status instead of 101.
    private let refuseUpgradeWith: Int?
    /// Kill the connection without answering the upgrade at all — a dial that
    /// dies mid-handshake, which is what a genuinely transient failure looks
    /// like (no status code ever reaches the client).
    private let dropsUpgrade: Bool
    private let onOpen: @Sendable (LoopbackGatewayServer) -> Void
    /// False lets a test hold back the `client.capabilities` reply and fire
    /// it explicitly via `answerCapabilities(asError:)`, to pin down the
    /// ordering against `.phase(.ready)`.
    private let autoAnswersCapabilities: Bool
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var _upgradeAttempts = 0
    private var _receivedFrames: [JSONValue] = []
    private var _pendingCapabilitiesID: Int?
    private(set) var port: UInt16 = 0

    /// One accepted TCP connection: its socket, its unparsed bytes, and
    /// whether the upgrade head has been consumed.
    private final class Peer {
        let connection: NWConnection
        var handshaken = false
        var pending: [UInt8] = []

        init(_ connection: NWConnection) { self.connection = connection }
    }

    /// How many HTTP upgrade heads the server has consumed — one per dial, so
    /// a supervisor that keeps redialing a terminal refusal shows up as a
    /// rising count.
    var upgradeAttempts: Int { lock.withLock { _upgradeAttempts } }

    static func start(
        refuseUpgradeWith: Int? = nil,
        dropsUpgrade: Bool = false,
        autoAnswersCapabilities: Bool = true,
        onOpen: @escaping @Sendable (LoopbackGatewayServer) -> Void = { server in
            server.sendEvent(type: "gateway.ready")
        }
    ) async throws -> LoopbackGatewayServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let server = LoopbackGatewayServer(
            listener: listener, refuseUpgradeWith: refuseUpgradeWith,
            dropsUpgrade: dropsUpgrade, autoAnswersCapabilities: autoAnswersCapabilities,
            onOpen: onOpen)
        try await server.waitUntilReady()
        return server
    }

    private init(
        listener: NWListener,
        refuseUpgradeWith: Int?,
        dropsUpgrade: Bool,
        autoAnswersCapabilities: Bool,
        onOpen: @escaping @Sendable (LoopbackGatewayServer) -> Void
    ) {
        self.listener = listener
        self.refuseUpgradeWith = refuseUpgradeWith
        self.dropsUpgrade = dropsUpgrade
        self.autoAnswersCapabilities = autoAnswersCapabilities
        self.onOpen = onOpen
        // Installed before start(): a started NWListener without a
        // newConnectionHandler fails with EINVAL.
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock {
                self.peers[ObjectIdentifier(connection)] = Peer(connection)
            }
            connection.start(queue: DispatchQueue(label: "test.loopback-gateway-connection"))
            self.receiveNext(connection)
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
            listener.start(queue: DispatchQueue(label: "test.loopback-gateway"))
        }
    }

    private func receiveNext(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.withLock {
                    self.peers[ObjectIdentifier(connection)]?.pending.append(contentsOf: data)
                }
                self.drain(connection)
            }
            if error != nil || isComplete {
                self.drop(connection)
                return
            }
            self.receiveNext(connection)
        }
    }

    private func drop(_ connection: NWConnection) {
        lock.withLock { peers[ObjectIdentifier(connection)] = nil }
        connection.cancel()
    }

    private func drain(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let needsHandshake = lock.withLock { peers[key].map { !$0.handshaken } ?? false }
        guard needsHandshake else {
            handleClientFrames(connection)
            return
        }
        guard let response = lock.withLock({ takeHandshakeLocked(key) }) else { return }
        if dropsUpgrade {
            drop(connection)
            return
        }
        if refuseUpgradeWith != nil {
            // The refusal must be fully flushed before the socket goes away:
            // a connection cancelled with bytes still queued reaches
            // URLSession as "the network connection was lost" and the status
            // code is never parsed at all.
            connection.send(
                content: response, isComplete: true,
                completion: .contentProcessed { [weak self] _ in self?.drop(connection) })
            return
        }
        connection.send(content: response, isComplete: true, completion: .idempotent)
        onOpen(self)
    }

    /// Consume the HTTP upgrade head and return the response bytes — 101 for
    /// a normal dial, or the scripted refusal status. Nil while the head has
    /// not fully arrived. Caller holds `lock`.
    private func takeHandshakeLocked(_ key: ObjectIdentifier) -> Data? {
        guard let peer = peers[key] else { return nil }
        let marker: [UInt8] = Array("\r\n\r\n".utf8)
        guard let headEnd = peer.pending.firstRange(of: marker) else { return nil }
        let head = String(decoding: peer.pending[..<headEnd.lowerBound], as: UTF8.self)
        peer.pending.removeSubrange(..<headEnd.upperBound)
        peer.handshaken = true
        _upgradeAttempts += 1

        if let status = refuseUpgradeWith {
            let body = Data(#"{"detail":"refused"}"#.utf8)
            let responseHead =
                "HTTP/1.1 \(status) Refused\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            return Data(responseHead.utf8) + body
        }

        let requestKey =
            head.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
            .split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let accept = Data(
            Insecure.SHA1.hash(
                data: Data((requestKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        ).base64EncodedString()
        return Data(
            ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                + "Connection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n").utf8)
    }

    // MARK: Client → server

    /// Every frame the client has sent, decoded and in arrival order — so a
    /// test can assert both `client.capabilities` is first *and* what params
    /// it carried, without racing the auto-answer below.
    var receivedFrames: [JSONValue] {
        lock.withLock { _receivedFrames }
    }

    /// The JSON-RPC `method` of every frame the client has sent, in arrival
    /// order.
    var receivedMethods: [String] {
        receivedFrames.compactMap { $0["method"]?.stringValue }
    }

    /// Parse whatever complete WebSocket frames are sitting in `connection`'s
    /// pending bytes. `client.capabilities` — the only request the supervisor
    /// sends before a test's own `onOpen` script runs — is auto-answered
    /// unless `autoAnswersCapabilities` is false, in which case its id is
    /// captured for `answerCapabilities(result:)` to reply on cue; nothing
    /// else here needs a generic RPC dispatcher. Client frames are masked per
    /// RFC 6455 §5.3; unmask before decoding.
    ///
    /// Recording the frame and capturing the pending capabilities id happen
    /// under the same lock acquisition: splitting them let a fast test call
    /// `answerCapabilities()` between the two and find no id yet (issue found
    /// in review, round 1).
    private func handleClientFrames(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        while true {
            let payload: Data? = lock.withLock {
                guard let peer = peers[key] else { return nil }
                guard let (opcode, unmasked, consumed) = Self.takeFrame(peer.pending) else {
                    return nil
                }
                peer.pending.removeSubrange(..<consumed)
                return opcode == 0x1 ? unmasked : nil
            }
            guard let payload else { break }
            guard let text = String(data: payload, encoding: .utf8),
                let data = text.data(using: .utf8),
                let frame = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { continue }
            let isCapabilities = frame["method"]?.stringValue == "client.capabilities"
            let requestID = frame["id"]?.intValue
            lock.withLock {
                _receivedFrames.append(frame)
                if isCapabilities, let requestID, !autoAnswersCapabilities {
                    _pendingCapabilitiesID = requestID
                }
            }
            guard isCapabilities, let requestID else { continue }
            if autoAnswersCapabilities {
                send(#"{"jsonrpc":"2.0","id":\#(requestID),"result":{}}"#)
            }
        }
    }

    /// Reply to the `client.capabilities` request captured while
    /// `autoAnswersCapabilities` is false. `asError` sends `-32601` instead,
    /// the way a contract-6 backend answers.
    func answerCapabilities(asError: Bool = false) {
        guard let id = lock.withLock({ _pendingCapabilitiesID }) else { return }
        if asError {
            send(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"method not found"}}"#)
        } else {
            send(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
        }
    }

    /// Decode one masked client WebSocket frame from the front of `bytes`.
    /// Returns the opcode, the unmasked payload, and how many bytes to
    /// consume — or nil while the frame is not fully buffered yet. Only the
    /// single-frame (FIN=1, no fragmentation) case is handled; that is all a
    /// small JSON-RPC request ever produces.
    private static func takeFrame(_ bytes: [UInt8]) -> (opcode: UInt8, payload: Data, consumed: Int)? {
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var lengthByte = Int(bytes[1] & 0x7F)
        var offset = 2
        if lengthByte == 126 {
            guard bytes.count >= offset + 2 else { return nil }
            lengthByte = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
        } else if lengthByte == 127 {
            guard bytes.count >= offset + 8 else { return nil }
            var extended = 0
            for i in 0..<8 { extended = (extended << 8) | Int(bytes[offset + i]) }
            lengthByte = extended
            offset += 8
        }
        var maskKey: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            maskKey = Array(bytes[offset..<offset + 4])
            offset += 4
        }
        guard bytes.count >= offset + lengthByte else { return nil }
        var payloadBytes = Array(bytes[offset..<offset + lengthByte])
        if masked {
            for i in 0..<payloadBytes.count { payloadBytes[i] ^= maskKey[i % 4] }
        }
        return (opcode, Data(payloadBytes), offset + lengthByte)
    }

    // MARK: Server → client

    private func sendFrame(opcode: UInt8, payload: Data) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((payload.count >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        // Never hold the lock across a send.
        let live = lock.withLock { peers.values.filter(\.handshaken).map(\.connection) }
        for connection in live {
            connection.send(content: frame, isComplete: true, completion: .idempotent)
        }
    }

    func send(_ text: String) {
        sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    /// Push a `{"method": "event"}` frame the way the gateway does.
    func sendEvent(type: String, payload: String = "{}") {
        send(
            #"{"jsonrpc":"2.0","method":"event","params":{"type":"\#(type)","payload":\#(payload)}}"#
        )
    }

    /// Server-initiated close carrying an application close code (4401/4403).
    func close(code: UInt16) {
        sendFrame(opcode: 0x8, payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)]))
    }

    func stop() {
        let open = lock.withLock {
            let open = peers.values.map(\.connection)
            peers = [:]
            return open
        }
        for connection in open { connection.cancel() }
        listener.cancel()
    }

    /// Kill every open peer connection without stopping the listener — models
    /// a transport loss (network reset, backend restart) mid-flight, while a
    /// request the client is awaiting is still outstanding.
    func dropConnections() {
        let open = lock.withLock {
            let open = peers.values.map(\.connection)
            peers = [:]
            return open
        }
        for connection in open { connection.cancel() }
    }

    deinit { listener.cancel() }
}

final class PortResumeOnce<T: Sendable>: @unchecked Sendable {
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

/// Poll `condition` until it holds or the deadline passes. Loopback transport
/// outcomes land on URLSession's own queues, so a test observes them by
/// waiting for the state rather than by sleeping a guessed interval.
func eventually(
    timeout: Double = 5, _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
