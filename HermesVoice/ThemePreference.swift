import SwiftUI

/// User-selected appearance: follow the system, or force light/dark.
enum ThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    /// UserDefaults key shared by the pickers and the scene roots.
    static let key = "themePreference"

    var id: Self { self }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` inherits the system appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
