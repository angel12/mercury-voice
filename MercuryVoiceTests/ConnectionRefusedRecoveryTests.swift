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
        let stop = HarnessGate()
        defer { stop.release() }
        var dependencies = AppDependencies.scripted(
            authenticator: auth,
            probes: ProbeRecorder { _ in .accepting },
            gateway: gateway,
            defaults: defaults)
        dependencies.stopGateway = { connection in
            await stop.arrive()
            gateway.stop(connection)
        }
        let model = AppModel(dependencies: dependencies)

        await model.connect(input: "http://127.0.0.1:8080", token: nil)
        #expect(model.connection != nil)

        let pump = model.updatePump
        gateway.send(.phase(.refused(reason: Self.reason)), toConnection: 0)

        #expect(await stop.waitUntilEntered())
        await pump?.value
        // The refusal is on screen, but the owned stop is still held.
        #expect(model.connectError == Self.reason)
        #expect(model.connection == nil)
        // Error publication is deliberately earlier than gateway completion.
        #expect(gateway.stoppedCount == 0)
        let teardown = model.pendingTeardown
        #expect(teardown != nil)
        stop.release()
        await teardown?.value
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
        let pump = model.updatePump
        gateway.send(.phase(.refused(reason: nil)), toConnection: 0)

        // Join the producer before reading the teardown it schedules. This
        // model has just one connection and no earlier conversation teardown.
        await pump?.value
        let teardown = model.pendingTeardown
        #expect(teardown != nil)
        await teardown?.value
        #expect(gateway.stoppedCount == 1)
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
