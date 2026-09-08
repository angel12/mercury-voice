import Foundation
import Network

/// One monitor per connection lifetime. Callbacks are explicit signals, never a timer.
@MainActor
protocol NetworkPathMonitoring: AnyObject {
    func start(onChange: @escaping @MainActor @Sendable () -> Void)
    func cancel()
}

@MainActor
final class NetworkPathMonitor: NetworkPathMonitoring {
    private let monitor = NWPathMonitor()
    private let startMonitoring: (NWPathMonitor) -> Void

    init(
        startMonitoring: @escaping (NWPathMonitor) -> Void = {
            $0.start(queue: DispatchQueue(label: "MercuryVoice.network-path"))
        }
    ) {
        self.startMonitoring = startMonitoring
    }
    private var onChange: (@MainActor @Sendable () -> Void)?
    private var changes = PathChangeFilter<NWPath>()
    private var cancelled = false

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in self?.receive(path) }
        }
        startMonitoring(monitor)
    }

    /// Shared by the live callback and deterministic adapter tests.
    func receive(_ path: NWPath) {
        guard !cancelled, changes.accept(path) else { return }
        onChange?()
    }

    func cancel() {
        cancelled = true
        onChange = nil
        monitor.cancel()
    }

    deinit { monitor.cancel() }
}

/// Use Network's path equality, not a lossy interface/status fingerprint:
/// two different routes can have identical visible interface properties.
struct PathChangeFilter<Path: Equatable> {
    private var previous: Path?

    mutating func accept(_ path: Path) -> Bool {
        let old = previous
        previous = path
        return old.map { $0 != path } ?? false
    }
}
