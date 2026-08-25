import Foundation
import Testing

@testable import HermesKit

@Suite("ServerEndpoint parsing")
struct ServerEndpointTests {
    @Test func parsesBareHost() throws {
        let result = try ServerEndpoint.parse("localhost")
        #expect(result.endpoint.baseURL.absoluteString == "http://localhost")
        #expect(result.embeddedToken == nil)
    }

    @Test func parsesHostPort() throws {
        let result = try ServerEndpoint.parse("192.168.1.5:8080")
        #expect(result.endpoint.baseURL.absoluteString == "http://192.168.1.5:8080")
    }

    @Test func parsesHTTPSURL() throws {
        let result = try ServerEndpoint.parse("https://hermes.example.com/dashboard")
        #expect(result.endpoint.baseURL.absoluteString == "https://hermes.example.com")
        #expect(result.endpoint.isSecure)
    }

    @Test func extractsTokenFromDashboardURL() throws {
        let result = try ServerEndpoint.parse("http://127.0.0.1:52341/?token=abc-123_XYZ")
        #expect(result.endpoint.baseURL.absoluteString == "http://127.0.0.1:52341")
        #expect(result.embeddedToken == "abc-123_XYZ")
        #expect(result.endpoint.isLoopbackHost)
    }

    @Test func rejectsGarbage() {
        #expect(throws: ServerEndpoint.ParseError.self) {
            try ServerEndpoint.parse("   ")
        }
        #expect(throws: ServerEndpoint.ParseError.self) {
            try ServerEndpoint.parse("ftp://example.com")
        }
    }

    @Test func buildsWebSocketURL() throws {
        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:9000").endpoint
        let url = endpoint.webSocketURL(
            "/api/ws", query: [URLQueryItem(name: "token", value: "t")])
        #expect(url.absoluteString == "ws://127.0.0.1:9000/api/ws?token=t")

        let secure = try ServerEndpoint.parse("https://h.example.com").endpoint
        #expect(
            secure.webSocketURL("/api/audio/speak-stream", query: []).absoluteString
                == "wss://h.example.com/api/audio/speak-stream")
    }

    @Test func keyIsStableIdentity() throws {
        let a = try ServerEndpoint.parse("http://LocalHost:80/?token=x").endpoint
        let b = try ServerEndpoint.parse("localhost:80").endpoint
        #expect(a.key == b.key)
    }

    // MARK: Schemeless scheme defaults (issue #41)

    /// Qualified DNS names default to https — ATS blocks plaintext HTTP to
    /// them anyway, and it keeps passwords off the wire for the Tailscale /
    /// real-domain case.
    @Test func schemelessDNSNamesDefaultToHTTPS() throws {
        #expect(
            try ServerEndpoint.parse("my-mac.tail1234.ts.net").endpoint.baseURL.absoluteString
                == "https://my-mac.tail1234.ts.net")
        #expect(
            try ServerEndpoint.parse("hermes.example.com:8443").endpoint.baseURL.absoluteString
                == "https://hermes.example.com:8443")
    }

    /// The home-lab forms keep the http default — HTTPS is rarely available
    /// on LAN IPs and Bonjour names.
    @Test func schemelessLocalFormsKeepHTTP() throws {
        for input in [
            "localhost", "127.0.0.1:8080", "10.0.0.5:3000", "192.168.1.5",
            "mymac", "mymac:9119", "my-mac.local:8080", "[::1]:8080",
        ] {
            let endpoint = try ServerEndpoint.parse(input).endpoint
            #expect(endpoint.baseURL.scheme == "http", "\(input) should default to http")
        }
    }

    /// An explicit scheme always wins over the host-based default.
    @Test func explicitSchemeIsHonored() throws {
        #expect(
            try ServerEndpoint.parse("http://hermes.example.com").endpoint.baseURL.scheme
                == "http")
        #expect(
            try ServerEndpoint.parse("https://192.168.1.5:8443").endpoint.baseURL.scheme
                == "https")
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test func roundTrips() throws {
        let json = #"{"a": 1, "b": "x", "c": [true, null, 2.5], "d": {"e": -3}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(value["a"]?.intValue == 1)
        #expect(value["b"]?.stringValue == "x")
        #expect(value["c"]?[0]?.boolValue == true)
        #expect(value["c"]?[1] == .null)
        #expect(value["c"]?[2]?.doubleValue == 2.5)
        #expect(value["d"]?["e"]?.intValue == -3)

        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(decoded == value)
    }

    @Test func integralNumbersEncodeWithoutFraction() throws {
        let data = try JSONEncoder().encode(JSONValue.object(["id": .number(7)]))
        let text = String(data: data, encoding: .utf8)!
        #expect(text.contains("\"id\":7"))
    }

    /// Server-controlled numbers reach `intValue` on every inbound path, so
    /// an out-of-range one must decline rather than trap the process.
    @Test func outOfRangeIntegralNumbersAreNotInts() throws {
        let json = #"{"huge": 1e300, "big": 1e19, "negative": -1e300, "ok": 9007199254740992}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(value["huge"]?.intValue == nil)
        #expect(value["big"]?.intValue == nil)
        #expect(value["negative"]?.intValue == nil)
        // Still a number, just not one that fits Int.
        #expect(value["huge"]?.doubleValue == 1e300)
        // In-range integral values keep working.
        #expect(value["ok"]?.intValue == 9_007_199_254_740_992)
    }

    @Test func fractionalAndNonFiniteNumbersAreNotInts() {
        #expect(JSONValue.number(2.5).intValue == nil)
        #expect(JSONValue.number(.nan).intValue == nil)
        #expect(JSONValue.number(.infinity).intValue == nil)
        #expect(JSONValue.number(-0.0).intValue == 0)
    }
}

@Suite("Gateway models")
struct GatewayModelTests {
    private func decode(_ json: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test func sessionHandleFromCreate() {
        let result = decode(
            """
            {"session_id": "ab12cd34", "stored_session_id": "20260806_101500_beef",
             "message_count": 0, "messages": [],
             "info": {"model": "m", "cwd": "/tmp/proj", "lazy": true,
                      "desktop_contract": 5, "profile_name": "default"}}
            """)
        let handle = SessionHandle(result: result)
        #expect(handle?.runtimeID == "ab12cd34")
        #expect(handle?.storedID == "20260806_101500_beef")
        #expect(handle?.cwd == "/tmp/proj")
        #expect(handle?.desktopContract == 5)
    }

    @Test func approvalRequestDerivesChoicesWhenListed() {
        let event = GatewayEvent(
            type: "approval.request", sessionID: "ab12cd34",
            payload: decode(
                #"{"command": "rm -rf build/", "description": "recursive delete", "choices": ["once", "session", "always", "deny"]}"#
            ))
        let request = ApprovalRequest(event: event)
        #expect(request?.choices == ["once", "session", "always", "deny"])
        #expect(request?.command == "rm -rf build/")
    }

    @Test func approvalRequestDerivesChoicesWhenAbsent() {
        // allow_permanent absent means permitted (!= false).
        let event = GatewayEvent(
            type: "approval.request", sessionID: "s",
            payload: decode(#"{"command": "x", "allow_session": true}"#))
        #expect(ApprovalRequest(event: event)?.choices == ["once", "session", "always", "deny"])

        let smartDenied = GatewayEvent(
            type: "approval.request", sessionID: "s",
            payload: decode(#"{"command": "x", "smart_denied": true}"#))
        #expect(ApprovalRequest(event: smartDenied)?.choices == ["once", "deny"])
    }

    @Test func clarifyRequestParses() {
        let event = GatewayEvent(
            type: "clarify.request", sessionID: "s",
            payload: decode(
                #"{"request_id": "a1b2c3d4", "question": "Which DB?", "choices": ["Postgres", "MySQL"], "multi_select": true}"#
            ))
        let request = ClarifyRequest(event: event)
        #expect(request?.requestID == "a1b2c3d4")
        #expect(request?.question == "Which DB?")
        #expect(request?.choices == ["Postgres", "MySQL"])
        #expect(request?.multiSelect == true)
    }

    @Test func sessionSummaryAcceptsEpochAndTitle() {
        let row = decode(
            """
            {"session_id": "20260805_090000_cafe", "title": "Fix the tests",
             "cwd": "/w", "git_repo_root": "/w", "git_branch": "main",
             "profile": "work", "pinned": false, "updated_at": 1754500000}
            """)
        let summary = SessionSummary(json: row)
        #expect(summary?.storedID == "20260805_090000_cafe")
        #expect(summary?.title == "Fix the tests")
        #expect(summary?.profile == "work")
        #expect(summary?.updatedAt != nil)
    }
}
