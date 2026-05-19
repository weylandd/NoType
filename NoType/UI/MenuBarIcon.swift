import SwiftUI

/// Menu-bar tray label.
///
/// Three resting states (idle / sending / error) render as a static SF
/// Symbol — cheap, hit-testable, no re-rendering. The active "recording"
/// state morphs into the design's `tray-aura` pill: filled mic glyph in
/// accent + a live mm:ss timer + a pulsing red dot.
///
/// **About the timer.** A previous iteration shipped without any timer
/// here — `TimelineView` repaint storms broke `MenuBarExtra` hit-testing
/// (the popover would silently stop opening). The fix is to drive the
/// label's seconds counter from `Timer.publish` (1 Hz), only re-rendering
/// when the displayed `mm:ss` actually changes. That's exactly one
/// SwiftUI invalidation per second, which `MenuBarExtra` handles fine.
///
/// **About icon sizing.** The `menu_icon` / `menu_icon_fill` SVG assets
/// declare `width="18" height="18"` with `viewBox="0 0 418 418"` — that
/// makes NSImage report intrinsic size 18×18 (the viewBox is preserved
/// for scaling). MenuBarExtra picks up that intrinsic size and renders
/// at the right scale without any further sizing dance.
struct MenuBarIcon: View {
    @Environment(AppState.self)             var appState
    @Environment(PermissionsViewModel.self) var permissions
    @Environment(OnboardingState.self)      var onboarding
    @Environment(\.openWindow)              private var openWindow

    var body: some View {
        Group {
            switch appState.recordingState {
            case .idle:
                Image("menu_icon_fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)

            case .recording(let startedAt):
                RecordingTrayPill(startedAt: startedAt)

            case .sending:
                Image("menu_icon_fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)

            case .error:
                Image(systemName: "mic.slash")
                    .foregroundStyle(DS.Color.dangerBase)
            }
        }
        // Bridge SwiftUI's `openWindow` into AppState. The menu-bar icon
        // is always alive once onboarding completes (NoTypeApp suppresses
        // the entire MenuBarExtra during onboarding), so this is the most
        // reliable always-on hook. `.task` fires once on first appearance
        // and does NOT cause repaints — distinct from the TimelineView
        // repaint-storm hazard called out at the top of this file.
        // Idempotent re-binding is harmless; the closure is `nonisolated`-
        // safe because openWindow is itself `@MainActor`-bound and we're
        // already on MainActor here.
        .task {
            appState.openMainWindowRequest = { openWindow(id: "main") }
        }
    }
}

// MARK: - Recording pill

/// Tray pill shown while the hotkey is held: filled mic + mm:ss timer
/// in an accent capsule. Mirrors the design's `.tray-aura` block.
///
/// **Sizing strategy.** Earlier attempts used `.frame(width:)` *after*
/// the inner content, but `MenuBarExtra` was still picking up the inner
/// view's intrinsic size and reshuffling the whole tray on each digit
/// transition. The fix: lay everything out inside a `ZStack` whose
/// outer frame is the source of truth (`pillWidth × pillHeight`),
/// followed by `.fixedSize()` to commit that size all the way up to the
/// menu-bar host. The Capsule background fills the same frame, the
/// `Text` lives in its own fixed-width slot, and digit changes never
/// touch the outer geometry.
private struct RecordingTrayPill: View {
    let startedAt: Date

    private let pillWidth:  CGFloat = 78
    private let pillHeight: CGFloat = 18
    private let timerSlot:  CGFloat = 30

    /// 1-Hz tick. Drives only the *Text* re-render — the rest of the
    /// pill is static SwiftUI. We deliberately do *not* use TimelineView
    /// here, see the doc-comment on `MenuBarIcon`.
    @State private var elapsedText: String = "0:00"
    private let secondsTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Capsule().fill(DS.Color.accent.opacity(0.22))

            HStack(spacing: 5) {
                Image("menu_icon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(DS.Color.accentFg)

                Text(elapsedText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .frame(width: timerSlot, alignment: .leading)
            }
            .padding(.horizontal, 6)
        }
        .frame(width: pillWidth, height: pillHeight)
        .fixedSize()
        .onAppear {
            elapsedText = Self.format(elapsedFrom: startedAt, to: Date())
        }
        .onReceive(secondsTick) { now in
            let next = Self.format(elapsedFrom: startedAt, to: now)
            // Guard against churn — only re-render when the second flips.
            if next != elapsedText { elapsedText = next }
        }
    }

    private static func format(elapsedFrom start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
