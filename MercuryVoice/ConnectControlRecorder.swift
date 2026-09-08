import SwiftUI

/// The Connect screen's three input controls, named so a test can address the
/// binding or action the shipping view actually handed to one (issue #88).
enum ConnectControl: String, Sendable {
    case server
    case token
    case connect
    case retryConnection
}

#if DEBUG
    /// Test seam for issue #88.
    ///
    /// `ConnectFormStateTests` covers the token/endpoint rule itself. What it
    /// cannot see is whether the shipping fields still route through that rule:
    /// a field re-bound to a stray `@State` string, or a Connect button reading
    /// something other than what the fields wrote, reintroduces R01's
    /// cross-server credential disclosure with all of those tests still green.
    ///
    /// So each Connect control passes what it was given through
    /// `ConnectView.probed(_:_:)`, which hands it to the recorder in the view's
    /// environment. A test then types into the recorded binding and presses the
    /// recorded action, which are the same value and the same closure the
    /// user's keystroke and press reach.
    ///
    /// A recorder belongs to whoever put it in one view's environment, and only
    /// that view can write to it. Every other `ConnectView` — another test's,
    /// or the app's own window, which puts none there at all — records nowhere.
    /// That is what makes a recorded control *this* host's control: no other
    /// view can replace an entry a test is about to drive, or supply one the
    /// test expects to find missing, and dropping one host's recordings leaves
    /// every other host's intact.
    @MainActor
    final class ConnectControlRecorder {
        private var fields: [ConnectControl: Binding<String>] = [:]
        private var actions: [ConnectControl: () -> Void] = [:]

        func field(_ control: ConnectControl) -> Binding<String>? { fields[control] }
        func action(_ control: ConnectControl) -> (() -> Void)? { actions[control] }

        func record(_ control: ConnectControl, field: Binding<String>) {
            fields[control] = field
        }

        func record(_ control: ConnectControl, action: @escaping () -> Void) {
            actions[control] = action
        }

        /// Drops everything recorded so far, and with it the hold those
        /// bindings keep on the rendered view's state.
        func reset() {
            fields = [:]
            actions = [:]
        }
    }

    private struct ConnectControlRecorderKey: EnvironmentKey {
        static let defaultValue: ConnectControlRecorder? = nil
    }

    extension EnvironmentValues {
        /// Set by an issue #88 test on the single view it hosts. Every other
        /// view, the app's own included, inherits `nil` and records nothing.
        var connectControlRecorder: ConnectControlRecorder? {
            get { self[ConnectControlRecorderKey.self] }
            set { self[ConnectControlRecorderKey.self] = newValue }
        }
    }
#endif
