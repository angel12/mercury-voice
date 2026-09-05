import Foundation
import HermesKit
import Testing

@testable import MercuryVoice

/// Proves the #55 seam makes R02's third race reachable: `.authExpired` can be
/// delivered through the *real* update pump, and the recovery it triggers can
/// be suspended by a test. The race assertions themselves land with the fix.
@MainActor
@Suite("Auth-expiry pump reachability")
struct AuthExpiryReachabilityTests {

    @Test func authExpiredReachesRecoveryThroughTheRealPump() async {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let providersGate = CallGate()
        let auth = ScriptedAuthenticator(providersGate: providersGate)
        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let model = AppModel(
            dependencies: .scripted(
                authenticator: auth,
                probes: ProbeRecorder { _ in .accepting },
                gateway: gateway,
                defaults: defaults))

        // A real connect that runs all the way to gateway construction.
        await model.connect(input: "http://127.0.0.1:8080", token: nil)
        #expect(gateway.connections.count == 1)
        #expect(model.connection != nil)

        // The gateway reports its credentials dead, through the real pump.
        gateway.send(.phase(.authExpired), toConnection: 0)

        // Recovery is now suspended inside AppModel, mid-`authProviders`.
        await providersGate.waitUntilEntered()
        #expect(auth.providerEndpoints == ["http://127.0.0.1:8080"])
        #expect(gateway.stoppedCount == 0)

        await providersGate.release()
    }
}
