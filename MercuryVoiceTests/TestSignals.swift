import Foundation

/// One-shot async signal. `signal()` is idempotent and `wait()` returns
/// immediately once it has fired, so there is no ordering requirement between
/// the two sides — and therefore no reason to sleep or poll.
actor Signal {
    private var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSet else { return }
        isSet = true
        let resuming = waiters
        waiters = []
        for continuation in resuming { continuation.resume() }
    }

    func wait() async {
        if isSet { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// An awaitable call boundary. The code under test calls `arrive()`, which
/// announces that it reached the call and then suspends until the test calls
/// `release()`. That is what lets a test start `signIn`, act while the login
/// is genuinely in flight, and only then let it finish — deterministically,
/// with no `Task.sleep` anywhere.
struct CallGate: Sendable {
    let entered = Signal()
    let released = Signal()

    /// Called from the subject, inside the seam.
    func arrive() async {
        await entered.signal()
        await released.wait()
    }

    /// Called from the test: returns once the subject is suspended in `arrive()`.
    func waitUntilEntered() async { await entered.wait() }

    /// Called from the test: lets the suspended call complete.
    func release() async { await released.signal() }
}
