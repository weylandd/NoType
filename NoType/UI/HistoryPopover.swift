import AppKit
import SwiftUI

private let popoverWidth:     CGFloat = 380
/// Min/max overall height (per the `.menu-popover` spec `max-height: 560`).
/// The popover grows with content between these bounds; the middle
/// section is greedy and the SwiftUI scroll view kicks in once content
/// exceeds the available room.
///
/// `minHeight` exists to prevent SwiftUI from collapsing the middle
/// section to 0 when its intrinsic content sizing chain is ambiguous —
/// a regression we hit before when the middle had only `maxHeight` set
/// and the list disappeared entirely. Keep this here.
private let popoverMinHeight: CGFloat = 280
private let popoverMaxHeight: CGFloat = 560

struct HistoryPopover: View {
    @Environment(AppState.self)             private var appState
    @Environment(PermissionsViewModel.self) private var permissions
    @Environment(\.openWindow)              private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            DSSeparator()

            Group {
                if appState.history.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    historyList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            DSSeparator()
            footer
        }
        .frame(width: popoverWidth)
        .frame(minHeight: popoverMinHeight, maxHeight: popoverMaxHeight)
        // Solid body fill via the `popoverSurface` token — pure white in
        // light theme, near-black in dark. Replaces the previous
        // `.ultraThinMaterial` background which picked up the user's
        // wallpaper through the menu bar and made both themes look
        // cloudy / washed out.
        .background(DS.Color.popoverSurface)
        .overlay(
            // `inset 0 1px 0 rgba(255,255,255,0.06)` from the spec —
            // a 1 pt-tall highlight along the top edge that gives the
            // glass a "raised" feel. Theme-aware: white-on-dark,
            // black-on-light.
            Rectangle()
                .fill(DS.Color.glassTopHighlight)
                .frame(height: 1),
            alignment: .top
        )
        .onAppear {
            permissions.refresh()
            appState.handleMenuBarOpened()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Space.s2 + 1) {
            Text("NoType")
                .font(DS.Font.body(.semibold))
                .foregroundStyle(DS.Color.textPrimary)

            if !appState.history.isEmpty {
                DS.Color.textQuaternary
                    .frame(width: 2, height: 2)
                    .clipShape(Circle())
                Text("Recent · \(appState.history.count)")
                    .font(DS.Font.labelMono())
                    .foregroundStyle(DS.Color.textTertiary)
                    .textCase(.uppercase)
            }

            Spacer()

            if case .recording(let startedAt) = appState.recordingState {
                recordingPill(startedAt: startedAt)
            } else if case .sending = appState.recordingState {
                sendingPill
            } else {
                // Two separate kbd chips per the design — visually
                // matches `<kbd>⌥</kbd> <kbd>Right Option</kbd>` so the
                // hint reads as two key signals, not one string. Dropped
                // the trailing "to dictate" because at 380 pt with the
                // "Recent · N" subtitle present, the full phrase
                // overflowed and wrapped to two lines.
                HStack(spacing: DS.Space.s2) {
                    Text("Hold")
                        .font(DS.Font.labelMono())
                        .foregroundStyle(DS.Color.textTertiary)
                    DSKbd("⌥")
                    DSKbd("Right Option")
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, DS.Space.s4 + 2)  // 14 pt
        .padding(.vertical,   DS.Space.s3 + 3)  // 11 pt
    }

    private func recordingPill(startedAt: Date) -> some View {
        DSStatusPill(tone: .danger) {
            HStack(spacing: DS.Space.s2) {
                Circle()
                    .fill(DS.Color.dangerBase)
                    .frame(width: 6, height: 6)
                // `Self.formatElapsed` (static, nonisolated) instead of
                // an instance method so SwiftUI's TimelineView doesn't
                // re-enter `@MainActor`-isolated dispatch on every tick.
                // See HistoryRowView.TimestampDisplay for the original
                // crash (incident 4838DA5B-…); same pattern.
                TimelineView(.periodic(from: startedAt, by: 1)) { ctx in
                    Text(Self.formatElapsed(from: startedAt, to: ctx.date))
                        .monospacedDigit()
                }
            }
        }
    }

    private static func formatElapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var sendingPill: some View {
        DSStatusPill(tone: .accent) {
            HStack(spacing: DS.Space.s2) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                Text("Transcribing…")
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: DS.Space.s3 + 2) {
            Image(systemName: "waveform")
                .font(.system(size: 28))
                .foregroundStyle(DS.Color.textQuaternary)
            VStack(spacing: DS.Space.s3) {
                Text("No recordings yet.")
                    .font(DS.Font.body(.medium))
                    .foregroundStyle(DS.Color.textSecondary)
                HStack(spacing: DS.Space.s2) {
                    Text("Hold")
                        .font(DS.Font.bodySM())
                        .foregroundStyle(DS.Color.textTertiary)
                    DSKbd("⌥")
                    DSKbd("Right Option")
                    Text("anywhere to start")
                        .font(DS.Font.bodySM())
                        .foregroundStyle(DS.Color.textTertiary)
                }
            }
        }
    }

    // MARK: - History list

    private var historyList: some View {
        let reversed = Array(appState.history.reversed())
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(reversed.enumerated()), id: \.element.id) { i, entry in
                    HistoryRowView(
                        entry: entry,
                        isNewest: i == 0,
                        onDelete: { appState.deleteHistoryEntry(id: entry.id) }
                    )
                    if i < reversed.count - 1 {
                        DSSeparator(leadingPadding: HistoryRowView.separatorLeading)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DS.Space.s2) {
            MicInputPicker()
            Spacer()
            OpenMainWindowButton {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            DSIconButton(icon: .x, isDestructive: true) {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.vertical,   DS.Space.s2 + 2)  // 6 pt
        // Solid `footerSurface` — visibly darker than `popoverSurface`
        // in both themes (off-white on light, slightly darker tint on
        // dark). The previous `bgBase.opacity(0.6)` layered over a
        // material gave no visible contrast in light theme.
        .background(DS.Color.footerSurface)
    }
}

/// Quiet text + arrow pill that opens the main NoType window. Sits in
/// the popover footer next to the mic picker.
private struct OpenMainWindowButton: View {
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s2) {
                Text("Open NoType")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hovered ? DS.Color.textPrimary : DS.Color.textSecondary)
                DSIcon(
                    name: .arrowUpRight,
                    size: 11,
                    color: hovered ? DS.Color.textPrimary : DS.Color.textTertiary
                )
            }
            .padding(.horizontal, DS.Space.s3)
            .frame(height: DS.Size.hSM - 2)   // 26 pt
            .background(hovered ? DS.Color.bgHover : .clear,
                        in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
        .help("Open NoType")
    }
}

// `MicInputSelector` was extracted into `NoType/UI/MicInputPicker.swift`
// — same component is now reused by the onboarding mic-check screen.
