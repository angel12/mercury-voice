import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// Keeps the display awake while `active` is true — the conversation screen
/// counts as an active call, so the display never sleeps or auto-locks mid
/// call; normal timeout behavior resumes as soon as the call ends.
///
/// Driven by state rather than the conversation view's appear/disappear:
/// `onDisappear` is unreliable when RootView swaps its content out, which
/// left the iOS idle timer disabled after a call ended.
struct KeepScreenAwake: ViewModifier {
    var active: Bool

    #if os(macOS)
        @State private var activity: NSObjectProtocol?
    #endif

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { _, isActive in
                isActive ? hold() : release()
            }
            .onDisappear(perform: release)
    }

    private func hold() {
        #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
        #elseif os(macOS)
            guard activity == nil else { return }
            activity = ProcessInfo.processInfo.beginActivity(
                options: .idleDisplaySleepDisabled,
                reason: "Active voice conversation")
        #endif
    }

    private func release() {
        #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
        #elseif os(macOS)
            if let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
        #endif
    }
}

extension View {
    /// Prevents display sleep and auto-lock while `active` is true.
    func keepScreenAwake(while active: Bool) -> some View {
        modifier(KeepScreenAwake(active: active))
    }
}
