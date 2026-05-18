import Foundation

/// Categories of the redesigned Settings screen. Each maps to one
/// pane rendered in `SettingsTabView`. Order = display order in the
/// secondary sidebar. Default selection on tab open is `.general`.
///
/// The taxonomy comes from the `app/settings.html` design handoff:
/// the old flat 6-section list (General · Shortcuts · Microphone ·
/// Audio · API · System) collapses into 5 task-grouped categories
/// — Shortcuts / Microphone / Audio fold into Recording, and System
/// splits into Language & Paste plus a new About surface.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case recording
    case languagePaste
    case apiUsage
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:       return "General"
        case .recording:     return "Recording"
        case .languagePaste: return "Language & Paste"
        case .apiUsage:      return "API & Usage"
        case .about:         return "About"
        }
    }

    /// Mono breadcrumb pill rendered next to the content header.
    var crumb: String { "Settings / " + label }

    /// Sidebar glyph. Matches the design's `data-icon` set.
    var icon: DSIconName {
        switch self {
        case .general:       return .cog
        case .recording:     return .bolt
        case .languagePaste: return .chat
        case .apiUsage:      return .lock
        case .about:         return .info
        }
    }
}
