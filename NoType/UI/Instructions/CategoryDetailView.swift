import AppKit
import SwiftUI

/// Drill-in for a single category: editable prompt + list of apps
/// currently assigned to this category + reassign / re-classify / remove
/// menu per app. Activated by tapping a row in `InstructionsView`.
struct CategoryDetailView: View {
    let category: AppCategory
    let onBack: () -> Void

    @Environment(AppState.self) private var appState

    /// Identifier of the app currently expanded in the apps list (when
    /// non-nil, the row shows its bundle id and action buttons below the
    /// name). Tap a row to expand / collapse.
    @State private var expandedBundleID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s7) {
                    promptPanel
                    appsPanel
                }
                .padding(.horizontal, DS.Space.s7)
                .padding(.top, DS.Space.s7)
                .padding(.bottom, DS.Space.s7)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Space.s4) {
            Button(action: onBack) {
                HStack(spacing: DS.Space.s2 + 1) {
                    DSIcon(name: .chevronLeft, size: 14, color: DS.Color.textTertiary)
                    Text("Back")
                        .font(DS.Font.bodySM())
                        .foregroundStyle(DS.Color.textSecondary)
                }
                .padding(.horizontal, DS.Space.s2 + 1)
                .padding(.vertical, DS.Space.s1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            CategoryIconTile(category: category, size: 28)
            Text(category.displayName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary)
            Text(category.blurb)
                .font(DS.Font.bodySM())
                .foregroundStyle(DS.Color.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s7)
        .padding(.top, DS.Space.s5)
        .padding(.bottom, DS.Space.s5)
        .background(
            DS.Color.bgBase
                .overlay(DS.Color.borderSubtle.frame(height: 1), alignment: .bottom)
        )
    }

    // MARK: - Prompt panel

    private var promptPanel: some View {
        InstructionsPanel(
            title: "Category prompt",
            meta: hasOverride ? "CUSTOMISED" : "DEFAULT"
        ) {
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                if category == .uncategorized {
                    Text("No prompt is sent for uncategorized apps — the model falls back to neutral formatting based on the base rules and the on-screen context.")
                        .font(DS.Font.bodySM())
                        .foregroundStyle(DS.Color.textTertiary)
                } else {
                    DSTextEditor(
                        placeholder: category.defaultPrompt ?? "",
                        text: appState.categoryPromptOverrides[category] ?? "",
                        onChange: { newValue in
                            appState.updateCategoryPrompt(category, prompt: newValue)
                        },
                        minHeight: 180
                    )
                    HStack(spacing: DS.Space.s3) {
                        if hasOverride {
                            DSSecondaryButton(label: "Reset to default") {
                                appState.resetCategoryPrompt(category)
                            }
                            Text("Override active — the default prompt is shown as a placeholder. Save by typing; reset to drop your changes.")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.Color.textTertiary)
                        } else {
                            Text("Default prompt for this category. Edit to override.")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.Color.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, DS.Space.s5 + 2)
            .padding(.bottom, DS.Space.s5)
        }
    }

    private var hasOverride: Bool {
        appState.categoryPromptOverrides[category] != nil
    }

    // MARK: - Apps panel

    private var appsPanel: some View {
        InstructionsPanel(
            title: appsPanelTitle,
            meta: appsPanelMeta
        ) {
            if category == .search {
                searchInfoCard
                    .padding(.horizontal, DS.Space.s5 + 2)
                    .padding(.bottom, DS.Space.s5)
            } else {
                let rows = apps(in: category)
                if rows.isEmpty {
                    emptyAppsState
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.bundleID) { idx, record in
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
                            if idx < rows.count - 1 {
                                DSSeparator(leadingPadding: DS.Space.s5 + 2)
                            }
                        }
                    }
                }
            }
        }
    }

    private var appsPanelTitle: String {
        category == .search ? "How search detection works" : "Apps in this category"
    }

    private var appsPanelMeta: String? {
        if category == .search { return nil }
        let count = apps(in: category).count
        return count == 1 ? "1 APP" : "\(count) APPS"
    }

    private var searchInfoCard: some View {
        HStack(alignment: .top, spacing: DS.Space.s4) {
            DSIcon(name: .info, size: 16, color: DS.Color.accentFg)
                .padding(.top, 2)
            Text("Search and address-bar fields are detected automatically when you start dictation. There are no apps to assign here — any focused element whose role or identifier looks like a search field uses this category instead of its app's category.")
                .font(DS.Font.bodySM())
                .foregroundStyle(DS.Color.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(DS.Space.s4)
        .background(DS.Color.accentSoftSubtle, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(DS.Color.accentBorder, lineWidth: DS.Border.hairline)
        )
    }

    private var emptyAppsState: some View {
        VStack(spacing: DS.Space.s3) {
            DSIcon(name: .inbox, size: 18, color: DS.Color.textQuaternary)
            Text("No apps assigned yet.")
                .font(DS.Font.bodySM())
                .foregroundStyle(DS.Color.textTertiary)
            Text("Dictate into an app once — it'll be auto-classified and shown here.")
                .font(.system(size: 11))
                .foregroundStyle(DS.Color.textQuaternary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.s8)
    }

    // MARK: - Helpers

    private func apps(in category: AppCategory) -> [AppCategoryAssignment] {
        appState.categoryAssignments.values
            .filter { $0.category == category }
            .sorted { lhs, rhs in
                // Stable by app name (resolved by appNameForBundle when
                // possible), then bundle id.
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
        // Fall back to the trailing component of the bundle id.
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
                        cornerRadius: DS.Radius.sm
                    )
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(appName)
                            .font(DS.Font.body(.medium))
                            .foregroundStyle(DS.Color.textPrimary)
                        Text(record.bundleID)
                            .font(DS.Font.labelMono())
                            .foregroundStyle(DS.Color.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    DSBadge(text: record.source == .manual ? "manual" : "auto",
                            style: record.source == .manual ? .accent : .neutral)
                    DSIcon(
                        name: isExpanded ? .chevronDown : .chevronRight,
                        size: 14,
                        color: DS.Color.textTertiary
                    )
                }
                .padding(.horizontal, DS.Space.s5 + 2)
                .padding(.vertical, DS.Space.s4)
                .background(hovered ? DS.Color.bgHover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .animation(DS.Motion.fast, value: hovered)

            if isExpanded {
                actionsRow
                    .padding(.horizontal, DS.Space.s5 + 2)
                    .padding(.bottom, DS.Space.s4)
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

    private var actionsRow: some View {
        HStack(spacing: DS.Space.s3) {
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
                    Text("Move to category")
                    DSIcon(name: .chevronDown, size: 11, color: DS.Color.textPrimary)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DS.Color.textPrimary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(DS.Color.bgInset, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(DS.Color.borderDefault, lineWidth: DS.Border.hairline)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if record.source == .auto {
                DSSecondaryButton(label: "Re-classify with AI", action: onReclassify)
            }
            DSLinkButton(label: "Remove from cache", action: onRemove)
            Spacer(minLength: 0)
        }
    }
}
