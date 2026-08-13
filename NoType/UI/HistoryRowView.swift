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
    /// The user's *current* replacement pairs — `AppState.dictionaryReplacements`,
    /// the observable mirror, threaded down verbatim by both surfaces
    /// (R5). They are applied to the assembled row at render time rather
    /// than baked into what was stored, so editing or deleting a pair
    /// changes how rows already on disk read (AE7). Reading them from a
    /// store here instead would make the row impure and stop SwiftUI
    /// re-rendering on an edit; deriving them per surface is the drift
    /// `NoType/UI/CLAUDE.md`'s threading rule names.
    var replacements: [DictionaryReplacement] = []
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
        Self.actions(entry: entry, canRetry: canRetry, isRetrying: isRetrying)
    }

    /// The one string this row shows and copies (R4 → R5 → R6). Computed
    /// per render from the stored sequence and the *current* pairs — see
    /// `HistoryText.rendered`.
    private var shownText: String {
        HistoryText.rendered(entry, replacements: replacements)
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

            // Action buttons. Membership comes from the pure `actions`
            // table so a change to R10's truth table reaches the
            // rendering, not just the test; visibility is a separate
            // axis — faded out unless the row is hovered, broken, or
            // busy. Both live behind the trailing `Spacer`, so a state
            // change that adds or drops a button re-lays out only this
            // cluster and never moves the app name or timestamp.
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
        Text(shownText)
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
        // R6: the *same* property the transcript above renders, not a
        // second derivation that happens to agree. Display and copy are
        // one string by construction.
        NSPasteboard.general.setString(shownText, forType: .string)
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
    //
    // What the row *shows* is no longer one of them: it is
    // `HistoryText.rendered`, which lives beside `HistoryEntry` because
    // `StatsStore` needs the same string and cannot reach into the UI
    // module for it (R13).

    /// The three things a row can offer. Declaration order is render
    /// order, matching the design's markup (retry, copy, delete).
    enum RowAction: CaseIterable, Sendable {
        case retry, copy, delete
    }

    /// What a row offers, per R10 and R13.
    ///
    /// Takes the **entry**, not caller-derived flags. Two of the three
    /// actions turn on readings of the row's own stored sequence — "is
    /// any of it worth copying" and "is it broken" — and a boolean
    /// parameter puts those derivations in the caller, where no test
    /// reaches them and the two surfaces can drift. `canRetry` and
    /// `isRetrying` stay parameters because they are facts only
    /// `AppState` can give: that is the line `NoType/UI/CLAUDE.md`'s
    /// threading rule draws.
    ///
    /// - `isRetrying` wins outright: a run in flight offers no retry (one
    ///   run at a time) and deliberately no cancel (KTD7); delete is the
    ///   only exit. Copy survives **only when the row is showing text
    ///   worth copying** — the drawn retrying row carries a lone trash
    ///   button, but that row has no transcript at all, and since R9's
    ///   supersession a busy row does render whatever it recovered.
    ///   Withholding copy from visible text for an uncancellable run
    ///   would be a worse trade than diverging from a mock that never
    ///   depicted this state.
    /// - `retry` needs a gap and the audio behind it, and **that is now
    ///   the whole test** (R8). It used to carry a third term —
    ///   `RetryMerge.canAcceptRecovery`, "is there still a marker in the
    ///   text for a recovery to land in" — because a replacement pair on
    ///   the ellipsis could erase every `[…]` from the stored string and
    ///   leave a broken row no retry could write into. That was a
    ///   mitigation for the storage defect, not a rule: it hid the
    ///   user's recovery instead of fixing the model. A gap is a position
    ///   in `segments` now, and a pair applied at render time cannot
    ///   reach it, so the term has nothing left to protect against and is
    ///   gone (AE1).
    ///
    ///   **The merge has since caught up with the button.** For one unit
    ///   it did not: `AppState.settleRetry` still merged by scanning
    ///   `HistoryEntry.text` for the marker, so on the ellipsis-pair row
    ///   this term used to hide, the retry was offered, billed, and settled
    ///   onto the nothing-recovered exit every time. `RetryMerge` writes
    ///   into the gap at the chunk's own index now (R7), so "offered" and
    ///   "lands" are one fact again. Should they ever diverge, the fix is
    ///   never a text-shaped gate here — that re-hides the user's
    ///   recovery, which is what AE1 rejects.
    /// - `copy` asks whether anything but gaps survived, via
    ///   `hasCopyableText` below — hoisted out of this body because the
    ///   withheld-paste notice asks the same question about the same row
    ///   and must not spell it a second time. So a row whose every
    ///   segment is a gap reads the same as one that recovered nothing:
    ///   both render markers, and neither is worth putting on the
    ///   clipboard (AE4).
    nonisolated static func actions(
        entry: HistoryEntry,
        canRetry: Bool,
        isRetrying: Bool
    ) -> [RowAction] {
        let copyable = hasCopyableText(entry)
        if isRetrying { return copyable ? [.copy, .delete] : [.delete] }
        var out: [RowAction] = []
        if entry.isBroken && canRetry { out.append(.retry) }
        if copyable { out.append(.copy) }
        out.append(.delete)
        return out
    }

    /// Whether this row has anything worth putting on the clipboard — the
    /// `.copy` term of `actions(...)` above, and the whole of it.
    ///
    /// **Derived from the sequence, not from splitting the rendered string
    /// on the marker.** That is the same inversion R8 makes above: a
    /// replacement pair rewrites how a gap *looks*, so any predicate that
    /// finds gaps by looking for `[…]` in text answers differently once
    /// the user adds a pair on the ellipsis. Asking the segments instead
    /// makes the answer independent of the pair list — which is also why
    /// this takes no `replacements` argument, and why the notice and the
    /// row cannot disagree about it even if they render with different
    /// lists.
    ///
    /// A segment holding whitespace-only text counts as nothing, for the
    /// same reason `RetryMerge.isEmptyText` trims: a row rendering a lone
    /// space is empty to the user in every sense that matters.
    ///
    /// Named and hoisted out of `actions`' body because it has a **second
    /// caller outside this view**: `NoTypeErrorKind.pasteWithheld`'s
    /// notice offers Copy iff the row it points at does (the 2026-08-11
    /// ruling — the notice and the row must not disagree about the same
    /// entry, which is the same reason R30 routes the copied string
    /// through `HistoryText.rendered`). That caller must not re-spell this
    /// test; `NoType/UI/CLAUDE.md`'s threading rule puts predicates over
    /// the row's own fields *here*, where one edit reaches every surface
    /// and a test reaches the predicate.
    nonisolated static func hasCopyableText(_ entry: HistoryEntry) -> Bool {
        entry.segments.contains { segment in
            guard let text = segment.text else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
