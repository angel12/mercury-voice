import Foundation
import HermesKit
import Testing

@testable import MercuryVoice

/// Issue #60, app half: an access refusal (WS 4403 / 403 on the upgrade) is
/// terminal but is *not* a credential failure, so the screen it produces must
/// differ from `.authExpired`'s. The package tests prove the phase; these
/// prove what the user is left looking at, through the real update pump.
@MainActor
@Suite("Refused-connection recovery")
struct ConnectionRefusedRecoveryTests {
    private static let reason =
        "refused (4403) — the server refused this connection; dial it by exactly "
        + "the address it bound to, or check its access rules"

    @Test func refusedShowsTheServerReasonAndAsksForNoCredentials() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let auth = ScriptedAuthenticator()
        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let model = AppModel(
            dependencies: .scripted(
                authenticator: auth,
                probes: ProbeRecorder { _ in .accepting },
                gateway: gateway,
                defaults: defaults))

        await model.connect(input: "http://127.0.0.1:8080", token: nil)
        #expect(model.connection != nil)

        gateway.send(.phase(.refused(reason: Self.reason)), toConnection: 0)

        // The refusal is on screen…
        #expect(await eventuallyOnMain { model.connectError == Self.reason })
        // …the connection is released rather than left "Reconnecting…"…
        #expect(model.connection == nil)
        #expect(gateway.stoppedCount == 1)
        #expect(!model.isConnected)
        // …and nothing asked the user to re-authenticate: no sign-in form,
        // and no provider lookup on the way to one.
        #expect(model.pendingLogin == nil)
        #expect(auth.providerEndpoints.isEmpty)
        #expect(model.connectError?.contains("dashboard") != true)
        #expect(model.connectError?.contains("expired") != true)
    }

    @Test func refusalWithoutAReasonStillExplainsItself() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let model = AppModel(
            dependencies: .scripted(
                probes: ProbeRecorder { _ in .accepting },
                gateway: gateway,
                defaults: defaults))

        await model.connect(input: "http://127.0.0.1:8080", token: nil)
        gateway.send(.phase(.refused(reason: nil)), toConnection: 0)

        #expect(await eventuallyOnMain { model.connectError != nil })
        #expect(model.connectError == "The server refused this connection.")
        #expect(model.pendingLogin == nil)
    }
}

/// Poll a main-actor condition: the pump publishes from its own task, so the
/// assertion waits for the state instead of a guessed sleep.
@MainActor
func eventuallyOnMain(
    timeout: Double = 3, _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
