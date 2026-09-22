import HermesKit
import Testing

@testable import MercuryVoice

/// Issue #125, contract v7, Task 9: the controller leases the server-side
/// TTS model for the life of the conversation — acquire when the session
/// opens, release exactly once when it closes, both under the same
/// per-controller lease name (`mercury:conversation:<UUID>`), never a fixed
/// shared name (a shared name would let one device's release drop another's
/// warm-up, since upstream keys leases by name only).
@MainActor
struct TTSLeaseControllerTests {
    @Test func openSessionAcquiresTheLease() async throws {
        let service = ScriptedSessionService()
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "rt1", storedID: "st1"))
        let controller = makeController(service: service)

        try await controller.openSession(mode: .resume(storedID: "st1"))
        await controller.diagnosticAwaitTTSLeaseAcquire()

        #expect(service.ttsLeaseCalls.count == 1)
        let call = try #require(service.ttsLeaseCalls.first)
        #expect(call.active == true)
        #expect(call.lease.hasPrefix("mercury:conversation:"))
        #expect(call.profile == nil)

        await controller.teardown()
    }

    @Test func teardownReleasesTheSameLeaseNameExactlyOnce() async throws {
        let service = ScriptedSessionService()
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "rt1", storedID: "st1"))
        let controller = makeController(service: service)

        try await controller.openSession(mode: .resume(storedID: "st1"))
        await controller.diagnosticAwaitTTSLeaseAcquire()
        await controller.teardown()
        // Idempotent per the controller's own contract (R32): a repeat
        // teardown must not release a second time.
        await controller.teardown()

        let releases = service.ttsLeaseCalls.filter { !$0.active }
        #expect(releases.count == 1)
        let acquiredName = try #require(service.ttsLeaseCalls.first?.lease)
        #expect(releases.first?.lease == acquiredName)
    }

    @Test func twoControllersMintDistinctLeaseNames() async throws {
        // Binding resolution: the lease name is per-conversation, not a
        // fixed shared string — otherwise one controller's release would
        // drop the other's warm-up.
        let serviceA = ScriptedSessionService()
        serviceA.enqueueResume(Fixtures.resumeResult(runtimeID: "rtA", storedID: "stA"))
        let controllerA = makeController(service: serviceA)

        let serviceB = ScriptedSessionService()
        serviceB.enqueueResume(Fixtures.resumeResult(runtimeID: "rtB", storedID: "stB"))
        let controllerB = makeController(service: serviceB)

        try await controllerA.openSession(mode: .resume(storedID: "stA"))
        await controllerA.diagnosticAwaitTTSLeaseAcquire()
        try await controllerB.openSession(mode: .resume(storedID: "stB"))
        await controllerB.diagnosticAwaitTTSLeaseAcquire()

        let nameA = try #require(serviceA.ttsLeaseCalls.first?.lease)
        let nameB = try #require(serviceB.ttsLeaseCalls.first?.lease)
        #expect(nameA != nameB)

        await controllerA.teardown()
        await controllerB.teardown()
    }

    @Test func failedOpenSessionNeverAcquires() async {
        // No scripted resume answer: `resumeSession` throws before a
        // session is ever considered open, so there is nothing to lease.
        let service = ScriptedSessionService()
        let controller = makeController(service: service)

        await controller.begin(mode: .resume(storedID: "st1"))

        #expect(service.ttsLeaseCalls.isEmpty)
        await controller.teardown()
    }
}
