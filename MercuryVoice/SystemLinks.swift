import Foundation
import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// Public pages and system destinations the app links out to.
enum SystemLinks {
    static let privacyPolicy = URL(string: "https://angel12.github.io/mercury-voice/privacy-policy")!
    static let support = URL(string: "https://angel12.github.io/mercury-voice/support")!

    /// The system's microphone-privacy setting for this app: the iOS
    /// Settings page for the app, or the macOS Privacy & Security pane.
    @MainActor
    static func openMicrophonePrivacySettings() {
        #if os(iOS)
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        #else
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            NSWorkspace.shared.open(url)
        #endif
    }
}

/// Privacy policy + support rows, shared by the macOS Settings pane and the
/// iOS settings sheet (App Store guideline 5.1.1: the policy must be
/// reachable inside the app).
struct AboutLinksSection: View {
    var body: some View {
        Section("About") {
            Link(destination: SystemLinks.privacyPolicy) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
            Link(destination: SystemLinks.support) {
                Label("Support", systemImage: "questionmark.circle")
            }
        }
    }
}
