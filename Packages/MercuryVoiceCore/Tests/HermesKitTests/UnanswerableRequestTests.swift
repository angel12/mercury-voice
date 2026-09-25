import Foundation
import Testing

@testable import HermesKit

/// Issue #130 — server requests the app cannot answer (a password, a secret,
/// a vault prompt, or an approval/clarify it cannot decode) are shown to the
/// user with what was asked and a Decline that sends the backend's own
/// "skipped" answer. Desktop GUI bridges are never shown.
@Suite("Unanswerable server requests")
struct UnanswerableRequestTests {
    private func request(_ method: String, _ params: [String: JSONValue]) -> ServerRequest {
        var params = params
        params["session_id"] = .string("s1")
        return ServerRequest(id: "srq-0123456789ab", method: method, params: .object(params))
    }

    private func detail(_ request: UnanswerableRequest?, _ label: String) -> String? {
        request?.details.first { $0.label == label }?.value
    }

    @Test func sudoShowsTheCommandAndDeclinesWithAnEmptyValue() throws {
        let decoded = try #require(
            UnanswerableRequest(serverRequest: request("sudo", ["command": "apt install jq"])))
        #expect(decoded.id == "srq-0123456789ab")
        #expect(decoded.method == "sudo")
        #expect(decoded.sessionID == "s1")
        #expect(decoded.title == "Hermes needs your sudo password")
        #expect(decoded.details == [.init(label: "Command", value: "apt install jq", monospaced: true)])
        #expect(decoded.declineResult == .object(["value": ""]))
        #expect(decoded.spokenNotice.contains("sudo password"))
    }

    @Test func secretShowsTheVariablePromptAndTextMetadata() throws {
        let decoded = try #require(
            UnanswerableRequest(
                serverRequest: request(
                    "secret",
                    [
                        "env_var": "OPENAI_API_KEY", "prompt": "Paste your OpenAI key",
                        "metadata": ["skill": "image-gen", "nested": ["a": 1], "retries": 2],
                    ])))
        #expect(decoded.title == "Hermes needs a secret value")
        #expect(detail(decoded, "Variable") == "OPENAI_API_KEY")
        #expect(detail(decoded, "Prompt") == "Paste your OpenAI key")
        #expect(detail(decoded, "skill") == "image-gen")
        #expect(detail(decoded, "retries") == "2")
        // Structured metadata has no one-line rendering; it is left out.
        #expect(detail(decoded, "nested") == nil)
        #expect(decoded.declineResult == .object(["value": ""]))
    }

    @Test func vaultPromptsShowTheirSiteDetails() throws {
        let unlock = UnanswerableRequest(
            serverRequest: request(
                "vault.unlock_prompt", ["backend": "bitwarden", "display_name": "Bitwarden"]))
        #expect(unlock?.title == "Hermes wants to unlock Bitwarden")
        #expect(detail(unlock, "Backend") == "bitwarden")

        let save = UnanswerableRequest(
            serverRequest: request(
                "vault.save_login", ["origin": "https://example.com", "site": "Example"]))
        #expect(save?.title == "Hermes wants to save a login")
        #expect(detail(save, "Site") == "Example")
        #expect(detail(save, "Origin") == "https://example.com")

        let code = UnanswerableRequest(
            serverRequest: request("vault.code", ["site": "GitHub", "hint": "Authenticator app"]))
        #expect(code?.title == "Hermes needs a one-time code")
        #expect(detail(code, "Site") == "GitHub")
        #expect(detail(code, "Hint") == "Authenticator app")

        for decoded in [unlock, save, code] {
            #expect(decoded?.declineResult == .object(["value": ""]))
        }
    }

    @Test func emptyFieldsAreLeftOutRatherThanShownBlank() throws {
        let decoded = try #require(
            UnanswerableRequest(serverRequest: request("sudo", ["command": ""])))
        #expect(decoded.details.isEmpty)
        let code = try #require(UnanswerableRequest(serverRequest: request("vault.code", [:])))
        #expect(code.details.isEmpty)
    }

    @Test func anUndecodableApprovalShowsWhatCameThroughAndDeclinesWithDeny() throws {
        // No `session_id` → `ApprovalRequest(serverRequest:)` cannot decode it.
        let raw = ServerRequest(
            id: "srq-a", method: "approval",
            params: .object(["command": "rm -rf build", "description": "Delete build output"]))
        #expect(ApprovalRequest(serverRequest: raw) == nil)
        let decoded = try #require(UnanswerableRequest(serverRequest: raw))
        #expect(decoded.title == "Hermes is asking for approval")
        #expect(detail(decoded, "Command") == "rm -rf build")
        #expect(detail(decoded, "Description") == "Delete build output")
        #expect(decoded.declineResult == .object(["choice": "deny"]))
    }

    @Test func anUndecodableBatchClarifyListsItsQuestionsAndDeclinesWithCancelAll() throws {
        // The second entry has no qid, so the batch fails closed.
        let raw = request(
            "clarify",
            ["questions": [["qid": "q1", "question": "Which branch?"], ["question": "Squash?"]]])
        #expect(ClarifyRequest(serverRequest: raw) == nil)
        let decoded = try #require(UnanswerableRequest(serverRequest: raw))
        #expect(decoded.title == "Hermes has questions for you")
        #expect(detail(decoded, "Question 1") == "Which branch?")
        #expect(detail(decoded, "Question 2") == "Squash?")
        // `ClarifyResult` with neither answer nor answers is cancel-all.
        #expect(decoded.declineResult == .object([:]))
    }

    @Test func requestsTheAppCanRenderAreNotUnanswerable() {
        #expect(
            UnanswerableRequest(
                serverRequest: request("approval", ["request_id": "a1", "command": "ls"])) == nil)
        #expect(
            UnanswerableRequest(serverRequest: request("clarify", ["question": "Which?"])) == nil)
    }

    @Test(arguments: ["terminal.read", "preview.read", "preview.act", "window.read", "tour", "future.thing"])
    func desktopBridgesAndUnknownMethodsAreNeverShown(method: String) {
        #expect(UnanswerableRequest(serverRequest: request(method, ["action": "click"])) == nil)
        #expect(!ServerRequest.routedMethods.contains(method))
    }

    @Test func everyShownMethodIsRouted() {
        for method in ["approval", "clarify", "sudo", "secret", "vault.unlock_prompt", "vault.save_login", "vault.code"] {
            #expect(ServerRequest.routedMethods.contains(method))
        }
    }
}
