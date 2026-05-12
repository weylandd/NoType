import SwiftUI
import AppKit

// MARK: - Row

struct HistoryRowView: View {
    let entry: HistoryEntry
    var isNewest: Bool = false
    var onDelete: (() -> Void)? = nil

    @State private var isHovered  = false
    @State private var copied     = false
    @State private var isExpanded = false

    // Icon column width + gap + row h-padding = separator indent
    static let separatorLeading: CGFloat = 14 + 28 + 10

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s3 + 2) {  // 10 pt gap
            AppIconView(bundleID: entry.sourceBundleID, name: entry.sourceAppName)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: DS.Space.s2) {
                metaRow
                transcriptText
            }
        }
        .padding(.horizontal, DS.Space.s4 + 2)  // 14 pt
        .padding(.vertical,   DS.Space.s3 + 2)  // 10 pt
        // Newest-entry accent bar (2 px, inset 8 pt top/bottom)
        .overlay(alignment: .leading) {
            if isNewest {
                DS.Color.accent
                    .frame(width: 2)
                    .padding(.vertical, DS.Space.s3)
                    .clipShape(Capsule())
            }
        }
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { isExpanded.toggle() }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }

    // MARK: Sub-views

    private var metaRow: some View {
        HStack(spacing: DS.Space.s2 + 1) {  // 5 pt
            Text(entry.sourceAppName)
                .font(DS.Font.bodySM(.medium))
                .foregroundStyle(DS.Color.textPrimary)

            TimestampDisplay(date: entry.timestamp, useAccentBadge: isNewest)

            Spacer(minLength: 0)

            // Action buttons — always in layout so the row never shifts;
            // faded out unless the row is hovered.
            HStack(spacing: DS.Space.s2) {
                DSIconButton(icon: copied ? .check : .copy) {
                    copyToClipboard()
                }
                .accessibilityLabel(copied ? "Copied" : "Copy transcript")

                DSIconButton(icon: .trash, isDestructive: true) {
                    onDelete?()
                }
                .accessibilityLabel("Delete transcript")
            }
            .opacity(isHovered ? 1 : 0)
        }
    }

    private var transcriptText: some View {
        Text(entry.text)
            .font(.system(size: 12.5))
            .foregroundStyle(DS.Color.textSecondary)
            .lineLimit(isExpanded ? nil : 3)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isHovered {
            DS.Color.bgHover
        } else if isNewest {
            // Subtler tint than `accentSoft` — the row already has the
            // 2 pt accent capsule on its leading edge, so a strong fill
            // ends up double-billing the "newest" signal.
            DS.Color.accentSoftSubtle
        } else {
            Color.clear
        }
    }

    // MARK: Actions

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

// MARK: - Timestamp display
//
// Single time-driven view that handles BOTH the "just now" accent badge
// (for the newest row, while it's still fresh) AND the gray dot + relative
// time for everything else. Wrapping both branches in one `TimelineView`
// is what fixes the "just now stays forever" bug — the newest row used to
// render a static `DSBadge(text: "just now")` outside any time scheduler,
// so it never aged. Now the same view is re-evaluated every 15 s and
// flips to the dot + "Xm ago" form once the entry crosses the 60 s
// freshness boundary.

private struct TimestampDisplay: View {
    let date: Date
    /// When `true`, render the accent "just now" badge while the entry
    /// is fresh (< 60 s). After that the view degrades to the same gray
    /// dot + relative time text used by the rest of the list. Driven by
    /// the parent — only the newest row gets `true`.
    let useAccentBadge: Bool

    // The whole row is inlined into the TimelineView closure (no
    // `content(secs:)` / `string(secs:)` method hops, helpers are
    // `static`). Reason: on macOS 26 the per-tick re-entry into a
    // `@MainActor`-isolated View instance method from inside the
    // `TimelineView` content closure triggered a runtime executor
    // check (`swift_task_isCurrentExecutorWithFlagsImpl` →
    // `objc_opt_class`) that crashed on launch (incident
    // 4838DA5B-4636-4468-AC06-2E9A73CED3FB). Inlining + static helpers
    // removes the method-call boundary where the check is inserted.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let secs = max(0, Int(ctx.date.timeIntervalSince(date)))
            if useAccentBadge && secs < 60 {
                DSBadge(text: "just now", style: .accent)
            } else {
                HStack(spacing: DS.Space.s2 + 1) {
                    Circle()
                        .fill(DS.Color.textQuaternary)
                        .frame(width: 2, height: 2)
                    Text(Self.relativeString(secs: secs))
                        .font(DS.Font.labelMono())
                        .foregroundStyle(DS.Color.textTertiary)
                        .monospacedDigit()
                }
            }
        }
    }

    private static func relativeString(secs: Int) -> String {
        if secs <  60 { return "just now" }
        let mins = secs / 60
        if mins <  60 { return "\(mins)m ago" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
