import Foundation
import Testing

@testable import HermesKit

/// Issue #74: REST JSON `detail` strings must not bypass the 300-byte
/// plain-body cap on the real `HermesRESTClient.perform` path.
@Suite("Bounded REST error details")
struct RESTHTTPErrorDetailTests {
    private static let displayLimit = HTTPErrorDetail.displayLimit

    @Test func healthThrowsCappedJSONDetailThroughPerform() async throws {
        let message = String(repeating: "B", count: 400) + "REST-TAIL"
        let body = Data("{\"detail\":\"\(message)\"}".utf8)
        let server = try await ScriptedHTTPServer.start(status: 500, body: body)
        defer { server.stop() }

        let endpoint = try ServerEndpoint.parse("http://127.0.0.1:\(server.port)").endpoint
        let client = HermesRESTClient(endpoint: endpoint, token: nil)
        do {
            try await client.health()
            Issue.record("expected HTTP error")
        } catch let HermesError.httpError(status, detail) {
            #expect(status == 500)
            let text = detail ?? ""
            #expect(text.utf8.count <= Self.displayLimit)
            #expect(text.hasPrefix("BBB"))
            #expect(!text.contains("REST-TAIL"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func displayCapDropsSplitScalarWithoutReplacement() {
        let text = String(repeating: "A", count: 299) + "😀"
        #expect(text.utf8.count == 303)
        let detail = HTTPErrorDetail.displayed(text)
        #expect(detail.utf8.count <= Self.displayLimit)
        #expect(detail == String(repeating: "A", count: 299))
        #expect(!detail.contains("\u{FFFD}"))
        #expect(!detail.contains("😀"))
    }

    @Test func displayCapPreservesExactByteBoundary() {
        let ascii = String(repeating: "B", count: Self.displayLimit)
        #expect(HTTPErrorDetail.displayed(ascii) == ascii)

        let emoji = String(repeating: "C", count: 296) + "😀"
        #expect(emoji.utf8.count == Self.displayLimit)
        #expect(HTTPErrorDetail.displayed(emoji) == emoji)
        #expect(HTTPErrorDetail.displayed(emoji).contains("😀"))
    }

    @Test func redactsBeforeTruncatingDisplay() {
        let secret = "sk-" + String(repeating: "S", count: 48)
        let text = String(repeating: "A", count: 280) + " \(secret) TAIL"
        let detail = HTTPErrorDetail.displayed(text)
        #expect(!detail.contains("SSSSSSSS"))
        #expect(detail.contains("«redacted»"))
        #expect(detail.utf8.count <= Self.displayLimit)
    }

    @Test func restJSONDetailDropsSplitScalar() {
        let message = String(repeating: "A", count: 299) + "😀"
        let detail = HTTPErrorDetail.restJSONDetail(
            Data("{\"detail\":\"\(message)\"}".utf8)) ?? ""
        #expect(detail.utf8.count <= Self.displayLimit)
        #expect(!detail.contains("\u{FFFD}"))
        #expect(!detail.contains("😀"))
    }

    @Test func authenticatorPerformCapsJSONDetail() async throws {
        let message = String(repeating: "C", count: 400) + "AUTH-TAIL"
        let body = Data("{\"detail\":\"\(message)\"}".utf8)
        let server = try await ScriptedHTTPServer.start(status: 502, body: body)
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/x")!)
        request.httpMethod = "GET"
        let session = URLSession(configuration: .ephemeral)
        do {
            _ = try await HermesAuthenticator.perform(request, on: session)
            Issue.record("expected HTTP error")
        } catch let HermesError.httpError(status, detail) {
            #expect(status == 502)
            let text = detail ?? ""
            #expect(text.utf8.count <= Self.displayLimit)
            #expect(!text.contains("AUTH-TAIL"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
