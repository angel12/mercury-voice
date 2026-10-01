import Foundation

/// "Interrupt by speaking" (issue #146). Upstream's desktop honours the
/// backend's `voice.barge_in`, but the only way to read that flag is the whole
/// profile config, keys included, so the app keeps its own switch instead.
/// On by default, matching `voice.barge_in`'s default. Off, talking over a
/// reply no longer interrupts it; Stop still does.
public enum BargeInPreference {
    public static let key = "bargeInEnabled"
    public static let defaultEnabled = true

    public static var isEnabled: Bool { isEnabled(in: .standard) }

    /// The same read against an explicit store, so tests never write the
    /// process-global defaults other suites would see.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultEnabled }
        return defaults.bool(forKey: key)
    }
}
