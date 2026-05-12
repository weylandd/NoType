import AppKit
import SwiftUI

/// Renders a source app's macOS icon (resolved via `AppIconCache`) as a
/// rounded tile with a hairline border. Falls back to a violet
/// letter-tile when the bundle can't be located — typically: the app
/// was uninstalled since the entry was recorded, or no bundle id is
/// available.
///
/// Used by `HistoryRowView` (28 pt, in popover and main window) and
/// `HomeAppsPanel` (22 pt, in the top-apps breakdown). The size is
/// caller-driven via the surrounding `.frame(...)`.
struct AppIconView: View {
    let bundleID: String
    let name: String

    /// Corner radius for the tile. Defaults to a 7 pt radius that pairs
    /// with the design system's 28 pt icon size; adjust on the call
    /// site for smaller tiles.
    var cornerRadius: CGFloat = DS.Radius.sm + 1

    var body: some View {
        iconContent
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(DS.Color.borderDefault, lineWidth: DS.Border.hairline)
            )
    }

    @ViewBuilder
    private var iconContent: some View {
        if let nsIcon = AppIconCache.icon(for: bundleID) {
            Image(nsImage: nsIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                DS.Color.accentSoft
                Text(String(name.prefix(1)).uppercased())
                    .font(DS.Font.body(.semibold))
                    .foregroundStyle(DS.Color.accentFg)
            }
        }
    }
}
