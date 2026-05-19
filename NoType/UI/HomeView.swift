import AppKit
import SwiftUI

/// Home tab content: stats summary, top-apps breakdown, monthly
/// activity heatmap, and the recent transcripts list. The first three
/// read from `AppState.statsSummary` (lifetime aggregate via
/// `StatsStore`) windowed by `range`; only the bottom "Recent
/// transcripts" list pulls from the rolling 10-entry `AppState.history`.
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var range: HomeRange = .d30

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s7) {
                    HomeStatsRow(stats: HomeStats(
                        summary: appState.statsSummary,
                        range: range
                    ))

                    HStack(alignment: .top, spacing: DS.Space.s4) {
                        HomeAppsPanel(summary: appState.statsSummary, range: range)
                            .frame(maxWidth: .infinity)
                        HomeActivityCalendar(summary: appState.statsSummary)
                            // Container hugs the 7-cell grid + panel
                            // padding instead of stretching with the
                            // ProportionalRow. Width is derived from
                            // `CalendarGridLayout.maxCellSize` so a
                            // future cell-size change auto-updates.
                            .frame(width: HomeActivityCalendar.naturalWidth)
                    }

                    HomeRecentList(
                        entries: appState.history,
                        onDelete: { id in appState.deleteHistoryEntry(id: id) }
                    )
                }
                .padding(.horizontal, DS.Space.s7)
                .padding(.top, DS.Space.s7)
                .padding(.bottom, DS.Space.s7)
            }
        }
    }

    // MARK: - Header
    //
    // Sticks at the top of the main pane. The first row is rendered
    // *underneath* the OS title bar (we use `.hiddenTitleBar`), so the
    // top padding here clears it visually as well as keeping the area
    // draggable.

    private var header: some View {
        HStack(spacing: DS.Space.s4) {
            Text("Home")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary)

            Text(range.scopeLabel.uppercased())
                .font(DS.Font.labelMono())
                .foregroundStyle(DS.Color.textTertiary)
                .padding(.horizontal, DS.Space.s2 + 1)
                .padding(.vertical, DS.Space.s1)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.xs)
                        .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
                )

            Spacer(minLength: 0)

            DSRangeTabs(selection: $range)
        }
        .padding(.horizontal, DS.Space.s7)
        .padding(.top, DS.Space.s5)            // clears OS title bar zone
        .padding(.bottom, DS.Space.s5)
        .background(
            DS.Color.bgBase
                .overlay(
                    DS.Color.borderSubtle.frame(height: 1),
                    alignment: .bottom
                )
        )
    }
}

// MARK: - Range tabs
//
// 7D / 30D / 90D / All — matches the design's `.range-tabs` group in
// the page header. The range scopes the three stat cards and the Top
// apps panel. The activity calendar is independent (it has its own
// month navigator).

enum HomeRange: String, CaseIterable, Identifiable, Sendable {
    case d7, d30, d90, all

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .d7:  return "7D"
        case .d30: return "30D"
        case .d90: return "90D"
        case .all: return "All"
        }
    }

    var scopeLabel: String {
        switch self {
        case .d7:  return "Last 7 days"
        case .d30: return "Last 30 days"
        case .d90: return "Last 90 days"
        case .all: return "All time"
        }
    }

    /// Day window for `StatsSnapshot.totals(overLastDays:)`. `nil` for
    /// "All" — caller falls back to lifetime totals.
    var days: Int? {
        switch self {
        case .d7:  return 7
        case .d30: return 30
        case .d90: return 90
        case .all: return nil
        }
    }
}

private struct DSRangeTabs: View {
    @Binding var selection: HomeRange

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HomeRange.allCases) { range in
                let isSelected = range == selection
                Button {
                    selection = range
                } label: {
                    Text(range.shortLabel)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(isSelected ? DS.Color.textPrimary : DS.Color.textTertiary)
                        .padding(.horizontal, DS.Space.s3)
                        .frame(height: 24)
                        .background(
                            isSelected ? DS.Color.bgOverlay : .clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.xs + 1)
                        )
                }
                .buttonStyle(.plain)
                .animation(DS.Motion.fast, value: isSelected)
                .accessibilityLabel(range.scopeLabel)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(DS.Color.bgInset, in: RoundedRectangle(cornerRadius: DS.Radius.sm + 1))
    }
}

// MARK: - Stats summary

/// Aggregated counts shown in the Home tab, scoped by the selected
/// `HomeRange`. Reads from the lifetime `StatsSnapshot`; "All"
/// returns lifetime totals directly. WPM is now computed from real
/// session duration captured at hotkey-release; legacy sessions
/// without duration data contribute 0 seconds and are excluded from
/// the divisor.
struct HomeStats: Equatable {
    /// 47 WPM is a commonly cited keyboard typing average; we
    /// surface it as the "vs typing avg." comparison on the WPM
    /// card.
    static let typingWPM: Int = 47

    let range: HomeRange
    let totalWords: Int
    let totalSessions: Int
    /// Total dictation time over the selected window. 0 when no
    /// duration data has been recorded yet (legacy sessions).
    let totalDurationSeconds: TimeInterval
    /// Time saved vs typing at `typingWPM`. Clamped at 0 — possible
    /// to go negative if the user dictates very slowly relative to
    /// their typing speed, but showing a negative "time saved" is
    /// confusing UX.
    let timeSavedSeconds: TimeInterval
    /// Average WPM across the window. `nil` when there's no usable
    /// duration data (totalDuration ≈ 0 or totalWords == 0); the
    /// card renders "—" in that state.
    let averageWPM: Int?

    init(summary: StatsSnapshot, range: HomeRange) {
        let totals = summary.totals(overLastDays: range.days)
        self.range = range
        self.totalWords = totals.words
        self.totalSessions = totals.sessions
        self.totalDurationSeconds = totals.durationSeconds

        // WPM uses the **matched pair** (`durationWords`,
        // `durationSeconds`) — both come from the same set of timed
        // sessions. Using `totalWords` here would include legacy
        // sessions without timing data in the numerator and blow up
        // the rate (3 new measured words ÷ 0.5 s of duration carried
        // over from 1000 legacy words ≈ 10 000 WPM). Floor of 1 s on
        // the denom guards against quick aborts.
        if totals.durationWords > 0 && totals.durationSeconds > 1.0 {
            let minutes = totals.durationSeconds / 60.0
            self.averageWPM = max(1, Int((Double(totals.durationWords) / minutes).rounded()))
        } else {
            self.averageWPM = nil
        }

        // Time saved compares typing-time *of the same matched
        // words* against their measured dictation duration. Mixing
        // populations here would either over- or under-state savings
        // depending on which leg had legacy data.
        let typingSeconds = Double(totals.durationWords) / Double(Self.typingWPM) * 60.0
        self.timeSavedSeconds = max(0, typingSeconds - totals.durationSeconds)
    }

    static func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.count
    }
}

private struct HomeStatsRow: View {
    let stats: HomeStats

    var body: some View {
        HStack(spacing: DS.Space.s4) {
            StatCard(
                icon: .sparkle,
                label: "Words transcribed",
                value: stats.totalWords.formatted(.number.grouping(.automatic)),
                unit: "words",
                delta: Self.wordsCardDelta(for: stats),
                deltaTone: .neutral
            )
            StatCard(
                icon: .bolt,
                label: "Time saved",
                value: HomeStatsRow.formatDuration(stats.timeSavedSeconds),
                unit: nil,
                delta: stats.totalWords > 0
                    ? "vs typing at \(HomeStats.typingWPM) wpm"
                    : "—",
                deltaTone: .positive
            )
            StatCard(
                icon: .sort,
                label: "Average WPM",
                value: stats.averageWPM.map { "\($0)" } ?? "—",
                unit: stats.averageWPM == nil ? nil : "wpm",
                delta: stats.averageWPM == nil
                    ? "Need more dictation time"
                    : "vs typing avg. \(HomeStats.typingWPM) wpm",
                deltaTone: .neutral
            )
        }
    }

    /// Words-card subtitle. Replaces the previous range-label
    /// ("Last 30 days") with the user's actual dictation time over the
    /// window — the range is already shown in the page header pill and
    /// repeated on every card was redundant. Fallback to the range
    /// label is only for legacy sessions that have words but no
    /// duration data (totalDuration ≈ 0), where rendering "0m of
    /// dictation" alongside a non-zero word count would mislead.
    static func wordsCardDelta(for stats: HomeStats) -> String {
        if stats.totalWords == 0 { return "No words yet — hold ⌥ to dictate" }
        if stats.totalDurationSeconds <= 0 { return stats.range.scopeLabel }
        return "\(formatDuration(stats.totalDurationSeconds)) of dictation"
    }

    /// Formats positive seconds as "Xh YYm" / "YYm" / "YYs". We don't
    /// surface partial-second figures — the input is always derived
    /// from word totals, so sub-second numbers are noise.
    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total <= 0 { return "0m" }
        let hours = total / 3600
        let mins  = (total % 3600) / 60
        let secs  = total % 60
        if hours > 0 { return "\(hours)h \(String(format: "%02d", mins))m" }
        if mins  > 0 { return "\(mins)m" }
        return "\(secs)s"
    }
}

private struct StatCard: View {
    let icon: DSIconName
    let label: String
    let value: String
    let unit: String?
    let delta: String?
    let deltaTone: DeltaTone

    enum DeltaTone { case positive, neutral }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s2 + 2) {  // 6 pt
                DSIcon(name: icon, size: 12, color: DS.Color.accentFg)
                Text(label)
                    .font(DS.Font.labelMono())
                    .textCase(.uppercase)
                    .foregroundStyle(DS.Color.textTertiary)
                    .tracking(0.6)
            }

            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2 + 2) {
                Text(value)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(DS.Color.textPrimary)
                    .monospacedDigit()
                    .kerning(-0.8)
                if let unit {
                    Text(unit)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(DS.Color.textTertiary)
                }
            }
            .padding(.top, DS.Space.s3)

            if let delta {
                Text(delta)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(deltaTone == .positive ? DS.Color.successFg : DS.Color.textTertiary)
                    .padding(.top, DS.Space.s2 + 2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, DS.Space.s6)     // 20 pt
        .padding(.top, DS.Space.s5 + 2)         // 18 pt
        .padding(.bottom, DS.Space.s5)          // 16 pt
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg - 2))   // 10 pt
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg - 2)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
    }

    private var cardBackground: some View {
        ZStack {
            DS.Color.bgSurface
            // Violet glow in the top-right corner — matches the design's
            // `radial-gradient(60% 100% at 100% 0%, accent 8%, transparent)`.
            RadialGradient(
                colors: [DS.Color.accent.opacity(0.10), .clear],
                center: UnitPoint(x: 1.0, y: 0.0),
                startRadius: 0,
                endRadius: 220
            )
            .blendMode(.plusLighter)
        }
    }
}

// MARK: - Top apps panel

private struct HomeAppsPanel: View {
    let summary: StatsSnapshot
    let range: HomeRange

    var body: some View {
        Panel(title: "Top apps", meta: range.scopeLabel) {
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                let rows = appRows()
                if rows.isEmpty {
                    EmptyPanelMessage(
                        icon: .grid,
                        message: emptyMessage
                    )
                    .padding(.top, DS.Space.s3)
                } else {
                    ForEach(rows, id: \.bundleID) { row in
                        AppRowView(row: row, maxWords: rows.first?.words ?? 1)
                    }
                }
            }
            .padding(.horizontal, DS.Space.s5 + 2)   // 18 pt
            .padding(.top, DS.Space.s2)
            .padding(.bottom, DS.Space.s5)
        }
    }

    /// Empty-state copy reflects whether the user has never dictated
    /// (lifetime empty) vs the windowed view simply has no hits in
    /// the chosen range (lifetime has data, window is empty).
    private var emptyMessage: String {
        if summary.totalWords == 0 {
            return "No app activity yet."
        }
        switch range {
        case .all: return "No app activity yet."
        case .d7:  return "No activity in the last 7 days."
        case .d30: return "No activity in the last 30 days."
        case .d90: return "No activity in the last 90 days."
        }
    }

    /// Top 5 apps by words within the selected window. Share is
    /// computed against the **window's total** words (across all apps,
    /// not just the top 5) so percentages reflect "of all dictation in
    /// this window, X% landed in Slack".
    private func appRows() -> [HomeAppRow] {
        let top = summary.topApps(overLastDays: range.days, limit: 5)
        let denom = max(1, summary.totals(overLastDays: range.days).words)
        return top.map { row in
            HomeAppRow(
                bundleID: row.bundleID,
                name: row.name,
                words: row.words,
                share: Double(row.words) / Double(denom)
            )
        }
    }
}

private struct HomeAppRow: Equatable {
    let bundleID: String
    let name: String
    let words: Int
    let share: Double
}

private struct AppRowView: View {
    let row: HomeAppRow
    let maxWords: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2 + 2) {  // 6 pt
            HStack(spacing: DS.Space.s3 + 2) {                    // 10 pt
                AppIconView(
                    bundleID: row.bundleID,
                    name: row.name,
                    cornerRadius: DS.Radius.sm
                )
                .frame(width: 22, height: 22)

                Text(row.name)
                    .font(DS.Font.bodySM())
                    .foregroundStyle(DS.Color.textPrimary)

                Spacer(minLength: DS.Space.s3)

                HStack(spacing: DS.Space.s2) {
                    Text(row.words.formatted(.number.grouping(.automatic)))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.Color.textPrimary)
                    Text("·")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(DS.Color.textQuaternary)
                    Text("\(Int((row.share * 100).rounded()))%")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(DS.Color.textSecondary)
                }
                .monospacedDigit()
            }

            Meter(progress: maxWords > 0 ? Double(row.words) / Double(maxWords) : 0)
                .padding(.leading, 22 + DS.Space.s3 + 2)
        }
    }
}

/// 4 pt thin meter bar with an accent gradient fill.
private struct Meter: View {
    let progress: Double  // 0...1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(DS.Color.bgInset)
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [DS.Color.accentFg, DS.Color.accent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * max(0, min(1, progress)))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Activity calendar

private struct HomeActivityCalendar: View {
    let summary: StatsSnapshot

    @State private var visibleMonth: Date = Date()

    /// Width the calendar Panel naturally needs so its container
    /// hugs the 7-column grid (no empty space on either side). Derived
    /// from `CalendarGridLayout.maxCellSize` + cell spacing + panel
    /// horizontal padding. Update both ends together if cell sizing
    /// changes.
    ///   7 × maxCellSize(32)  = 224
    /// + 6 × cellSpacing(4)   =  24
    /// + 2 × panelPadH(18)    =  36
    /// =                       284
    static let naturalWidth: CGFloat = 284

    var body: some View {
        Panel(
            title: "Activity",
            meta: monthLabel(for: visibleMonth, format: "MMM yyyy")
        ) {
            VStack(alignment: .leading, spacing: DS.Space.s3 + 2) {
                monthControls
                grid
                legend
            }
            .padding(.horizontal, DS.Space.s5 + 2)
            .padding(.top, DS.Space.s2)
            .padding(.bottom, DS.Space.s5)
        }
    }

    private var monthControls: some View {
        HStack(spacing: DS.Space.s2 + 2) {
            ArrowButton(direction: .left) { step(-1) }
            ArrowButton(direction: .right) { step(1) }
            Text(monthLabel(for: visibleMonth, format: "LLLL yyyy"))
                .font(DS.Font.bodySM(.semibold))
                .foregroundStyle(DS.Color.textPrimary)
            Spacer(minLength: 0)
        }
    }

    private var grid: some View {
        let cells = monthGrid(for: visibleMonth, summary: summary)
        // Hand-rolled layout instead of `LazyVGrid`: the lazy grid was
        // measuring its first row's height (the DoW "M T W T F S S"
        // text ≈ 18 pt) and propagating that height to every later
        // row, which collapsed our square cells vertically. With a
        // bespoke `Layout` we compute cellSize from the panel width
        // and place each cell with an exact square proposal — DoW row
        // gets its own fixed slot above.
        return CalendarGridLayout() {
            ForEach(0..<7, id: \.self) { i in
                let dows = ["M", "T", "W", "T", "F", "S", "S"]
                Text(dows[i])
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(DS.Color.textQuaternary)
                    .tracking(0.6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ForEach(cells.indices, id: \.self) { i in
                CalendarDayCell(cell: cells[i])
            }
        }
    }

    private var legend: some View {
        HStack(spacing: DS.Space.s3) {
            Text("Less")
                .font(.system(size: 10, design: .monospaced))
                .textCase(.uppercase)
                .foregroundStyle(DS.Color.textQuaternary)
                .tracking(0.6)
            HStack(spacing: 2) {
                // Levels 1…4 only — level 0 (no activity) is
                // rendered as transparent in the grid, so showing it
                // in the legend would just be an empty square. The
                // legend communicates the *intensity ramp* for days
                // with at least one session.
                ForEach(1...4, id: \.self) { lvl in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(intensityColor(level: lvl))
                        .frame(width: 10, height: 10)
                }
            }
            Text("More")
                .font(.system(size: 10, design: .monospaced))
                .textCase(.uppercase)
                .foregroundStyle(DS.Color.textQuaternary)
                .tracking(0.6)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    private func step(_ delta: Int) {
        if let next = Calendar.current.date(byAdding: .month, value: delta, to: visibleMonth) {
            visibleMonth = next
        }
    }

    private func monthLabel(for date: Date, format: String) -> String {
        let f = DateFormatter()
        f.dateFormat = format
        return f.string(from: date)
    }
}

private struct ArrowButton: View {
    enum Direction { case left, right }
    let direction: Direction
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            DSIcon(
                name: direction == .left ? .chevronLeft : .chevronRight,
                size: 12,
                color: hovered ? DS.Color.textPrimary : DS.Color.textTertiary
            )
            .frame(width: 22, height: 22)
            .background(
                hovered ? DS.Color.bgHover : .clear,
                in: RoundedRectangle(cornerRadius: DS.Radius.xs + 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.fast, value: hovered)
    }
}

/// A single calendar cell.
private struct CalendarDay {
    let day: Int
    let isInside: Bool
    let isToday: Bool
    /// Intensity bucket 0…4, already normalised to the visible month's
    /// max activity by `monthGrid`. 0 means "no activity".
    let count: Int
}

private struct CalendarDayCell: View {
    let cell: CalendarDay
    @State private var hovered = false

    var body: some View {
        // `cell.count` is already a 0…4 intensity bucket (see
        // `monthGrid`). Days with zero activity render with NO
        // background — the chrome only appears once the user has
        // actually dictated that day. Today gets a small accent dot
        // below the digit instead of a border.
        let level = cell.count
        let hasActivity = cell.isInside && level > 0

        ZStack {
            if hasActivity {
                RoundedRectangle(cornerRadius: 6)
                    .fill(intensityColor(level: level))
            }

            Text("\(cell.day)")
                .font(.system(
                    size: 11.5,
                    weight: cell.isToday ? .semibold : .regular,
                    design: .monospaced
                ))
                .foregroundStyle(textColor(level: level))
                .monospacedDigit()

            if cell.isToday {
                // 3-pt accent dot below the digit. Offset is in cell
                // coordinates: the cell is ~32 pt, digit is centred,
                // so y=+9 puts the dot just under the baseline with a
                // small visual gap. Doesn't push the digit upward
                // because it overlays.
                Circle()
                    .fill(DS.Color.accent)
                    .frame(width: 3, height: 3)
                    .offset(y: 9)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(cell.isInside ? 1 : 0.4)
        .scaleEffect(hovered && cell.isInside ? 1.04 : 1.0)
        .animation(DS.Motion.fast, value: hovered)
        .onHover { hovered = $0 }
    }

    private func textColor(level: Int) -> Color {
        if cell.isToday { return DS.Color.accentFg }
        if !cell.isInside { return DS.Color.textQuaternary }
        switch level {
        case 0:    return DS.Color.textSecondary
        case 1, 2: return DS.Color.textPrimary
        default:   return .white
        }
    }
}

/// Pre-bucketed intensity (0 = no activity, 1…4 stronger).
/// Level 0 returns `.clear` — days with no recorded activity show
/// NO background chrome at all (per design feedback). The cell-fill
/// only appears once the user has dictated that day.
private func intensityColor(level: Int) -> Color {
    switch level {
    case 0: return .clear
    case 1: return DS.Color.accent.opacity(0.18)
    case 2: return DS.Color.accent.opacity(0.30)
    case 3: return DS.Color.accent.opacity(0.45)
    default: return DS.Color.accent.opacity(0.60)
    }
}

/// Builds the 6-row grid for the visible month, padded with leading
/// (previous month) and trailing (next month) days. Mon-anchored to
/// match the design's "M T W T F S S" header. Intensity buckets are
/// normalised to the **month's** busiest day so a quiet month and a
/// busy month both produce visible contrast without one washing out
/// the other.
private func monthGrid(for visibleMonth: Date, summary: StatsSnapshot) -> [CalendarDay] {
    var calendar = Calendar(identifier: .iso8601)
    calendar.firstWeekday = 2  // Monday

    let comps = calendar.dateComponents([.year, .month], from: visibleMonth)
    guard let firstOfMonth = calendar.date(from: comps),
          let monthRange = calendar.range(of: .day, in: .month, for: firstOfMonth)
    else { return [] }

    let daysInMonth = monthRange.count
    let year = comps.year ?? 1970
    let month = comps.month ?? 1

    // Pull the raw session counts for this month directly from
    // `dayBuckets` — `StatsSnapshot.dayKey` is the same format
    // `StatsStore` writes (local-calendar yyyy-MM-dd).
    var rawCounts: [Int: Int] = [:]
    var maxCount = 0
    for d in 1...daysInMonth {
        let key = String(format: "%04d-%02d-%02d", year, month, d)
        let n = summary.dayBuckets[key]?.sessions ?? 0
        if n > 0 {
            rawCounts[d] = n
            maxCount = max(maxCount, n)
        }
    }

    // Normalise to 1…4 against the month's max so quiet months still
    // show full contrast. A day with 0 sessions stays at 0.
    func bucket(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        guard maxCount > 1 else { return 1 }
        // Quartile bands: 0..25% → 1, ..50 → 2, ..75 → 3, ..100 → 4.
        let share = Double(count) / Double(maxCount)
        switch share {
        case 0.75...:  return 4
        case 0.5..<0.75: return 3
        case 0.25..<0.5: return 2
        default:         return 1
        }
    }

    // Number of leading "outside" cells: 0 for Mon, 1 for Tue, …, 6 for Sun.
    let weekdayOfFirst = calendar.component(.weekday, from: firstOfMonth)  // 1=Sun … 7=Sat
    let mondayBased = (weekdayOfFirst + 5) % 7   // Mon=0 … Sun=6
    let leading = mondayBased

    // Previous month's trailing days.
    var cells: [CalendarDay] = []
    if leading > 0,
       let prev = calendar.date(byAdding: .month, value: -1, to: firstOfMonth),
       let prevRange = calendar.range(of: .day, in: .month, for: prev) {
        let prevCount = prevRange.count
        for offset in (0..<leading).reversed() {
            let day = prevCount - offset
            cells.append(CalendarDay(day: day, isInside: false, isToday: false, count: 0))
        }
    }

    // Current month days.
    let today = Date()
    let isVisibleMonthToday = calendar.isDate(today, equalTo: visibleMonth, toGranularity: .month)
    let todayDay = calendar.component(.day, from: today)
    for d in 1...daysInMonth {
        cells.append(CalendarDay(
            day: d,
            isInside: true,
            isToday: isVisibleMonthToday && d == todayDay,
            count: bucket(rawCounts[d] ?? 0)
        ))
    }

    // Pad to a full 6-row (42-cell) grid with next month days.
    let trailing = max(0, 42 - cells.count)
    for d in 1...max(1, trailing) where trailing > 0 {
        cells.append(CalendarDay(day: d, isInside: false, isToday: false, count: 0))
        if cells.count == 42 { break }
    }
    return cells
}

// MARK: - Calendar layout
//
// Lays out 49 subviews: the first 7 are the M-T-W-T-F-S-S day-of-week
// header, the remaining 42 are the six weeks of day cells. Cell size
// is derived from the proposed width (the panel's interior), so each
// cell is a deterministic square — `LazyVGrid` was deciding row
// heights from the first row's content (the small DoW text), which
// flattened the day cells.

private struct CalendarGridLayout: Layout {
    /// Height reserved above the cell grid for the DoW labels.
    let dowHeight: CGFloat = 16
    /// Gap between the DoW row and the first week.
    let dowSpacing: CGFloat = 4
    /// Gap between adjacent weeks (and adjacent columns).
    let cellSpacing: CGFloat = 4
    /// Cell-size floor so the grid stays usable on narrow windows.
    let minCellSize: CGFloat = 22
    /// Cell-size ceiling. With `1fr` columns and a wide window the
    /// natural cell could grow to ~50 pt+, which looks oversized
    /// next to a small 11.5 pt digit. Cap at 32 pt; if the panel is
    /// wider, the grid is left-aligned and there's empty space on
    /// the right edge.
    let maxCellSize: CGFloat = 32

    private func cellSize(for width: CGFloat) -> CGFloat {
        let natural = (width - cellSpacing * 6) / 7
        return min(maxCellSize, max(minCellSize, natural))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.width ?? (minCellSize * 7 + cellSpacing * 6)
        let cs = cellSize(for: proposed)
        // We always render at the proposed width (the panel decides
        // how wide we are); height is the *cell-size-driven*
        // intrinsic height of the grid.
        let height = dowHeight
            + dowSpacing
            + cs * 6
            + cellSpacing * 5
        return CGSize(width: proposed, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let cs = cellSize(for: bounds.width)

        // DoW row — subviews 0..<7.
        for col in 0..<7 {
            guard subviews.indices.contains(col) else { return }
            let x = bounds.minX + CGFloat(col) * (cs + cellSpacing)
            subviews[col].place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: cs, height: dowHeight)
            )
        }

        // 6 × 7 day cells — subviews 7..<49. Each is an exact square.
        let firstRowY = bounds.minY + dowHeight + dowSpacing
        for row in 0..<6 {
            for col in 0..<7 {
                let idx = 7 + row * 7 + col
                guard subviews.indices.contains(idx) else { return }
                let x = bounds.minX + CGFloat(col) * (cs + cellSpacing)
                let y = firstRowY + CGFloat(row) * (cs + cellSpacing)
                subviews[idx].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: cs, height: cs)
                )
            }
        }
    }
}

// MARK: - Recent transcripts list

private struct HomeRecentList: View {
    let entries: [HistoryEntry]
    let onDelete: (UUID) -> Void

    var body: some View {
        Panel(title: "Recent transcripts", meta: "Last \(entries.count)") {
            if entries.isEmpty {
                EmptyPanelMessage(
                    icon: .inbox,
                    message: "No transcripts yet — hold ⌥ Right Option to start."
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.s8)
            } else {
                let reversed = Array(entries.reversed())
                VStack(spacing: 0) {
                    ForEach(Array(reversed.enumerated()), id: \.element.id) { i, entry in
                        HistoryRowView(
                            entry: entry,
                            isNewest: i == 0,
                            onDelete: { onDelete(entry.id) }
                        )
                        if i < reversed.count - 1 {
                            DSSeparator(leadingPadding: HistoryRowView.separatorLeading)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Panel chrome
//
// Shared shell for the three lower panels: rounded surface card, subtle
// border, an internal head row with title + meta. Header padding
// matches the design's `.panel-head` (14 18 10).

private struct Panel<Content: View>: View {
    let title: String
    let meta: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary)
                Spacer(minLength: 0)
                if let meta {
                    Text(meta.uppercased())
                        .font(DS.Font.labelMono())
                        .foregroundStyle(DS.Color.textQuaternary)
                        .tracking(0.6)
                }
            }
            .padding(.horizontal, DS.Space.s5 + 2)
            .padding(.top, DS.Space.s4 + 2)
            .padding(.bottom, DS.Space.s3 + 2)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg - 2))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg - 2)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
    }
}

private struct EmptyPanelMessage: View {
    let icon: DSIconName
    let message: String

    var body: some View {
        VStack(spacing: DS.Space.s3) {
            DSIcon(name: icon, size: 18, color: DS.Color.textQuaternary)
            Text(message)
                .font(DS.Font.bodySM())
                .foregroundStyle(DS.Color.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.s5)
    }
}
