import HermesKit
import SwiftUI
import Testing

@testable import MercuryVoice

// Harness for driving the *shipping* `ConnectView` controls (issue #88).
//
// The view reaches `ConnectFormState` through two computed `Binding`s and
// reads it back in the Connect button's action. Those are only exercised when
// the controls the view hands them to are the ones a test drives, so each
// control registers what it was given (`Binding.probed(_:)`,
// `ConnectControl.probing(_:)`) and this hosts the real view long enough for
// that registration to happen.
//
// Hosting rather than rendering-free reflection is forced by
// `@Environment(AppModel.self)`: a `View`'s `body` cannot be evaluated, and its
// `@State` cannot be read, until SwiftUI has installed it.

/// The shipping `ConnectView`, rendered in an off-screen window with `model`
/// in its environment.
@MainActor
final class ConnectViewHost {
    #if os(macOS)
        private var window: NSWindow?
    #else
        private var window: UIWindow?
    #endif

    /// Renders the view and returns once its controls have registered.
    init(model: AppModel, sourceLocation: SourceLocation = #_sourceLocation) async {
        ConnectControlProbe.reset()
        ConnectControlProbe.isRecording = true

        let root = ConnectView().environment(model)
        #if os(macOS)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 900),
                styleMask: [.titled], backing: .buffered, defer: true)
            window.contentView = NSHostingView(rootView: root)
        #else
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 900))
            window.rootViewController = UIHostingController(rootView: root)
            window.isHidden = false
        #endif
        self.window = window
        layOut()

        let registered = await wait(for: {
            ConnectControlProbe.field(.server) != nil
                && ConnectControlProbe.field(.token) != nil
                && ConnectControlProbe.action(.connect) != nil
        })
        if !registered {
            Issue.record(
                """
                ConnectView rendered without registering its server field, token field and \
                Connect action. Either a control no longer routes through the bindings that \
                own the ConnectFormState rules, or the view did not render at all.
                """,
                sourceLocation: sourceLocation)
        }
    }

    /// Drops the window and everything the probe recorded. Call from a test's
    /// `defer`: the recorded bindings retain the rendered view.
    func tearDown() {
        #if os(macOS)
            window?.contentView = nil
        #else
            window?.isHidden = true
            window?.rootViewController = nil
        #endif
        window = nil
        ConnectControlProbe.reset()
    }

    /// Types `text` into a field, the way a keystroke does: through the
    /// binding that field was given.
    func type(
        _ text: String, into control: ConnectControl,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        guard let field = ConnectControlProbe.field(control) else {
            Issue.record(
                "no \(control.rawValue) field registered by ConnectView",
                sourceLocation: sourceLocation)
            return
        }
        field.wrappedValue = text
        await pump()
    }

    /// What a field currently shows.
    func text(
        of control: ConnectControl, sourceLocation: SourceLocation = #_sourceLocation
    ) -> String? {
        guard let field = ConnectControlProbe.field(control) else {
            Issue.record(
                "no \(control.rawValue) field registered by ConnectView",
                sourceLocation: sourceLocation)
            return nil
        }
        return field.wrappedValue
    }

    /// Presses a button — its registered action, not a copy of it.
    func press(
        _ control: ConnectControl, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let action = ConnectControlProbe.action(control) else {
            Issue.record(
                "no \(control.rawValue) action registered by ConnectView",
                sourceLocation: sourceLocation)
            return
        }
        action()
    }

    /// Pumps the main run loop until `condition` holds, or for a bounded
    /// number of turns; reports whether it held.
    ///
    /// SwiftUI publishes no "this view re-evaluated" signal, and the Connect
    /// button's action starts a detached `Task` the caller has no handle on,
    /// so unlike the `AppModel` harness's gates there is nothing to await.
    @discardableResult
    func wait(for condition: () -> Bool) async -> Bool {
        for turn in 0..<400 {
            layOut()
            if condition() { return true }
            await Task.yield()
            // The first few turns cover work already queued; only then is
            // there any point slowing down.
            if turn > 2 { try? await Task.sleep(for: .milliseconds(5)) }
        }
        return condition()
    }

    /// Lets SwiftUI take the edit just made — there is no condition to wait
    /// on, since the assertions read the binding's own storage.
    private func pump() async {
        for _ in 0..<3 {
            layOut()
            await Task.yield()
        }
    }

    private func layOut() {
        #if os(macOS)
            window?.contentView?.layoutSubtreeIfNeeded()
        #else
            window?.layoutIfNeeded()
        #endif
    }
}

/// Records what `AppModel.connect` was actually asked to do: which endpoint it
/// probed, and — through the `HermesAuthenticator` it built — the credentials
/// it sent there. A Connect button reading the wrong value becomes visible
/// here and nowhere else.
final class ConnectAttemptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _endpointKeys: [String] = []
    private var _authenticators: [HermesAuthenticator] = []

    var endpointKeys: [String] { lock.withLock { _endpointKeys } }
    var authenticators: [HermesAuthenticator] { lock.withLock { _authenticators } }

    /// Stops `connect()` once the endpoint and credentials are settled, before
    /// it would build a gateway.
    func makeProbe(_ endpoint: ServerEndpoint, _ authenticator: HermesAuthenticator)
        -> any ServerProbing
    {
        lock.withLock {
            _endpointKeys.append(endpoint.key)
            _authenticators.append(authenticator)
        }
        return ScriptedProbe(statusResult: .success(.open))
    }
}
