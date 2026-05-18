import SwiftUI

/// Settings → API → Token usage panel. Segmented range picker
/// (Today / 7d / 30d / All) over 3 stat cells: Input, Output, Cost.
/// Reads from `appState.statsSummary` — the same `StatsSnapshot`
/// mirror Home tab uses.
///
/// The cost cell is **derived** from token totals at the rates
/// pinned in `GeminiPricing`. We factor in cached tokens (a subset
/// of input) at the cache-read rate so the displayed dollar amount
/// matches the actual Gemini bill, even though the cached count
/// itself is no longer surfaced in the UI (revoked 2026-05-18 —
/// not actionable for the typical user).
///
/// Pure helpers (`formatCount`) live as static methods so they can
/// be exercised without standing up a SwiftUI render harness — see
/// `TokenStatsPanelTests`. The cost helpers live next door in
/// `GeminiPricing` for the same reason.
struct TokenStatsPanel: View {
    @Environment(AppState.self) private var appState

    @State private var range: TokenStatsRange = .last7

    var body: some View {
        let totals = appState.statsSummary.tokenTotals(overLastDays: range.days)
        let cost = GeminiPricing.cost(
            input: totals.input,
            output: totals.output,
            cached: totals.cached
        )
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(alignment: .center) {
                Text("Token usage")
                    .font(DS.Font.body(.medium))
                    .foregroundStyle(DS.Color.textPrimary)
                Spacer()
                TokenStatsRangePicker(selection: $range)
            }

            HStack(alignment: .top, spacing: DS.Space.s4) {
                TokenStatCell(label: "Input",  value: Self.formatCount(totals.input))
                TokenStatCell(label: "Output", value: Self.formatCount(totals.output))
                TokenStatCell(label: "Cost",   value: GeminiPricing.formatCost(cost))
            }
        }
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s3 + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pure helpers (testable)

    /// Integer count with grouping separator. 1234 → "1,234".
    /// 0 still renders as "0" — there is no "no data" sentinel for
    /// the count cells; if a window has no usage, every cell reads
    /// "0" (and the Cost cell reads "$0.00").
    static func formatCount(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }
}

// MARK: - Range enum

/// Time windows for the token stats panel. Mirrors `HomeRange`
/// from HomeView (7D / 30D / 90D / All) but uses (Today / 7d /
/// 30d / All) per plan §550 — token usage moves quickly enough
/// that "Today" is more useful than "90D".
enum TokenStatsRange: String, CaseIterable, Identifiable, Sendable {
    case today, last7, last30, all

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .today:  return "Today"
        case .last7:  return "7d"
        case .last30: return "30d"
        case .all:    return "All"
        }
    }

    var scopeLabel: String {
        switch self {
        case .today:  return "Today"
        case .last7:  return "Last 7 days"
        case .last30: return "Last 30 days"
        case .all:    return "All time"
        }
    }

    /// Day window for `StatsSnapshot.tokenTotals(overLastDays:)`.
    /// `nil` for "All" — caller falls back to the lifetime sum
    /// of every recorded day bucket. Do NOT swap to a large
    /// finite value: `tokenTotals` walks calendar offsets, so a
    /// finite ceiling would silently miss older days.
    var days: Int? {
        switch self {
        case .today:  return 1
        case .last7:  return 7
        case .last30: return 30
        case .all:    return nil
        }
    }
}

// MARK: - Range picker

private struct TokenStatsRangePicker: View {
    @Binding var selection: TokenStatsRange

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TokenStatsRange.allCases) { range in
                let isSelected = range == selection
                Button {
                    selection = range
                } label: {
                    Text(range.shortLabel)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(isSelected ? DS.Color.textPrimary : DS.Color.textTertiary)
                        .padding(.horizontal, DS.Space.s3)
                        .frame(height: 22)
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

// MARK: - Single stat cell

private struct TokenStatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DS.Font.labelMono())
                .textCase(.uppercase)
                .foregroundStyle(DS.Color.textTertiary)
                .tracking(0.5)
                .lineLimit(1)
            Text(value)
                .font(DS.Font.title(.medium))
                .foregroundStyle(DS.Color.textPrimary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
