import AppKit

/// Resolves and caches macOS application icons by bundle ID.
///
/// `NSWorkspace.icon(forFile:)` does disk I/O and decodes a multi-rep
/// `NSImage`; doing this on every history-row render flickers and burns
/// CPU. We memoize per `bundleID` for the app's lifetime — a "miss"
/// (uninstalled / sandboxed app we can't resolve) is also cached, so we
/// don't keep hitting `LaunchServices` looking for an app that isn't
/// there.
@MainActor
enum AppIconCache {
    /// `Optional<NSImage>?` is intentional:
    ///   - `nil` outer: never looked up.
    ///   - `.some(nil)`: looked up, app couldn't be located.
    ///   - `.some(image)`: resolved.
    private static var cache: [String: NSImage?] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        let resolved = resolve(bundleID: bundleID)
        cache[bundleID] = resolved
        return resolved
    }

    private static func resolve(bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
