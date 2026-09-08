import HermesKit
import SwiftUI
import Testing

@testable import MercuryVoice

// Harness for driving the *shipping* `ConnectView` controls (issue #88).
//
// The view reaches `ConnectFormState` through two computed `Binding`s and
// reads it back in the Connect button's action. Those are only exercised when
// the controls the view hands them to are the ones a test drives, so each
// control registers what it was given (`ConnectView.probed(_:_:)`) with the
// `ConnectControlRecorder` in its environment, and this hosts the real view
// with such a recorder long enough for that registration to happen.
//
// Hosting rather than rendering-free reflection is forced by
// `@Environment(AppModel.self)`: a `View`'s `body` cannot be evaluated, and its
// `@State` cannot be read, until SwiftUI has installed it.
//
// Each host owns its recorder, so what it drives is its own view's controls:
// no other `ConnectView` in this process — another host's, or the app window's
// — can write there, and tearing a host down touches nobody else's.

/// The shipping `ConnectView`, rendered in an off-screen window with `model`
/// in its environment.
@MainActor
final class ConnectViewHost {
    /// What this host's view registered. Nothing else can reach it.
    let controls: ConnectControlRecorder

    #if os(macOS)
        private var window: NSWindow?
    #else
        private var window: UIWindow?
    #endif

    /// Renders the view with `controls` in its environment and returns once
    /// its controls have registered there.
    init(
        model: AppModel, controls: ConnectControlRecorder = ConnectControlRecorder(),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        self.controls = controls
        render(ConnectView().environment(\.connectControlRecorder, controls), for: model)

        let registered = await wait(for: {
            controls.field(.server) != nil
                && controls.field(.token) != nil
                && controls.action(.connect) != nil
        })
        if !registered {
            Issue.record(
                """
                ConnectView rendered without registering its server field, token field and \
                Connect action with this host's recorder. Either a control no longer routes \
                through the bindings that own the ConnectFormState rules, or the view did \
                not render at all.
                """,
                sourceLocation: sourceLocation)
        }
    }

    /// Renders the view the way the app's own window does: with no recorder
    /// anywhere in its environment. This host's `controls` therefore stay
    /// empty, and so must every other host's.
    init(ordinaryAppViewFor model: AppModel) async {
        controls = ConnectControlRecorder()
        render(ConnectView(), for: model)
        await pump()
    }

    private func render(_ root: some View, for model: AppModel) {
        let root = root.environment(model)
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
    }

    /// Drops this host's window and its recordings. Call from a test's
    /// `defer`: the recorded bindings retain the rendered view.
    func tearDown() {
        #if os(macOS)
            window?.contentView = nil
        #else
            window?.isHidden = true
            window?.rootViewController = nil
        #endif
        window = nil
        controls.reset()
    }

    /// Types `text` into a field, the way a keystroke does: through the
    /// binding that field was given.
    func type(
        _ text: String, into control: ConnectControl,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        guard let field = controls.field(control) else {
            Issue.record(
                "no \(control.rawValue) field registered by ConnectView",
                sourceLocation: sourceLocation)
            return
        }
        field.wrappedValue = text
        await pump()
    }

    /// What a field's binding currently holds — its `get`, which reads the
    /// view's own `ConnectFormState`. Not what a rendered control displays.
    func text(
        of control: ConnectControl, sourceLocation: SourceLocation = #_sourceLocation
    ) -> String? {
        guard let field = controls.field(control) else {
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
        guard let action = controls.action(control) else {
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
    /// button's action starts an unstructured `Task` the caller has no handle
    /// on, so unlike the `AppModel` harness's gates there is nothing to await:
    /// a test observes the work through the model it can see instead.
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

    /// Gives SwiftUI a few turns with the edit just made. Not a completion
    /// signal: nothing here proves a re-render finished, and no assertion
    /// needs one — the bindings' `get`/`set` run synchronously against the
    /// view's `ConnectFormState`. Waits that must observe something use
    /// `wait(for:)`.
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
    /// it would build a gateway. Validation then fails (`ScriptedProbe`'s
    /// default), which is the attempt's terminal state: `connectError`.
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
