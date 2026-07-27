import AppKit
import SwiftUI

/// Window canvas dimensions. The same `NSSize` is consumed by three
/// load-bearing sites that must agree or the SwiftUI hint and the
/// AppKit lock fight each other silently:
///   1. `NoTypeApp.swift` — `.defaultSize(...)` on the `Window` scene.
///   2. `MainWindowView.body` — `.frame(min==max ...)`.
///   3. `MainWindowView.body` — `FixedSizeWindowConfigurator(size:)`.
enum MainWindowMetrics {
    static let canvasSize = NSSize(width: 1180, height: 820)
}

/// Tabs available in the main window's left navigation.
enum MainTab: String, CaseIterable, Identifiable {
    case home
    case instructions
    case dictionary
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home:         return "Home"
        case .instructions: return "Instructions"
        case .dictionary:   return "Dictionary"
        case .settings:     return "Settings"
        }
    }

    var icon: DSIconName {
        switch self {
        case .home:         return .home
        case .instructions: return .edit
        case .dictionary:   return .bookmark
        case .settings:     return .settings
        }
    }

    /// Cross-window `pendingTabSelection` consumer (popover gear →
    /// main window navigation). Delegates to the shared generic
    /// `consumeAndClearPendingSelection` helper — see its doc-comment
    /// for the clear-first-apply-second discipline. Kept as an
    /// enum-scoped static for backwards compatibility with
    /// `MainTabTests`.
    static func consumePendingSelection(
        pending: inout MainTab?,
        current: MainTab
    ) -> MainTab {
        consumeAndClearPendingSelection(pending: &pending, current: current)
    }
}

/// Shared generic consumer for cross-surface "pending selection"
/// flags (`pendingTabSelection`, `pendingSettingsCategory`). Reads +
/// clears `pending` atomically; returns `current` if nothing was
/// pending. Clear-first-apply-second is load-bearing per plan §270 —
/// guards against a stale flag (set hours ago) hijacking an unrelated
/// trigger (Sparkle banner click → tab/category switch, etc.). Even
/// when `pending` is non-nil here we still clear it; the caller
/// decides whether to apply the returned value.
///
/// Distinct name from the enum-scoped `consumePendingSelection`
/// statics to avoid unqualified-name lookup ambiguity from their
/// bodies. Extracted from byte-for-byte duplication between
/// `MainTab.consumePendingSelection` and
/// `SettingsCategory.consumePendingSelection`; both statics delegate
/// here so existing test surfaces stay unchanged.
func consumeAndClearPendingSelection<T>(
    pending: inout T?,
    current: T
) -> T {
    let captured = pending
    pending = nil
    return captured ?? current
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
    @Environment(\.scenePhase)              private var scenePhase

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
        // Both axes pinned (min == max). `.windowResizability(.contentSize)`
        // on the scene only locks the window when the content reports
        // identical min and max bounds — `.frame(width:height:)` alone is
        // treated as an "ideal" hint and lets AppKit make the window
        // resizable. See Apple Developer Forums thread 708177.
        .frame(
            minWidth:  MainWindowMetrics.canvasSize.width,
            maxWidth:  MainWindowMetrics.canvasSize.width,
            minHeight: MainWindowMetrics.canvasSize.height,
            maxHeight: MainWindowMetrics.canvasSize.height
        )
        .background(DS.Color.bgBase.ignoresSafeArea())
        .background(FixedSizeWindowConfigurator(size: MainWindowMetrics.canvasSize))
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
            AppIconBadge(size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("NoType")
                    .font(DS.Font.body(.semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                Text(Bundle.main.shortVersion)
                    .font(DS.Font.labelMono())
                    .foregroundStyle(DS.Color.textQuaternary)
            }
        }
        // Anchored to the sidebar's left edge, aligned with the nav-item
        // icons below (sidebarNav: s3 horizontal padding + each item's
        // s3 horizontal padding = 16 pt from the rail's leading edge).
        //
        // The earlier 56 pt leading inset was leftover stoplight
        // clearance from when the header content sat on the same row as
        // the OS stoplights. With the `top: 14 pt` inset the content is
        // already below the stoplight zone vertically, so no horizontal
        // clearance is needed — the stoplights live above this region
        // purely by virtue of being drawn higher in the window.
        .padding(.leading, DS.Space.s5)
        .padding(.trailing, DS.Space.s5)
        .padding(.top, DS.Space.s8)          // 32 pt — keep clear of stoplights vertically
        .padding(.bottom, DS.Space.s5 + 2)   // 18 pt
        .frame(maxWidth: .infinity, alignment: .leading)
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
            case .settings:
                SettingsTabView()
            }
        }
        // Consume cross-window tab navigation requests (popover gear → Settings).
        // Unconditional clear-then-apply per plan §270 — prevents a stale flag
        // (set hours ago) from hijacking an unrelated window-open trigger:
        //   1. snapshot pending
        //   2. clear it (atomic w/ read)
        //   3. apply if non-nil
        // Three triggers, belt-and-braces:
        //   - `.onAppear` — window first becomes visible (popover gear when
        //     main window was hidden).
        //   - `.onChange(of: scenePhase)` — window re-focused after popover
        //     blur (popover gear when main window was already visible but
        //     unfocused; macOS popovers normally blur the main window).
        //   - `.onChange(of: pendingTabSelection)` — direct watcher for the
        //     edge case where main window is already visible AND focused
        //     when `openSettings()` fires (no scenePhase transition, but
        //     the flag write itself is observable).
        .onAppear { consumePendingTabSelection() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { consumePendingTabSelection() }
        }
        .onChange(of: appState.pendingTabSelection) { _, new in
            if new != nil { consumePendingTabSelection() }
        }
    }

    private func consumePendingTabSelection() {
        selectedTab = MainTab.consumePendingSelection(
            pending: &appState.pendingTabSelection,
            current: selectedTab
        )
    }
}

// MARK: - Fixed-size window configurator
//
// `.windowResizability(.contentSize)` + `.frame(width:height:)` on the
// content is *meant* to lock the window, but in practice SwiftUI on
// macOS 15/26 still forwards a `.resizable` style mask to AppKit, so
// the user can drag the edges. We attach this helper as a background
// view, walk up to the hosting NSWindow on appear, drop the resizable
// bit, and pin `minSize == maxSize`. The window cannot grow or shrink
// after this — exactly what we want for a rarely-opened utility shell.
//
// **Why the lock lives in BOTH `viewDidMoveToWindow` and `updateNSView`
// (do not delete the latter as "redundant").** SwiftUI owns the NSWindow
// and re-applies its window configuration on certain system events
// (Mission Control / Space switch, display add-remove, screen
// sleep/wake, full-screen exit). Those re-configurations can transiently
// re-assert `.resizable` until the next SwiftUI body rebuild. The
// `viewDidMoveToWindow` hook only fires when AppKit (re-)attaches the
// view to a window; SwiftUI may update the body without a re-attach.
// `updateNSView` re-strips the bit on every body update so the lock
// recovers without an actual re-attach event.
//
// Both call sites stay. `lock(window:to:)` is guarded by
// `lockReason(for:target:)` so the steady-state repeats are cheap rather
// than absent — see that method's doc-comment for why the guard narrows
// exposure to a raise-prone mutation and does not remove it.

struct FixedSizeWindowConfigurator: NSViewRepresentable {
    let size: NSSize

    func makeNSView(context: Context) -> NSView {
        // `NSView.window` is nil at `makeNSView` time and stays nil
        // until AppKit attaches the view to a window — a deferred
        // `DispatchQueue.main.async` runs too early on the first beat
        // for newly-created windows. We override `viewDidMoveToWindow`
        // so the lock fires exactly when AppKit hands us a window.
        WindowAwareView(targetSize: size)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        Self.lock(window: window, to: size)
    }

    /// The four window facts `lock(window:to:)` would mutate, snapshotted
    /// so "does this window still need locking?" can be asked as a pure
    /// function with no `NSWindow` in the test.
    ///
    /// Same shape as `MicProbeFormatGate.Shape`: an explicit memberwise
    /// initializer for tests, plus a convenience initializer that reads the
    /// live object.
    struct WindowState: Equatable, Sendable {
        let isResizable: Bool
        let minSize: NSSize
        let maxSize: NSSize
        let frameSize: NSSize

        init(isResizable: Bool, minSize: NSSize, maxSize: NSSize, frameSize: NSSize) {
            self.isResizable = isResizable
            self.minSize = minSize
            self.maxSize = maxSize
            self.frameSize = frameSize
        }

        @MainActor
        init(_ window: NSWindow) {
            self.init(
                isResizable: window.styleMask.contains(.resizable),
                minSize: window.minSize,
                maxSize: window.maxSize,
                frameSize: window.frame.size
            )
        }
    }

    /// Why the window still needs the fixed-size lock applied.
    ///
    /// `CaseIterable` exists for the exhaustiveness test — it asserts every
    /// case is produced by at least one state, so adding a case without an
    /// input that reaches it goes red instead of shipping dead
    /// classification. Same discipline as `HUDPanelGeometry.Rejection`.
    ///
    /// Deliberately *not* `CustomStringConvertible`, which is where this
    /// diverges from `HUDPanelGeometry.Rejection` and
    /// `MicProbeFormatGate.Rejection`: both of those interpolate their
    /// rejection into a `Logger` line, so a `description` has a consumer.
    /// ``lock(window:to:)`` only tests the result against `nil` and logs
    /// nothing, so the conformance would be dead code. Add it back together
    /// with the logging caller, not ahead of it.
    enum LockReason: Hashable, Sendable, CaseIterable {
        /// SwiftUI is still forwarding a resizable style mask to AppKit —
        /// the fresh-window case, and the case every re-configuration
        /// (Mission Control, Space switch, display add/remove) restores.
        case resizable
        /// `minSize` is not pinned to the target.
        case minSizeMismatch
        /// `maxSize` is not pinned to the target.
        case maxSizeMismatch
        /// The window is not sitting at the target size.
        case frameSizeMismatch
    }

    /// Returns `nil` when `state` already matches `target` — nothing for
    /// ``lock(window:to:)`` to do — otherwise the first fact that differs.
    ///
    /// **This answers "is the mutation needed?", never "is the mutation
    /// safe?".** See ``lock(window:to:)`` for why those are different
    /// questions here and why only the first one is answerable.
    ///
    /// Limb order is fixed — resizable → minSize → maxSize → frame size — so
    /// which reason a multi-mismatch state reports is deterministic rather
    /// than whichever limb happened to be evaluated. Pinned by
    /// `FixedSizeWindowConfiguratorTests`.
    static func lockReason(for state: WindowState, target: NSSize) -> LockReason? {
        if state.isResizable { return .resizable }
        if state.minSize != target { return .minSizeMismatch }
        if state.maxSize != target { return .maxSizeMismatch }
        if state.frameSize != target { return .frameSizeMismatch }
        return nil
    }

    /// Apply the fixed-size lock, skipping the AppKit mutations entirely
    /// when the window already matches `size`.
    ///
    /// **The guard is containment. It narrows exposure to a raise-prone
    /// mutation; it does not remove the raise, and must not be counted as
    /// removing it.** Mutating `styleMask` on a window AppKit is still
    /// configuring can raise `NSInternalInconsistencyException`, and
    /// `setFrame(_:display: true)` right behind it forces a synchronous
    /// display pass. An Objective-C exception unwinding out of a main-actor
    /// Swift-concurrency job orphans the thread's `ExecutorTrackingInfo`,
    /// so the *next* "am I on the main executor?" check SIGSEGVs somewhere
    /// unrelated — see
    /// `docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`.
    ///
    /// `MicProbeFormatGate` and `HUDPanelGeometry` validate the argument
    /// that would make their call raise, so their raise never happens. This
    /// guard cannot do the equivalent, for three separate reasons — stated
    /// here so a later reader does not file this under "raise removed":
    ///
    /// 1. **The precondition is not checkable.** It is *"AppKit is not
    ///    currently reconfiguring this window"*, and no API answers that.
    ///    ``lockReason(for:target:)`` decides only whether the mutation is
    ///    *needed*.
    /// 2. **The predicate skips the safe calls and never the dangerous
    ///    one.** The first `lock` arrives from
    ///    `WindowAwareView.viewDidMoveToWindow` — while AppKit is attaching
    ///    the window, precisely the mid-configure moment a raise needs. At
    ///    that instant the style mask still carries `.resizable`, so the
    ///    predicate says "needed" and the mutation runs unchanged. The
    ///    genuine re-lock events (Mission Control, Space switch, display
    ///    add/remove) are re-configurations too and re-assert `.resizable`,
    ///    so they pass as well. What is skipped is the steady-state
    ///    `updateNSView` repeats — the calls least likely to raise.
    /// 3. **Neither caller is established as a Swift-concurrency job.**
    ///    `updateNSView` and `viewDidMoveToWindow` are synchronous
    ///    SwiftUI / AppKit callbacks. The mechanism above requires the raise
    ///    to unwind through `libswift_Concurrency`; if these are not reached
    ///    from inside a `Task { @MainActor }`, a raise here cannot orphan
    ///    the executor identity at all and this site is not in that family.
    ///    That has not been checked.
    ///
    /// So what this buys is narrower exposure plus a real latent-performance
    /// fix (no AppKit round-trip on every body update) — **conditional on the
    /// window actually settling at `size`.** `minSize` / `maxSize` / `frame`
    /// are frame-space, and AppKit's `constrainFrameRect(_:to:)` clamps the
    /// frame to the screen's visible area, so on a display too short for
    /// `size` the frame limb never matches, `lockReason` returns
    /// `.frameSizeMismatch` on every call, and nothing is ever skipped. That
    /// degrades to exactly the pre-guard behaviour — never worse — but it is
    /// why "the repeats are cheap" is not an unconditional claim. No test
    /// covers it: `MutationCountingWindow` overrides `constrainFrameRect` to
    /// the identity so the acceptance test stays machine-independent.
    ///
    /// If evidence ever names `NSInternalInconsistencyException` from this
    /// site, the fix is the containment escalation — bridging the mutation
    /// off the concurrency job so there is no `ExecutorTrackingInfo` node to
    /// unwind through — not a sharper predicate.
    static func lock(window: NSWindow, to size: NSSize) {
        guard lockReason(for: WindowState(window), target: size) != nil else { return }
        window.styleMask.remove(.resizable)
        window.minSize = size
        window.maxSize = size
        if window.frame.size != size {
            window.setFrame(adjustedFrame(for: window.frame, target: size), display: true)
        }
    }

    /// Shift `currentFrame` to `target` while preserving the visual top-left
    /// anchor. AppKit's coordinate system has the origin at the bottom-left,
    /// so a height change must be matched by an offset on `origin.y` —
    /// otherwise the window appears to jump vertically by the height delta.
    /// Exposed `internal static` for direct unit testing.
    static func adjustedFrame(for currentFrame: NSRect, target: NSSize) -> NSRect {
        var frame = currentFrame
        let dy = frame.size.height - target.height
        frame.size = target
        frame.origin.y += dy
        return frame
    }
}

private final class WindowAwareView: NSView {
    private let targetSize: NSSize

    init(targetSize: NSSize) {
        self.targetSize = targetSize
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("WindowAwareView is created in code only.")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        FixedSizeWindowConfigurator.lock(window: window, to: targetSize)
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
        .dsOnHover { isHovered = $0 }
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
