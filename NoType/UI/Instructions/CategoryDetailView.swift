import AppKit
import SwiftUI

/// Drill-in for a single category: gradient banner + editable prompt
/// (or explain card for AX-only / no-prompt categories) + list of apps
/// currently assigned. Activated by tapping a row in `InstructionsView`.
struct CategoryDetailView: View {
    let category: AppCategory
    let onBack: () -> Void

    @Environment(AppState.self) private var appState

    /// Identifier of the app currently expanded in the apps list (when
    /// non-nil, the row inlines its Move / Re-classify / Remove
    /// actions below the name).
    @State private var expandedBundleID: String?
    @State private var promptDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s6) {
                    banner
                    if isExplainCategory {
                        explainCard
                    } else {
                        promptPanel
                    }
                    appsPanel
                }
                .padding(.horizontal, DS.Space.s7 + 4)
                .padding(.top, DS.Space.s7)
                .padding(.bottom, DS.Space.s9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            promptDraft = appState.categoryPromptOverrides[category] ?? ""
        }
        .onChange(of: category) { _, newValue in
            promptDraft = appState.categoryPromptOverrides[newValue] ?? ""
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Space.s3 + 2) {
            backButton
            Text("Instructions / \(category.displayName)")
                .font(DS.Font.labelMono())
                .foregroundStyle(DS.Color.textTertiary)
                .tracking(0.4)
                .padding(.horizontal, DS.Space.s2 - 1)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.xs)
                        .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
                )
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text("esc")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DS.Color.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
                    )
                Text("back")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(DS.Color.textQuaternary)
                    .tracking(0.4)
            }
        }
        .padding(.horizontal, DS.Space.s7 + 4)
        .padding(.top, DS.Space.s5)
        .padding(.bottom, DS.Space.s5)
        .background(
            DS.Color.bgBase
                .overlay(DS.Color.borderSubtle.frame(height: 1), alignment: .bottom)
        )
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 4) {
                DSIcon(name: .chevronLeft, size: 13, color: DS.Color.textSecondary)
                Text("Instructions")
                    .font(DS.Font.body(.medium))
                    .foregroundStyle(DS.Color.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }

    // MARK: - Banner

    private var banner: some View {
        HStack(alignment: .center, spacing: DS.Space.s4) {
            CategoryIconTile(category: category, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DS.Space.s2 + 1) {
                    Text(category.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary)
                    if hasOverride && !isExplainCategory {
                        InstructionsCustomisedPill()
                    }
                }
                Text(category.blurb)
                    .font(DS.Font.bodySM())
                    .foregroundStyle(DS.Color.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            bannerCount
        }
        .padding(.horizontal, DS.Space.s5 + 2)
        .padding(.vertical, DS.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topLeading) {
                DS.Color.bgSurface
                // Soft category-tinted glow seeping in from top-left.
                RadialGradient(
                    gradient: Gradient(colors: [
                        CategoryPalette.glow(for: category),
                        Color.clear
                    ]),
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 320
                )
                .allowsHitTesting(false)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg - 2))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg - 2)
                .strokeBorder(DS.Color.borderSubtle, lineWidth: DS.Border.hairline)
        )
    }

    @ViewBuilder
    private var bannerCount: some View {
        if category == .search {
            Text("Detected automatically by AX role")
                .font(DS.Font.labelMono())
                .tracking(0.4)
                .foregroundStyle(DS.Color.textTertiary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(assignedCount)")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DS.Color.textPrimary)
                    .monospacedDigit()
                Text(assignedCount == 1 ? "app in this category" : "apps in this category")
                    .font(.system(size: 11, design: .monospaced))
                    .tracking(0.3)
                    .foregroundStyle(DS.Color.textTertiary)
            }
        }
    }

    // MARK: - Prompt editor card

    private var promptPanel: some View {
        let highlighted = hasOverride
        return InstructionsPanel(
            title: "Category prompt",
            meta: "SENT BEFORE EACH SESSION"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                PromptTextEditor(
                    text: $promptDraft,
                    placeholder: category.defaultPrompt ?? "",
                    minHeight: 200,
                    isMono: true,
                    isHighlighted: highlighted,
                    onCommit: { newValue in
                        appState.updateCategoryPrompt(category, prompt: newValue)
                    }
                )
                .padding(.horizontal, DS.Space.s5 + 2)
                .padding(.bottom, DS.Space.s3)

                editorFoot
            }
        }
    }

    private var editorFoot: some View {
        HStack(spacing: DS.Space.s3) {
            Text(hasOverride
                 ? "Your override is sent in place of the default."
                 : "Empty field uses the default shown in grey.")
                .font(.system(size: 11, design: .monospaced))
                .tracking(0.3)
                .foregroundStyle(DS.Color.textQuaternary)
            Spacer(minLength: 0)
            if hasOverride {
                DSSecondaryButton(label: "Reset to default") {
                    promptDraft = ""
                    appState.resetCategoryPrompt(category)
                }
            }
        }
        .padding(.horizontal, DS.Space.s5 + 2)
        .padding(.top, DS.Space.s3)
        .padding(.bottom, DS.Space.s4 + 2)
    }

    // MARK: - Explain card (search / uncategorized)

    private var explainCard: some View {
        InstructionsPanel(
            title: "How this category works",
            meta: "READ ONLY"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                HStack(alignment: .top, spacing: DS.Space.s4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: DS.Radius.md)
                            .fill(DS.Color.bgInset)
                            .frame(width: 32, height: 32)
                        DSIcon(
                            name: category == .search ? .search : .folder,
                            size: 14,
                            color: DS.Color.textSecondary
                        )
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        explainTitleLine
                        explainSubLine
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(DS.Space.s5)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .strokeBorder(
                            DS.Color.borderDefault,
                            style: StrokeStyle(lineWidth: DS.Border.hairline, dash: [4, 3])
                        )
                )
            }
            .padding(.horizontal, DS.Space.s5 + 2)
            .padding(.top, DS.Space.s2)
            .padding(.bottom, DS.Space.s5)
        }
    }

    @ViewBuilder
    private var explainTitleLine: some View {
        if category == .search {
            (
                Text("Auto-detected at session start. ").bold()
                + Text("When the focused element is a search field — determined by its ")
                + Text("AX: AXSearchField").font(.system(size: 11.5, design: .monospaced))
                + Text(" role, or any text input whose identifier or title contains ")
                + Text("search / address / url").font(.system(size: 11.5, design: .monospaced))
                + Text(" — NoType drops the active category prompt and sends a short query-style hint to Gemini instead.")
            )
            .font(DS.Font.bodySM())
            .foregroundStyle(DS.Color.textSecondary)
        } else {
            (
                Text("No prompt is sent. ").bold()
                + Text("Apps land here when the classifier can't confidently assign one of the other categories. Your global instruction still applies; nothing else is added on top.")
            )
            .font(DS.Font.bodySM())
            .foregroundStyle(DS.Color.textSecondary)
        }
    }

    @ViewBuilder
    private var explainSubLine: some View {
        if category == .search {
            Text("That's why Search can't be assigned to an app manually, and why no app counter is shown — it's a per-session AX signal, not a cache entry.")
                .font(DS.Font.bodySM())
                .foregroundStyle(DS.Color.textTertiary)
        } else {
            Text("Re-classify any row below to move it into a real category — or move it manually.")
                .font(DS.Font.bodySM())
                .foregroundStyle(DS.Color.textTertiary)
        }
    }

    // MARK: - Apps card

    private var appsPanel: some View {
        InstructionsPanel(
            title: appsPanelTitle,
            meta: appsPanelMeta
        ) {
            if category == .search {
                emptyState(
                    icon: .search,
                    title: "No app assignment",
                    sub: "Search activates from the focused element's accessibility role — it doesn't belong to any specific app."
                )
            } else {
                let rows = apps(in: category)
                if rows.isEmpty {
                    emptyState(
                        icon: .inbox,
                        title: "No apps yet",
                        sub: "Dictate into any app — it'll be classified and show up here automatically."
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.bundleID) { idx, record in
                            if idx > 0 {
                                DS.Color.borderSubtle.frame(height: 1)
                            }
                            AppAssignmentRow(
                                record: record,
                                isExpanded: expandedBundleID == record.bundleID,
                                onTap: { toggleExpand(record.bundleID) },
                                onMove: { destination in
                                    appState.moveAppToCategory(bundleID: record.bundleID, to: destination)
                                },
                                onReclassify: {
                                    appState.refreshAssignment(
                                        bundleID: record.bundleID,
                                        displayName: appNameForBundle(record.bundleID)
                                    )
                                },
                                onRemove: {
                                    appState.removeAssignment(bundleID: record.bundleID)
                                }
                            )
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var appsPanelTitle: String {
        category == .search ? "Apps" : "Apps in this category"
    }

    private var appsPanelMeta: String? {
        if category == .search { return "NOT APPLICABLE" }
        let count = apps(in: category).count
        return "\(count) CACHED"
    }

    private func emptyState(icon: DSIconName, title: String, sub: String) -> some View {
        VStack(spacing: DS.Space.s3) {
            ZStack {
                Circle()
                    .fill(DS.Color.bgInset)
                    .frame(width: 36, height: 36)
                DSIcon(name: icon, size: 14, color: DS.Color.textTertiary)
            }
            .padding(.bottom, 2)
            Text(title)
                .font(DS.Font.body(.medium))
                .foregroundStyle(DS.Color.textSecondary)
            Text(sub)
                .font(DS.Font.bodySM())
                .foregroundStyle(DS.Color.textQuaternary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.s8 - 4)
    }

    // MARK: - Helpers

    private var hasOverride: Bool {
        appState.categoryPromptOverrides[category] != nil
    }

    private var isExplainCategory: Bool {
        category == .search || category == .uncategorized
    }

    private var assignedCount: Int {
        appState.categoryAssignments.values.reduce(into: 0) { acc, record in
            if record.category == category { acc += 1 }
        }
    }

    private func apps(in category: AppCategory) -> [AppCategoryAssignment] {
        appState.categoryAssignments.values
            .filter { $0.category == category }
            .sorted { lhs, rhs in
                let lName = appNameForBundle(lhs.bundleID).lowercased()
                let rName = appNameForBundle(rhs.bundleID).lowercased()
                if lName != rName { return lName < rName }
                return lhs.bundleID < rhs.bundleID
            }
    }

    private func toggleExpand(_ bundleID: String) {
        if expandedBundleID == bundleID {
            expandedBundleID = nil
        } else {
            expandedBundleID = bundleID
        }
    }

    /// Best-effort resolution of the app's display name from history
    /// (most recent entry wins) or from the macOS app cache. We never
    /// stored the display name alongside the assignment — keeps the
    /// schema small and lets a renamed app pick up its new label.
    private func appNameForBundle(_ bundleID: String) -> String {
        if let entry = appState.history.first(where: { $0.sourceBundleID == bundleID }) {
            return entry.sourceAppName
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return (Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}

// MARK: - Per-app row

private struct AppAssignmentRow: View {
    let record: AppCategoryAssignment
    let isExpanded: Bool
    let onTap: () -> Void
    let onMove: (AppCategory) -> Void
    let onReclassify: () -> Void
    let onRemove: () -> Void

    @Environment(AppState.self) private var appState
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: DS.Space.s3 + 2) {
                    AppIconView(
                        bundleID: record.bundleID,
                        name: appName,
                        cornerRadius: DS.Radius.sm + 1
                    )
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(appName)
                            .font(DS.Font.body(.medium))
                            .foregroundStyle(DS.Color.textPrimary)
                        Text(record.bundleID)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(DS.Color.textQuaternary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    sourcePill
                    DSIcon(
                        name: isExpanded ? .chevronDown : .chevronRight,
                        size: 12,
                        color: DS.Color.textQuaternary
                    )
                }
                .padding(.horizontal, DS.Space.s5 + 2)
                .padding(.vertical, DS.Space.s4)
                .background((hovered || isExpanded) ? DS.Color.bgHover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dsOnHover { hovered = $0 }
            .animation(DS.Motion.fast, value: hovered)

            if isExpanded {
                actionsRow
                    .padding(.horizontal, DS.Space.s5 + 2)
                    .padding(.bottom, DS.Space.s4)
                    .padding(.leading, 40)
                    .transition(.opacity)
            }
        }
        .animation(DS.Motion.fast, value: isExpanded)
    }

    private var appName: String {
        if let entry = appState.history.first(where: { $0.sourceBundleID == record.bundleID }) {
            return entry.sourceAppName
        }
        return record.bundleID.split(separator: ".").last.map(String.init) ?? record.bundleID
    }

    @ViewBuilder
    private var sourcePill: some View {
        let isManual = record.source == .manual
        HStack(spacing: 4) {
            DSIcon(
                name: isManual ? .user : .sparkle,
                size: 9,
                color: isManual ? DS.Color.accentFg : DS.Color.textTertiary
            )
            Text(isManual ? "MANUAL" : "AUTO")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(isManual ? DS.Color.accentFg : DS.Color.textTertiary)
        }
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(
            isManual ? DS.Color.accentSoft : DS.Color.bgInset,
            in: Capsule()
        )
        .overlay(
            Capsule().strokeBorder(
                isManual ? DS.Color.accentBorder : DS.Color.borderSubtle,
                lineWidth: DS.Border.hairline
            )
        )
    }

    private var actionsRow: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(AppCategory.manuallyAssignableCases) { destination in
                    if destination != record.category {
                        Button(destination.displayName) {
                            onMove(destination)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    DSIcon(name: .folder, size: 11, color: DS.Color.textPrimary)
                    Text("Move to category")
                    DSIcon(name: .chevronDown, size: 10, color: DS.Color.textTertiary)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DS.Color.textPrimary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(DS.Color.bgInset, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                        .strokeBorder(DS.Color.borderDefault, lineWidth: DS.Border.hairline)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if record.source == .auto {
                Button(action: onReclassify) {
                    HStack(spacing: 4) {
                        DSIcon(name: .sparkle, size: 11, color: DS.Color.textPrimary)
                        Text("Re-classify with AI")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.Color.textPrimary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(DS.Color.bgInset, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.sm)
                            .strokeBorder(DS.Color.borderDefault, lineWidth: DS.Border.hairline)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            Button(action: onRemove) {
                HStack(spacing: 4) {
                    DSIcon(name: .trash, size: 11, color: DS.Color.dangerFg)
                    Text("Remove from cache")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DS.Color.dangerFg)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                        .strokeBorder(DS.Color.dangerBorder, lineWidth: DS.Border.hairline)
                )
            }
            .buttonStyle(.plain)
        }
    }
}
