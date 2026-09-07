import SwiftUI

/// The Connect screen's three input controls, named so a test can address the
/// binding or action the shipping view actually handed to one (issue #88).
enum ConnectControl: String, Sendable {
    case server
    case token
    case connect
}

extension Binding where Value == String {
    /// Identity. In a debug build it also hands `self` to `ConnectControlProbe`
    /// while a test is recording, so the test drives the very binding the
    /// field writes through — not a second one that merely looks the same.
    @MainActor
    func probed(_ control: ConnectControl) -> Binding<String> {
        #if DEBUG
            ConnectControlProbe.record(control, field: self)
        #endif
        return self
    }
}

extension ConnectControl {
    /// Identity, as `Binding.probed(_:)` is, for a button's action closure.
    @MainActor
    func probing(_ action: @escaping () -> Void) -> () -> Void {
        #if DEBUG
            ConnectControlProbe.record(self, action: action)
        #endif
        return action
    }
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
    /// So each Connect control passes what it was given through `probed`, and
    /// this records it. A test then types into the recorded binding and presses
    /// the recorded action, which is the same value and the same closure the
    /// user's keystroke and press reach. Nothing in the app reads any of this,
    /// and nothing is recorded until a test sets `isRecording`.
    @MainActor
    enum ConnectControlProbe {
        /// Off by default: recording retains the bindings, which retain the
        /// rendered view's state.
        static var isRecording = false

        private static var fields: [ConnectControl: Binding<String>] = [:]
        private static var actions: [ConnectControl: () -> Void] = [:]

        static func field(_ control: ConnectControl) -> Binding<String>? { fields[control] }
        static func action(_ control: ConnectControl) -> (() -> Void)? { actions[control] }

        static func record(_ control: ConnectControl, field: Binding<String>) {
            guard isRecording else { return }
            fields[control] = field
        }

        static func record(_ control: ConnectControl, action: @escaping () -> Void) {
            guard isRecording else { return }
            actions[control] = action
        }

        /// Stops recording and drops everything recorded so far.
        static func reset() {
            isRecording = false
            fields = [:]
            actions = [:]
        }
    }
#endif
