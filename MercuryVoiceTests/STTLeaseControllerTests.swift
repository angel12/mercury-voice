import HermesKit
import Testing

@testable import MercuryVoice

/// Issue #146: `RestTranscriber` acquires the backend's STT warm-up lease at
/// every listen start under the controller's per-conversation name; the
/// controller releases it exactly once when the session closes.
@MainActor
struct STTLeaseControllerTests {
    @Test func closingTheSessionReleasesTheLeaseExactlyOnce() async throws {
        let service = ScriptedSessionService()
        service.enqueueResume(Fixtures.resumeResult(runtimeID: "rt1", storedID: "st1"))
        let controller = makeController(service: service)

        try await controller.openSession(mode: .resume(storedID: "st1"))
        #expect(service.sttLeaseCalls.isEmpty)  // acquiring is the transcriber's job
        await controller.teardown()
        await controller.teardown()
        await controller.diagnosticAwaitSTTLeaseRelease()

        #expect(service.sttLeaseCalls.count == 1)
        let release = try #require(service.sttLeaseCalls.first)
        #expect(release.active == false)
        #expect(release.lease == controller.sttLeaseName)
        #expect(release.lease.hasPrefix("mercury:voice-input:"))
    }

    @Test func eachControllerMintsItsOwnLeaseName() {
        let a = makeController(service: ScriptedSessionService())
        let b = makeController(service: ScriptedSessionService())
        #expect(a.sttLeaseName != b.sttLeaseName)
    }
}
