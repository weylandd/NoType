import SwiftUI

/// Names of every DS line-icon shipped in `Assets.xcassets`. The set
/// mirrors `aura/project/shared/icons.js` from the design handoff
/// 1-to-1, plus `mic` (a NoType-specific extension — the design system
/// doesn't define a microphone glyph, but the app needs one).
///
/// All glyphs are 16×16 vector SVG with `stroke="currentColor"` and a
/// 1.5 stroke weight, so `DSIcon` can tint them via `foregroundStyle`.
/// SF Symbols stay only for system-only concepts that have no DS
/// counterpart (e.g. `mic.fill` for the active recording state, or
/// `figure.stand` for the accessibility permission glyph).
enum DSIconName: String, CaseIterable {
    case sun           = "icon-sun"
    case moon          = "icon-moon"
    case search        = "icon-search"
    case plus          = "icon-plus"
    case chevronDown   = "icon-chevronDown"
    case chevronRight  = "icon-chevronRight"
    case chevronLeft   = "icon-chevronLeft"
    case arrowRight    = "icon-arrowRight"
    case arrowUpRight  = "icon-arrowUpRight"
    case check         = "icon-check"
    case x             = "icon-x"
    case dot           = "icon-dot"
    case info          = "icon-info"
    case warning       = "icon-warning"
    case success       = "icon-success"
    case danger        = "icon-danger"
    case sparkle       = "icon-sparkle"
    case user          = "icon-user"
    case settings      = "icon-settings"
    case cog           = "icon-cog"
    case calendar      = "icon-calendar"
    case inbox         = "icon-inbox"
    case folder        = "icon-folder"
    case file          = "icon-file"
    case filter        = "icon-filter"
    case sort          = "icon-sort"
    case more          = "icon-more"
    case bell          = "icon-bell"
    case home          = "icon-home"
    case project       = "icon-project"
    case issue         = "icon-issue"
    case git           = "icon-git"
    case flag          = "icon-flag"
    case tag           = "icon-tag"
    case link          = "icon-link"
    case paperclip     = "icon-paperclip"
    case bolt          = "icon-bolt"
    case play          = "icon-play"
    case pause         = "icon-pause"
    case loader        = "icon-loader"
    case code          = "icon-code"
    case eye           = "icon-eye"
    case lock          = "icon-lock"
    case bookmark      = "icon-bookmark"
    case grid          = "icon-grid"
    case list          = "icon-list"
    case board         = "icon-board"
    case timeline      = "icon-timeline"
    case star          = "icon-star"
    case heart         = "icon-heart"
    case chat          = "icon-chat"
    case send          = "icon-send"
    case download      = "icon-download"
    case upload        = "icon-upload"
    case refresh       = "icon-refresh"
    case trash         = "icon-trash"
    case edit          = "icon-edit"
    case copy          = "icon-copy"
    case external      = "icon-external"
    case triangle      = "icon-triangle"
    case mic           = "icon-mic"
}

struct DSIcon: View {
    let name: DSIconName
    var size: CGFloat = 16
    var color: Color = DS.Color.textSecondary

    var body: some View {
        Image(name.rawValue)
            .renderingMode(.template)
            .resizable()
            .frame(width: size, height: size)
            .foregroundStyle(color)
    }
}
