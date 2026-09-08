import Foundation

/// Test-only one-shot boundary. Finishing broadcasts to every waiter and is
/// synchronous, so `defer { gate.release() }` also handles thrown requirements.
final class HarnessGate: Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let released = AsyncStream<Void>.makeStream()

    func arrive() async {
        entered.continuation.finish()
        for await _ in released.stream {}
    }

    func release() { released.continuation.finish() }

    func waitUntilEntered() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in self.entered.stream {}
                return !Task.isCancelled
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }
            let arrived = await group.next() ?? false
            group.cancelAll()
            return arrived
        }
    }
}
