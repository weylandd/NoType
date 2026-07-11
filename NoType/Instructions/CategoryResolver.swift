import ApplicationServices
import Foundation
import OSLog

/// Plain-value snapshot of the system-wide focused AX element, just the
/// attributes `CategoryResolver` cares about. Read once, off any actor,
/// then handed to the pure `resolve(...)` decision. Sendable so the
/// snapshot can cross isolation boundaries safely.
struct FocusedFieldSnapshot: Sendable, Equatable {
    let role: String?
    let subrole: String?
    let identifier: String?
    let title: String?
}

/// Resolves the *effective* category for the current session by layering
/// a runtime AX override on top of the cached `bundleID → category`
/// assignment.
///
/// The override exists because a single bundle (e.g. `com.google.Chrome`)
/// hosts many distinct typing contexts — Twitter, Gmail, the omnibox —
/// and the categorizer can only see the bundle. When the focused element
/// looks like a search field or address bar (`AXSearchField` role, or
/// `identifier` / `title` containing `search` / `address` / `url`), we
/// flip the session's category to `.search` regardless of bundle. See
/// `AppCategory` and `NoType/Context/CLAUDE.md`.
enum CategoryResolver {
    private static let log = Logger(subsystem: "app.notype", category: "category")

    /// Pure decision: returns `.search` when the focused element looks
    /// like a search / address-bar field, otherwise returns `stored`
    /// unchanged. Passing `nil` for `focused` (no focused element, AX
    /// not trusted, etc.) returns `stored`.
    static func resolve(stored: AppCategory, focused: FocusedFieldSnapshot?) -> AppCategory {
        guard let focused else { return stored }
        return isSearchField(focused) ? .search : stored
    }

    /// Convenience: read the system-wide focused element synchronously,
    /// build a `FocusedFieldSnapshot`, and delegate to `resolve(...)`.
    /// Safe to call from any actor (no AX state retained across awaits).
    /// Returns `stored` when AX is not trusted.
    static func resolveFromAX(stored: AppCategory) -> AppCategory {
        guard let focused = captureFocusedFieldSnapshot() else { return stored }
        let resolved = resolve(stored: stored, focused: focused)
        if resolved != stored {
            log.info("category override: \(stored.rawValue, privacy: .public) → search (role=\(focused.role ?? "?", privacy: .public) id=\(focused.identifier ?? "-", privacy: .public))")
        }
        return resolved
    }

    /// Live AX read. Mirrors `InsertionTarget.captureSync` for the
    /// system-wide focused element lookup — same guards (trust check,
    /// type-id verification, attribute fetch).
    static func captureFocusedFieldSnapshot() -> FocusedFieldSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()

        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &raw
        )
        guard err == .success,
              let focusedRaw = raw,
              CFGetTypeID(focusedRaw) == AXUIElementGetTypeID() else {
            return nil
        }
        // CFGetTypeID above is the real type check; `AnyObject → AXUIElement`
        // has no `as?`/`as` form, so guarded `unsafeDowncast` replaces the old
        // `as!` — no force-unwrap, no trap (R12).
        let element = unsafeDowncast(focusedRaw, to: AXUIElement.self)
        return FocusedFieldSnapshot(
            role:       AXAttr.string(element, kAXRoleAttribute as String),
            subrole:    AXAttr.string(element, kAXSubroleAttribute as String),
            identifier: AXAttr.string(element, kAXIdentifierAttribute as String),
            title:      AXAttr.string(element, kAXTitleAttribute as String)
        )
    }

    /// Search-field heuristic. Layered checks, most specific first:
    /// 1. AXSearchField role or subrole — set by NSSearchField, plus
    ///    several browsers' omnibox accessibility wrappers.
    /// 2. `identifier` substring match on `search` / `address` / `url`
    ///    (case-insensitive) — catches Safari / Chrome / Arc / Firefox
    ///    address bars and search inputs that don't bother with the
    ///    semantic role.
    /// 3. `title` substring match on `address` / `url` / `search` — last
    ///    resort, but kept because some apps put the field's purpose in
    ///    the accessibility title rather than the identifier.
    static func isSearchField(_ f: FocusedFieldSnapshot) -> Bool {
        if let role = f.role, role == "AXSearchField" { return true }
        if let subrole = f.subrole, subrole == "AXSearchField" { return true }

        if let id = f.identifier?.lowercased(), hasSearchHint(id) { return true }
        if let title = f.title?.lowercased(), hasSearchHint(title) { return true }
        return false
    }

    private static let searchNeedles = ["search", "address", "url"]

    private static func hasSearchHint(_ haystack: String) -> Bool {
        for needle in searchNeedles where haystack.contains(needle) {
            return true
        }
        return false
    }

}
