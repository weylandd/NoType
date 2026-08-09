import SwiftUI
import AppKit

// MARK: - Row

struct HistoryRowView: View {
    let entry: HistoryEntry
    var isNewest: Bool = false
    /// The one shared retry slot — `AppState.retryingEntryID` — passed
    /// through verbatim by both surfaces rather than reduced to a
    /// per-surface `Bool` (R18 / KTD9). Which row is busy is derived
    /// *here*, from that single value, so the popover and the Home tab
    /// cannot disagree about it.
    var retryingEntryID: UUID? = nil
    /// `AppState.canRetry(entryID:)` for this row. Deliberately not
    /// re-derived: it folds payload presence (a *dead* row has none),
    /// R14's recording exclusion and R13's one-run-at-a-time gate into a
    /// single answer only `AppState` can give.
    var canRetry: Bool = false
    var onRetry: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isHovered  = false
    @State private var copied     = false
    @State private var isExpanded = false

    /// The leading slot's edge. App icon, error slot and spinner all
    /// occupy the same box so the row never reflows between states.
    static let iconSlotSize: CGFloat = 28

    // Icon column width + gap + row h-padding = separator indent
    static let separatorLeading: CGFloat = 14 + iconSlotSize + 10

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s3 + 2) {  // 10 pt gap
            leadingSlot

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
        .dsOnHover { isHovered = $0 }
        .onTapGesture { isExpanded.toggle() }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }

    // MARK: Derived state

    /// Whether *this* row is the one whose retry is in flight. The state
    /// is a single slot on `AppState`, so at most one row is ever busy.
    private var isRetrying: Bool { retryingEntryID == entry.id }

    /// A broken row and a busy row are dimmed the way the design dims
    /// them (`.transcript.failed .t-text` / `.retrying .t-text`).
    private var isDimmed: Bool { entry.isBroken || isRetrying }

    /// R7 / R13. A broken row's actions are visible without hovering —
    /// the retry it offers has to be discoverable without the user first
    /// learning that rows are hoverable — and a busy row keeps its
    /// delete visible so the only escape from an uncancellable run
    /// (KTD7) is never hidden.
    private var actionsVisible: Bool { entry.isBroken || isRetrying || isHovered }

    private var actions: [RowAction] {
        Self.actions(
            isBroken: entry.isBroken,
            canRetry: canRetry,
            hasText: !entry.text.isEmpty,
            isRetrying: isRetrying
        )
    }

    // MARK: Sub-views

    /// App icon, error slot, or spinner — the design swaps the tile
    /// rather than decorating it (`app/menu-bar.html`, `.t-err-slot`).
    @ViewBuilder
    private var leadingSlot: some View {
        if isRetrying {
            RetryingSlot()
        } else if entry.isBroken {
            BrokenSlot()
        } else {
            AppIconView(bundleID: entry.sourceBundleID, name: entry.sourceAppName)
                .frame(width: Self.iconSlotSize, height: Self.iconSlotSize)
        }
    }

    private var metaRow: some View {
        HStack(spacing: DS.Space.s2 + 1) {  // 5 pt
            Text(entry.sourceAppName)
                .font(DS.Font.bodySM(.medium))
                .foregroundStyle(DS.Color.textPrimary)

            TimestampDisplay(date: entry.timestamp, useAccentBadge: isNewest)

            Spacer(minLength: 0)

            // Action buttons — always in layout so the row never shifts;
            // faded out unless the row is hovered, broken, or busy.
            // Membership comes from the pure `actions` table so a change
            // to R10's truth table reaches the rendering, not just the
            // test.
            HStack(spacing: DS.Space.s2) {
                if actions.contains(.retry) {
                    DSIconButton(icon: .refresh) {
                        onRetry?()
                    }
                    .accessibilityLabel("Retry transcription")
                }

                if actions.contains(.copy) {
                    DSIconButton(icon: copied ? .check : .copy) {
                        copyToClipboard()
                    }
                    .accessibilityLabel(copied ? "Copied" : "Copy transcript")
                }

                if actions.contains(.delete) {
                    DSIconButton(icon: .trash, isDestructive: true) {
                        onDelete?()
                    }
                    .accessibilityLabel("Delete transcript")
                }
            }
            .opacity(actionsVisible ? 1 : 0)
        }
    }

    private var transcriptText: some View {
        Text(Self.displayText(for: entry))
            .font(.system(size: 12.5))
            .foregroundStyle(isDimmed ? DS.Color.textQuaternary : DS.Color.textSecondary)
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
        // What the user sees is what they get. Identical to `entry.text`
        // wherever copy is actually offered — the action set gates copy on
        // the *stored* text being non-empty, and `displayText` only
        // synthesises anything when that text is empty — but going through
        // the same accessor keeps the two from drifting.
        NSPasteboard.general.setString(Self.displayText(for: entry), forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    // MARK: - Pure row logic
    //
    // Both of these are `nonisolated static` so `HistoryRowActionsTests`
    // can pin them without a running view — this project ships no UI
    // tests, so a pure seam is the only way these get proved at all.

    /// The three things a row can offer. Declaration order is render
    /// order, matching the design's markup (retry, copy, delete).
    enum RowAction: String, CaseIterable, Sendable {
        case retry, copy, delete
    }

    /// What a row offers, per R10 and R13.
    ///
    /// - `isRetrying` wins outright: a run in flight offers delete and
    ///   nothing else — no retry (one run at a time) and deliberately no
    ///   cancel (KTD7). Copy goes too, matching the drawn design, whose
    ///   retrying row carries a single trash button.
    /// - `retry` requires `isBroken` on top of `canRetry`. In production
    ///   only a broken row is ever given a payload, so the extra term
    ///   should be unreachable — but a row with no marker left in its
    ///   text has nowhere for a recovery to land (`RetryMerge` would
    ///   place nothing and the run would settle straight onto R19's
    ///   nothing-recovered exit), so offering the action there would
    ///   spend the user's Gemini budget on a request that cannot land.
    /// - `copy` reads the **stored** text, not the rendered one. A
    ///   session that recovered nothing renders as bare `[…]` markers
    ///   (see `displayText(for:)`), and markers are not worth putting on
    ///   the clipboard — AE4 says such a row offers delete only.
    nonisolated static func actions(
        isBroken: Bool,
        canRetry: Bool,
        hasText: Bool,
        isRetrying: Bool
    ) -> [RowAction] {
        if isRetrying { return [.delete] }
        var out: [RowAction] = []
        if isBroken && canRetry { out.append(.retry) }
        if hasText              { out.append(.copy) }
        out.append(.delete)
        return out
    }

    /// What the row shows for its transcript.
    ///
    /// A broken row renders exactly what the user was handed at paste
    /// time: the transcript with `RecordingSession.failureMarker`
    /// (`[…]`) sitting where each failed chunk's text should have been.
    /// A session that recovered *nothing* was never pasted and stores an
    /// empty string, so its markers are synthesised here rather than
    /// stored.
    ///
    /// **Why synthesise instead of storing them.** That empty string is
    /// load-bearing storage, not an oversight: `isBroken && text.isEmpty`
    /// is how "lifetime stats never counted this session" is represented
    /// (R15 / KTD7 — see `RecordingSession.brokenHistoryEntry()`, whose
    /// doc-comment warns in as many words that seeding the row with
    /// markers would make every recovered session double-count). Storing
    /// them would also make `text` non-empty, which is the very predicate
    /// the action set uses to decide whether copy is worth offering.
    ///
    /// **Why it does not drift from the retry path.** The synthesis is
    /// `TextInjector.stitchChunks` over N markers — the same call
    /// `RetryMerge`'s empty-text branch makes — so substituting a
    /// recovery into what the user saw and merging it into the stored
    /// empty string produce the same string, and the row does not reflow
    /// the moment a retry lands its first chunk. Pinned by
    /// `HistoryRowActionsTests`.
    nonisolated static func displayText(for entry: HistoryEntry) -> String {
        guard entry.isBroken, entry.text.isEmpty else { return entry.text }
        return TextInjector.stitchChunks(
            Array(repeating: RecordingSession.failureMarker, count: entry.failedChunkCount)
        )
    }
}

// MARK: - Broken / retrying leading slots
//
// The design replaces the row's app-icon tile with a bordered slot of
// the same size when a session failed (`app/menu-bar.html`,
// `.t-err-slot`): a dashed danger rim with a warning glyph while the
// row is merely broken, a solid accent rim with a spinning loader
// while a retry is in flight.

private struct BrokenSlot: View {
    var body: some View {
        DSIcon(name: .warning, size: 13, color: DS.Color.dangerFg)
            .frame(width: HistoryRowView.iconSlotSize, height: HistoryRowView.iconSlotSize)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm + 1)
                    .strokeBorder(
                        DS.Color.errorSlotBorder,
                        style: StrokeStyle(lineWidth: DS.Border.medium, dash: Self.dash)
                    )
            )
            .accessibilityLabel("Transcription failed")
    }

    /// Dash / gap lengths for the rim. CSS `dashed` is
    /// implementation-defined, so these are chosen to read closest to
    /// the design's 1.5 px dashed border at this tile size.
    private static let dash: [CGFloat] = [3, 2.5]
}

private struct RetryingSlot: View {
    @State private var spinning = false

    var body: some View {
        DSIcon(name: .loader, size: 13, color: DS.Color.accentFg)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(
                .linear(duration: Self.spinDuration).repeatForever(autoreverses: false),
                value: spinning
            )
            .frame(width: HistoryRowView.iconSlotSize, height: HistoryRowView.iconSlotSize)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm + 1)
                    .strokeBorder(DS.Color.retrySlotBorder, lineWidth: DS.Border.medium)
            )
            .onAppear { spinning = true }
            .accessibilityLabel("Retrying transcription")
    }

    /// 900 ms per turn, matching the design's `@keyframes spin` loop.
    ///
    /// Deliberately a repeating `.rotationEffect` and **not** a second
    /// `TimelineView`: this file already hosts one (the relative
    /// timestamp below) and the project's macOS 26 executor-identity
    /// crash family sits in exactly that neighbourhood. See the hard
    /// rules in `NoType/UI/CLAUDE.md`.
    private static let spinDuration: Double = 0.9
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
