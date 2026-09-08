import Foundation
import HermesKit
import Network
import Testing

@testable import MercuryVoice

@MainActor
@Suite struct NetworkRecoveryTests {
    @Test func monitorIgnoresInitialDuplicateAndCancelledDelivery() {
        let monitor = NetworkPathMonitor(startMonitoring: { _ in })
        var changes = 0
        monitor.start { changes += 1 }
        let path = NWPathMonitor().currentPath
        monitor.receive(path)
        monitor.receive(path)
        #expect(changes == 0)
        monitor.cancel()
        monitor.receive(path)
        #expect(changes == 0)

        // The adapter uses this exact generic filter with NWPath equality.
        var filter = PathChangeFilter<String>()
        let accepted = ["wifi-a", "wifi-a", "offline", "wifi-b", "wifi-b"].map { filter.accept($0) }
        #expect(accepted == [false, false, true, true, false])
    }
    @Test func pathSignalUsesProbeThenPokeAndRetiredProbeCannotPoke() async throws {
        let isolated = makeTestDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let monitors = PathMonitorFactory()
        let calls = RecoveryCalls()
        let gate = CallGate()
        var deps = AppDependencies.scripted(
            probes: ProbeRecorder(probe: { _ in .accepting }), gateway: gateway,
            defaults: isolated.defaults)
        deps.makePathMonitor = { monitors.make() }
        deps.verifyGateway = { connection in
            await calls.append("probe", connection)
            await gate.arrive()
        }
        deps.pokeGateway = { await calls.append("poke", $0) }
        let model = AppModel(dependencies: deps)
        defer { model.disconnect() }
        await model.connect(input: "localhost:8765", token: nil)
        let first = try #require(monitors.all.first)
        first.emit()
        let oldTask = try #require(model.recoveryTask)
        await gate.waitUntilEntered()
        await model.connect(input: "localhost:8766", token: nil)
        #expect(first.cancelled)
        await gate.release()
        await oldTask.value
        #expect(await calls.names == ["probe"])
        first.emit()  // Deliberately deliver an already-queued callback after cancellation.
        #expect(model.recoveryTask == nil)
        let second = try #require(monitors.all.last)
        second.emit()
        await model.recoveryTask?.value
        #expect(await calls.names == ["probe", "probe", "poke"])
        #expect(await calls.lastConnection === model.connection)
        model.disconnect()
        #expect(second.cancelled)
        second.emit()
        #expect(model.recoveryTask == nil)
    }

    @Test func retryFinishingAfterReplacementStopsOnlyItsRetiredConnection() async throws {
        let isolated = makeTestDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let calls = RecoveryCalls()
        let gate = CallGate()
        var deps = AppDependencies.scripted(
            probes: ProbeRecorder(probe: { _ in .accepting }), gateway: gateway,
            defaults: isolated.defaults)
        deps.startGateway = {
            gateway.start($0)
            await calls.append("start", $0)
            if await calls.names == ["start", "start"] { await gate.arrive() }
        }
        deps.stopGateway = {
            gateway.stop($0)
            await calls.append("stop", $0)
        }
        let model = AppModel(dependencies: deps)
        defer { model.disconnect() }
        await model.connect(input: "localhost:8765", token: nil)
        let retired = try #require(model.connection)
        gateway.send(.phase(.unreachable(reason: "Server unreachable")), toConnection: 0)
        #expect(await eventuallyOnMain { model.canRetryConnection })
        let retry = Task { await model.manualRetry() }
        await gate.waitUntilEntered()
        model.disconnect()
        await model.pendingTeardown?.value
        await model.connect(input: "localhost:8766", token: nil)
        let replacement = try #require(model.connection)
        await gate.release()
        await retry.value
        #expect(await calls.names == ["start", "start", "stop", "start", "stop"])
        #expect(await calls.lastConnection === retired)
        #expect(model.connection === replacement)
        #expect(!gateway.wasStopped(replacement))
        model.disconnect()
        await model.pendingTeardown?.value
    }

    @Test func unreachableUpdateOffersManualRetryAndStopsAutomaticSignals() async throws {
        let isolated = makeTestDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suiteName) }
        let gateway = GatewayRecorder()
        defer { gateway.finishAll() }
        let monitors = PathMonitorFactory()
        let calls = RecoveryCalls()
        var deps = AppDependencies.scripted(
            probes: ProbeRecorder(probe: { _ in .accepting }), gateway: gateway,
            defaults: isolated.defaults)
        deps.makePathMonitor = { monitors.make() }
        deps.startGateway = {
            gateway.start($0)
            await calls.append("start", $0)
        }
        deps.verifyGateway = { await calls.append("probe", $0) }
        deps.pokeGateway = { await calls.append("poke", $0) }
        let model = AppModel(dependencies: deps)
        defer { model.disconnect() }
        await model.connect(input: "localhost:8765", token: nil)
        let connection = try #require(model.connection)
        let pump = try #require(model.updatePump)
        gateway.send(
            .phase(.unreachable(reason: "Server unreachable after 10 failed connection attempts.")),
            toConnection: 0)
        #expect(await eventuallyOnMain { model.canRetryConnection })
        #expect(model.connectError?.contains("Server unreachable") == true)
        #expect(!model.isConnected)
        #expect(monitors.all.first?.cancelled == true)
        model.appBecameActive()
        await model.recoveryTask?.value
        #expect(await calls.names == ["start"])
        let host = await ConnectViewHost(model: model)
        defer { host.tearDown() }
        host.press(.retryConnection)
        #expect(await eventuallyOnMain { model.phase == .connecting(attempt: 0) })
        // Synchronize with the start call rather than a scheduled button task.
        #expect(await eventuallyOnMain { monitors.all.count == 2 })
        #expect(await calls.names == ["start", "start"])
        #expect(model.connection === connection)
        #expect(model.connectError == nil)
        #expect(monitors.all.count == 2)
        gateway.send(.phase(.connecting(attempt: 7)), toConnection: 0)
        gateway.finishAll()
        await pump.value
        #expect(model.phase == .connecting(attempt: 7))
        await model.pendingTeardown?.value
    }
}

@MainActor
private final class PathMonitorFactory {
    var all: [ScriptedPathMonitor] = []
    func make() -> ScriptedPathMonitor {
        let monitor = ScriptedPathMonitor()
        all.append(monitor)
        return monitor
    }
}

@MainActor
final class ScriptedPathMonitor: NetworkPathMonitoring {
    var callback: (@MainActor @Sendable () -> Void)?
    var cancelled = false
    func start(onChange: @escaping @MainActor @Sendable () -> Void) { callback = onChange }
    func cancel() { cancelled = true }
    func emit() { callback?() }
}

private actor RecoveryCalls {
    var names: [String] = []
    var lastConnection: HermesConnection?
    func append(_ name: String, _ connection: HermesConnection) {
        names.append(name)
        lastConnection = connection
    }
}
