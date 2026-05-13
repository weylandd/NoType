import AppKit
import SwiftUI

/// Tabs available in the main window's left navigation. Only `home`
/// exists today; the enum is structured so future tabs (settings,
/// activity, etc.) can be added without touching the layout code.
enum MainTab: String, CaseIterable, Identifiable {
    case home
    case instructions
    case dictionary

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home:         return "Home"
        case .instructions: return "Instructions"
        case .dictionary:   return "Dictionary"
        }
    }

    var icon: DSIconName {
        switch self {
        case .home:         return .home
        case .instructions: return .edit
        case .dictionary:   return .bookmark
        }
    }
}

/// Root view of the main app window. A 220 pt sidebar (brand + nav)
/// alongside a flexible main pane that swaps in the selected tab's
/// content. Keeps `LSUIElement = true` accommodation in mind: when this
/// view appears, we promote the activation policy to `.regular` so the
/// Dock and ⌘-tab show NoType while the window is open, and revert to
/// `.accessory` on disappear.
struct MainWindowView: View {
    @Environment(AppState.self)             private var appState
    @Environment(PermissionsViewModel.self) private var permissions
    @Environment(AppearanceController.self) private var appearance
    @Environment(OnboardingState.self)      private var onboarding

    @State private var selectedTab: MainTab = .home

    var body: some View {
        Group {
            if onboarding.isOnboarding {
                // Wizard takes the whole window — no sidebar, no tabs.
                OnboardingFlow()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    sidebar
                    mainPane
                }
            }
        }
        .frame(minWidth: 880, minHeight: 600)
        .background(DS.Color.bgBase.ignoresSafeArea())
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            // No other window types exist yet; if we add Settings as a
            // separate window later, gate this on "no app windows
            // remaining".
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            sidebarNav
            Spacer(minLength: 0)
            // Pending Sparkle update — visible only when
            // UpdateController.phase ≠ idle. Pinned to the bottom of
            // the sidebar so it reads like a system tray.
            UpdateBanner()
        }
        .frame(width: 220)
        // Slightly darker than `bgBase` per the design's
        // `color-mix(canvas 60%, base)` recipe — the sidebar reads as a
        // recessed rail next to the main pane.
        .background(DS.Color.bgCanvas)
        .overlay(
            DS.Color.borderSubtle
                .frame(width: 1),
            alignment: .trailing
        )
    }

    /// Real app icon + name above version. Top padding clears the OS
    /// stoplights that sit over this region thanks to
    /// `.windowStyle(.hiddenTitleBar)`. The icon is read from
    /// `NSApp.applicationIconImage` so it always tracks the bundle's
    /// current icon set (Sparkle replaces the bundle on update, the
    /// system updates the cached icon, and this view picks it up on
    /// next launch). Falls back to the synthetic `BrandMark` if the
    /// system hasn't given us a usable icon yet (very early launch).
    private var sidebarHeader: some View {
        HStack(spacing: DS.Space.s3) {
            Spacer().frame(width: 56)  // clear macOS stoplights
            AppIconBadge(size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("NoType")
                    .font(DS.Font.body(.semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                Text(Bundle.main.shortVersion)
                    .font(DS.Font.labelMono())
                    .foregroundStyle(DS.Color.textQuaternary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s5)
        .padding(.top, DS.Space.s4 + 2)      // 14 pt
        .padding(.bottom, DS.Space.s5 + 2)   // 18 pt
    }

    private var sidebarNav: some View {
        VStack(spacing: 1) {
            ForEach(MainTab.allCases) { tab in
                SidebarNavItem(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    onSelect: { selectedTab = tab }
                )
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.top, DS.Space.s2)
    }

    // MARK: - Main pane

    private var mainPane: some View {
        ZStack(alignment: .top) {
            DS.Color.bgBase.ignoresSafeArea()

            switch selectedTab {
            case .home:
                HomeView()
            case .instructions:
                InstructionsView()
            case .dictionary:
                DictionaryView()
            }
        }
    }
}

// MARK: - Sidebar nav item

private struct SidebarNavItem: View {
    let tab: MainTab
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DS.Space.s3 + 2) {  // 10 pt
                DSIcon(name: tab.icon, size: 14, color: iconColor)
                Text(tab.label)
                    .font(DS.Font.body())
                    .foregroundStyle(textColor)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(height: 30)
            .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DS.Motion.fast, value: isHovered)
    }

    private var iconColor: Color {
        if isSelected { return DS.Color.accentFg }
        return isHovered ? DS.Color.textSecondary : DS.Color.textTertiary
    }

    private var textColor: Color {
        if isSelected || isHovered { return DS.Color.textPrimary }
        return DS.Color.textSecondary
    }

    private var background: Color {
        if isSelected { return DS.Color.bgActive }
        if isHovered  { return DS.Color.bgHover  }
        return .clear
    }
}

// MARK: - Brand mark
//
// 18 pt rounded-square with a violet radial gradient + soft inner dot,
// matching the design's `.side-brand-mark`. Serves as the app's logo
// in the sidebar header.

struct BrandMark: View {
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(
                RadialGradient(
                    colors: [DS.Color.accent, DS.Color.accentPress],
                    center: UnitPoint(x: 0.2, y: 0.2),
                    startRadius: 0,
                    endRadius: size * 1.2
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .overlay(
                Circle()
                    .fill(.white.opacity(0.92))
                    .frame(width: size / 3, height: size / 3)
                    .shadow(color: .white.opacity(0.5), radius: 4)
            )
            .frame(width: size, height: size)
    }
}

// MARK: - App icon badge
//
// Renders the bundle's actual application icon as a rounded tile in the
// sidebar header. Pulls from `NSApp.applicationIconImage` so the image
// stays in sync with whatever is currently bundled at
// `Contents/Resources/AppIcon.icns` — including after a Sparkle in-place
// replacement. Falls back to the synthetic `BrandMark` for the brief
// window after `applicationDidFinishLaunching` where AppKit hasn't
// resolved the icon image yet.

struct AppIconBadge: View {
    var size: CGFloat = 32

    var body: some View {
        if let icon = Self.appIcon() {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            BrandMark(size: size)
        }
    }

    private static func appIcon() -> NSImage? {
        let img = NSApp?.applicationIconImage
        // A blank / 32×32 generic placeholder counts as "not ready" for
        // our purposes — fall through to the synthetic mark instead.
        guard let img, img.isValid, img.size.width > 0 else { return nil }
        return img
    }
}

// MARK: - Bundle helper

private extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
}
