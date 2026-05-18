---
title: "feat: Redesign Settings screen — secondary nav + card sections"
type: feat
status: active
created: 2026-05-18
---

# Redesign Settings screen — secondary nav + card sections

Source design: `claude.ai/design` handoff bundle (extracted to `/tmp/design-bundle/notype/project/app/settings.html`). User-confirmed direction:

- Widen main window to **1180×820** and adopt the two-column Settings shell (220 primary sidebar + 200 settings sub-nav + content).
- Adopt new section taxonomy: **General · Recording · Language & Paste · API & Usage · About**.
- Add About card with **Permissions chips** (Mic / Accessibility / Screen Recording) + **GitHub row**.
- Token usage panel: keep real numbers only — deltas & cache-hits deferred to TECHDEBT.

The previous Settings plan (`docs/plans/2026-05-18-001-feat-settings-screen-plan.md` §118) explicitly rejected an inner sidebar because the window was locked at 1080 wide. **This plan supersedes that decision** by widening the canvas — the trade-off changes once we have a hard design reference to anchor the layout.

---

## Summary

Replace the current scroll-with-headers Settings tab (6 stacked `DSSettingsSection`s in a `ScrollView`) with the design's card-based two-column shell. Settings becomes the only tab whose `mainPane` is itself a 2-column layout — primary sidebar nav (Home / Instructions / Dictionary / Settings) stays unchanged; the inner Settings nav is a `SettingsCategory` enum-driven `@State` switch with 5 panes, each rendered as a vertically-scrolling stack of `DSCard`s containing rows.

---

## Scope Boundaries

**In scope:**
- Widen `MainWindowMetrics.canvasSize` to 1180×820. All three load-bearing sites (`NoTypeApp.defaultSize`, `MainWindowView.frame`, `FixedSizeWindowConfigurator`) updated atomically.
- New `SettingsCategory` enum + secondary sidebar + `SettingsContentHeader` (sticky title + breadcrumb crumb pill).
- New section-level `DSCard` primitive in `DSComponents.swift` (rounded border, optional title + meta, slot for rows).
- New leaf components: `PermissionChip`, `GitHubRow`, `VersionBlock`, `MicSourcePill`, `HowRecordingWorksCallout`, `LanguageChip` (or upgraded `OutputLanguagePicker`).
- Re-grouping logic per the new 5-section taxonomy.
- Wire `PermissionsViewModel` into the About pane's three permission chips with grant/denied/optional state.

**Deferred to follow-up:**
- Token usage **delta** (`+18% vs prev 30d`) and **cache-hits %** indicator — needs `StatsStore` prior-period comparison + cached-token tracking; tracked separately as a TECHDEBT entry.
- Light theme polish — current app is dark-only (per `UI/CLAUDE.md` known gaps); the new design supports both, but we keep dark-only behaviour in this PR.
- Update banner inside the secondary sidebar foot — sidebar foot pill already exists at the main-sidebar level; we don't duplicate it into the Settings nav.

**Outside this product's identity:**
- "Pro · 4,820 min left" account row in the design's primary sidebar — NoType is BYOK / OSS, no accounts. Keep the existing `UpdateBanner` foot instead.

---

## Approach

```text
MainWindowView
└── HStack
    ├── primary sidebar (220 px, unchanged)
    └── mainPane
        └── if selectedTab == .settings → SettingsRoot
            └── HStack
                ├── SettingsSidebar (200 px) — 5 category buttons
                └── SettingsContent
                    ├── sticky header (title + crumb)
                    └── ScrollView
                        └── selected pane (5 panes total)
                            └── VStack of DSCards
                                └── DSCardRow rows
```

This illustrates the intended approach and is directional guidance, not implementation specification.

Each pane is a leaf SwiftUI view (`GeneralPane`, `RecordingPane`, `LanguagePastePane`, `APIUsagePane`, `AboutPane`). They consume the same `@Environment` services as today (`AppState`, `AppearanceController`, `OnboardingState`, `UpdateController`, `PermissionsViewModel`). No new view-models.

---

## Output Structure

```
NoType/UI/Settings/
├── SettingsTabView.swift              (rewritten — shell + pane switch)
├── SettingsCategory.swift             (new — enum + labels + icons)
├── SettingsSidebar.swift              (new)
├── SettingsContentHeader.swift        (new)
├── Panes/
│   ├── GeneralPane.swift              (new)
│   ├── RecordingPane.swift            (new)
│   ├── LanguagePastePane.swift        (new)
│   ├── APIUsagePane.swift             (new)
│   └── AboutPane.swift                (new)
├── Components/
│   ├── PermissionChip.swift           (new)
│   ├── GitHubRow.swift                (new)
│   ├── VersionBlock.swift             (new)
│   ├── MicSourcePill.swift            (new)
│   ├── HowRecordingWorksCallout.swift (new)
│   └── LanguageChip.swift             (new — extracted from OutputLanguagePicker if needed)
├── GeminiKeyRow.swift                 (kept; minor re-style to match card row)
├── MicChangeRow.swift                 (kept; absorbed into RecordingPane via MicSourcePill)
├── OutputLanguagePicker.swift         (kept; absorbed into LanguagePastePane)
├── TokenStatsPanel.swift              (kept; re-styled to live inside DSCard)
└── ShortcutRebindSheet.swift          (kept; unchanged)
```

`DSCard` lives in `NoType/UI/DSComponents.swift` (existing file) alongside other shared primitives.

---

## Implementation Units

### U1. Widen the main window to 1180×820

**Goal:** Atomically update the canvas size at the three load-bearing sites. Without this, the secondary nav has no room to live.

**Files:**
- `NoType/UI/MainWindow.swift` — `MainWindowMetrics.canvasSize` → `NSSize(width: 1180, height: 820)`.
- `NoType/NoTypeApp.swift` — verify the `.defaultSize(...)` call reads from `MainWindowMetrics.canvasSize` (no hard-coded literals).

**Verification:** App launches, main window opens at 1180×820, all existing tabs (Home, Instructions, Dictionary) render correctly with no clipping. Sidebar still 220 px, mainPane now 960 px wide.

**Test scenarios:** none — pure constant change. Manual smoke against Home / Instructions / Dictionary tabs is the verification.

---

### U2. Add `DSCard` primitive to DSComponents.swift

**Goal:** Shared card chrome (border + corner radius + optional `title` + optional `meta` text on the head) consumed by every pane.

**Files:**
- `NoType/UI/DSComponents.swift` — add `DSCard<Content: View>` and `DSCardRow<Trailing: View>` (replaces the row layout currently rendered by `DSSettingsRow` when inside a card; the old `DSSettingsSection` + `DSSettingsRow` pair stays for now in case other surfaces consume it, but the Settings panes use the card pair).

**Approach:** `DSCard` renders a `VStack(spacing: 0)` with optional head row, a 1-pt `DS.Color.borderSubtle` overlay at radius `DS.Radius.lg` (10 pt), background `DS.Color.bgSurface`. `DSCardRow` renders a 14×18 padded grid `1fr auto` with a top-border between siblings (handled by the parent card via `.overlay(borderSubtle, alignment: .top)` keyed off index ≥ 1, or via a `_DSCardDivider` interleaved by a `ForEach` in the card).

**Patterns to follow:** existing `DSSettingsSection` / `DSSettingsRow` for the same row contract — title + subtitle + trailing slot.

**Test scenarios:** none — visual primitive verified by usage in U6–U10.

---

### U3. `SettingsCategory` enum + `SettingsSidebar`

**Goal:** 5-button secondary nav. Selecting a category mutates an `@State var selectedCategory` in `SettingsTabView`.

**Files:**
- `NoType/UI/Settings/SettingsCategory.swift` — `enum SettingsCategory: String, CaseIterable, Identifiable { case general, recording, languagePaste, apiUsage, about }` with `label`, `icon` (DSIconName), and `crumb` ("Settings / General" etc.).
- `NoType/UI/Settings/SettingsSidebar.swift` — `View` with header label "Settings" + 5 buttons; matches the design's nav-item shape (30 pt height, 6 pt radius, 10 pt icon-text gap, hover/active background = `DS.Color.bgHover` / `DS.Color.bgActive`).

**Approach:** `SettingsSidebar` is a thin `VStack` of `Button { selection.wrappedValue = category } label: { … }` — each button styled as `.plain` with custom hover state via `.onHover { … }` and a `@State` flag. Active state is keyed off `selection == category`.

**Patterns to follow:** existing `MainWindowView.sidebarNav` button shape in `MainWindow.swift`.

**Test scenarios:** none — pure UI; pane switching covered by U11's smoke check.

---

### U4. `SettingsContentHeader` (sticky title + crumb pill)

**Goal:** The 56-pt-tall sticky head with `<h1>` and the mono breadcrumb pill, matching the design's `.content-head`.

**Files:**
- `NoType/UI/Settings/SettingsContentHeader.swift` — accepts `title: String, crumb: String`; renders `HStack` with title (`DS.Font.title` 18 pt semibold, tight tracking) + `DSBreadcrumbPill` (3×7 pt padded, 4 pt radius, mono 11 pt). Background uses `DS.Color.bgBase` with a 12-pt-blur material at 88 % opacity to mimic the `.content-head` backdrop-filter.

**Approach:** SwiftUI doesn't expose a true CSS `backdrop-filter`, but stacking `Rectangle().fill(DS.Color.bgBase.opacity(0.88))` over a `.background(.ultraThinMaterial)` produces a near-identical effect. The `ScrollView` below uses a `safeAreaInset(edge: .top)` so the header overlays the scrolled content rather than scrolling with it — matches the design's sticky behaviour.

**Test scenarios:** none — visual.

---

### U5. `SettingsTabView` shell — wire SettingsSidebar + Header + pane switch

**Goal:** Compose U3 + U4 + the 5 pane views into the Settings root. Replace the current `ScrollView` + 6-section body.

**Files:**
- `NoType/UI/Settings/SettingsTabView.swift` — rewritten to:
  ```text
  HStack(spacing: 0) {
    SettingsSidebar(selection: $selectedCategory)
    VStack(spacing: 0) {
      SettingsContentHeader(title: ..., crumb: ...)
      ScrollView { selectedPane }
    }
  }
  ```
  Pull confirmation-dialog state, sheet state, etc. that's shared across panes into this root so each pane stays a pure value (e.g., `Reset onboarding` dialog state lives in `SettingsTabView`, the pane just calls `onReset?()`).

**Dependencies:** U2, U3, U4, U6, U7, U8, U9, U10.

**Test scenarios:** none in unit tests (pure orchestration). Manual smoke: tab between all 5 categories without crash; first pane (General) is the default selection on tab open.

---

### U6. `GeneralPane` — Appearance + Startup & sessions + Onboarding

**Goal:** Three cards matching the design.

**Files:**
- `NoType/UI/Settings/Panes/GeneralPane.swift` — new.

**Approach:**

| Card | Rows |
|---|---|
| Appearance | Theme picker (Adaptive / Light / Dark) — keep existing `Picker(.segmented)` for now; the design's `.seg` look matches segmented style closely enough. |
| Startup & sessions | "Open NoType at login" toggle (+ requires-approval link); "Prevent sleep while recording" toggle. |
| Onboarding | "Reset onboarding" row with Reset button — fires a dialog via the parent. |

Reuse existing service bindings (`AppearanceController.mode`, `appState.loginItemController`, `appState.preventSleepDuringRecording`, `onboarding.resetWizard()`).

**Patterns to follow:** current `generalSectionBody` / `loginItemRow` logic in `SettingsTabView.swift` — port verbatim into row builders that produce `DSCardRow`s.

**Test scenarios:** none — pure composition over existing state. Manual smoke: toggle each control and verify the underlying value (UserDefaults / service) updates.

---

### U7. `RecordingPane` — Shortcuts + How-it-works callout + Input device

**Goal:** Three cards. Largest pane.

**Files:**
- `NoType/UI/Settings/Panes/RecordingPane.swift` — new.
- `NoType/UI/Settings/Components/HowRecordingWorksCallout.swift` — new (replaces the current `shortcutsExplanation` bullet block with a `display: grid` 1fr-auto layout that aligns keycaps on the right).
- `NoType/UI/Settings/Components/MicSourcePill.swift` — new (mic source pill with green dot + "Auto-detect · MacBook Pro Microphone").

**Approach:**

| Card | Rows |
|---|---|
| Shortcuts (meta: "Disabled while recording") | Recording shortcut row (keycap pill + Change button); Cancel shortcut row. Both disabled when `recordingState != .idle`. |
| How recording works | 4-row grid callout: Hold to record (⌥), Double-tap to lock (⌥ ×2), Hold + Space to lock (⌥ + space), Cancel (esc). |
| Input device | Mic row — label "Microphone" + `MicSourcePill` showing device + auto-detect dot + hint; Change button on the right. Music interruption row — segmented (None / Mute / Pause). |

Reuse existing services: `appState.hotkeyBinding`, `appState.cancelHotkeyBinding`, `MicChangeRow` logic (extract the source-pill bit), `appState.musicInterruptionMode`.

**Patterns to follow:** existing `recordingShortcutRow` / `cancelShortcutRow` / `audioSectionBody` / `MicChangeRow`.

**Test scenarios:** none — covered by manual smoke (rebind shortcut, change mic, switch music-interruption mode).

---

### U8. `LanguagePastePane` — Output languages + Transcripts history

**Goal:** Two cards.

**Files:**
- `NoType/UI/Settings/Panes/LanguagePastePane.swift` — new.
- (optional) `NoType/UI/Settings/Components/LanguageChip.swift` — extract the chip rendering from `OutputLanguagePicker` only if needed for re-style.

**Approach:**

| Card | Rows |
|---|---|
| Output languages (meta: "Sent to Gemini") | Single `.col`-layout row: title + hint above, chips wrap below. Chip = flag emoji + language name + remove (×). "Add language" chip opens the existing picker menu from `OutputLanguagePicker`. |
| Transcripts history (meta: "Last 10 sessions") | "Delete all transcripts" row + destructive button (red border, red text, trash icon). Hint copy explicitly notes that usage stats are kept. |

Reuse existing `OutputLanguagePicker` logic and `appState.deleteAllHistory()`.

**Test scenarios:** none — covered by smoke (add/remove a language, click Delete all → confirm dialog).

---

### U9. `APIUsagePane` — Gemini API + Token usage

**Goal:** Two cards. Re-style `GeminiKeyRow` + `TokenStatsPanel` to fit the card chrome.

**Files:**
- `NoType/UI/Settings/Panes/APIUsagePane.swift` — new.
- `NoType/UI/Settings/GeminiKeyRow.swift` — minor edits: trim its own outer chrome so it composes as a `DSCardRow` body; ship the lock-glyph + `AIzaSy••••••••` masked display + Edit button as today.
- `NoType/UI/Settings/TokenStatsPanel.swift` — minor edits: remove its own outer padding/title (the card head now owns the title); body remains the 3-cell HStack. Card head meta shows the selected range scope label (e.g., "Last 30 days").

**Approach:**

| Card | Rows |
|---|---|
| Gemini API (meta: "Stored in macOS Keychain") | API key row — masked field + lock icon on the left + Edit button on the right. Hint copy includes a link to Google AI Studio. |
| Token usage (meta: scope label from picker) | Range picker (Today / 7d / 30d / All) → 3-cell HStack (Input / Output / Cost). No deltas, no cache-hits in v1. |

**Test scenarios:**
- `NoTypeTests/TokenStatsPanelTests.swift` (existing) — verify `formatCount` still pinned after the re-style.

---

### U10. `AboutPane` — Version block + Permissions chips + GitHub row

**Goal:** Single card with three internal sections separated by hairlines.

**Files:**
- `NoType/UI/Settings/Panes/AboutPane.swift` — new.
- `NoType/UI/Settings/Components/VersionBlock.swift` — new (36 pt brand mark + "NoType X.Y.Z" + "Checks automatically every 24 hours" + primary `Check for updates` button).
- `NoType/UI/Settings/Components/PermissionChip.swift` — new (28 pt icon square + permission name + state pill with mono uppercase status: `GRANTED` / `DENIED` / `OPTIONAL`).
- `NoType/UI/Settings/Components/GitHubRow.swift` — new (GitHub mark glyph + "View source on GitHub" + `github.com/weylandd/NoType · MIT License` mono URL + external-link chevron).

**Approach:**

| Block | Rendered as |
|---|---|
| Version | `VersionBlock` — uses `UpdateController.checkForUpdates()` for the button. |
| Permissions chips | 3-column grid — `PermissionChip` × 3. Reads `PermissionsViewModel.microphone` / `.accessibility` / `.screenRecording`. Click → `MicrophonePermission.openSystemSettings()` etc. (per `Permissions/CLAUDE.md` invariant 4, Screen Recording is `optional`-state styled in neutral tertiary, never red). |
| GitHub | `GitHubRow` — opens `https://github.com/weylandd/NoType` in the default browser via `NSWorkspace.shared.open(_:)`. |

**Patterns to follow:** existing `updatesRow` in `SettingsTabView.swift` for the Check for Updates path; existing permission state reads in `OnboardingPermissionsStep` (mirror the same enum mapping).

**Test scenarios:** none — three-way perm-state mapping is verified by manual smoke against a TCC-toggled state. The `PermissionsViewModel` itself is tested elsewhere (`AccessibilityPermissionTests`).

---

### U11. CLAUDE.md + UI module doc updates

**Goal:** Reflect the new Settings shell in `NoType/UI/CLAUDE.md` and the cross-cutting `CLAUDE.md` references.

**Files:**
- `NoType/UI/CLAUDE.md` — update the `Settings/SettingsTabView.swift` bullet under "Surfaces" (now shell + 5 panes); add a new bullet for the secondary nav; bump the 6-section list to the new 5-section list.
- `CLAUDE.md` — verify no stale "scrolled-with-headers" reference; the @docs map references stay correct.

**Test scenarios:** none — doc-only.

---

### U12. TECHDEBT entry — deltas + cache-hits for Token usage

**Goal:** Document the deferred work so we don't lose it.

**Files:**
- `docs/solutions/documentation-gaps/token-usage-deltas-and-cache-hits-2026-05-18.md` — new (knowledge-track shape).
- `docs/TECHDEBT.md` — add the index entry.

---

## Key Technical Decisions

1. **Widen window to 1180×820 (not narrow the sidebars).** Per Phase 0.7-style synthesis: the design depends on the 220+200+content split; a narrower compromise produces a cramped layout and violates the design's grid budget. The user explicitly approved the widening.
2. **Re-use `Picker(.segmented)` for theme / music-interruption / token-range pickers.** AppKit's segmented control reads visually close enough to the design's `.seg` chip; building a custom `DSSegmentedPicker` is a Tier-2 nice-to-have, not load-bearing for the redesign.
3. **No new view-models.** Every pane consumes existing `@Environment(_:)` services (`AppState`, `AppearanceController`, `PermissionsViewModel`, `UpdateController`, `OnboardingState`). Per `UI/CLAUDE.md` hard rule "Don't introduce new ObservableObject / @Published view-models".
4. **Deltas + cache-hits deferred.** The design shows them as part of the panel; v1 omits them. The `StatsStore` schema would need a prior-period rollup and the Gemini client a cached-token counter — both real engineering, and the visual gap (single sub-caption line missing under each cell) is acceptable.
5. **Keep the existing `DSSettingsSection` / `DSSettingsRow` primitives.** Other surfaces may consume them — and the cost of removal is zero today. The Settings panes simply use `DSCard` / `DSCardRow` instead.

---

## Risks

| Risk | Mitigation |
|---|---|
| Widening the window breaks the Home tab's heatmap / top-apps layout. | Smoke-check Home tab after U1. If it breaks, gate the wider canvas to the Settings tab only via a per-tab frame; unlikely (Home is `frame(maxWidth: .infinity)` everywhere). |
| Sticky header `.safeAreaInset` interferes with `ScrollView` content-inset on macOS 15. | Fallback: pin the header as a `VStack` sibling and let the ScrollView render below it — abandons the "scroll under blurred header" look but keeps everything visible. |
| Permission chips in About duplicate the onboarding wizard's grant flow and double-prompt the user. | About chips never call `request()`; they only `openSystemSettings()`. The wizard remains the only TCC-prompt entry point. |
| `OutputLanguagePicker` chip styling drifts away from the design's accent-soft chip. | Stay close — accent-soft fill + accent-fg text + accent-border outline. If the existing component is too far gone, extract `LanguageChip` for clean re-style; otherwise edit in-place. |

---

## Verification

After all units land:
- App launches at 1180×820. Settings tab opens with General pane selected, sticky header reads "General · Settings / General".
- Click each of the 5 categories — content swaps without jank, header title + crumb update.
- Every existing setting (theme, login, sleep, shortcuts, mic, music, languages, delete history, API key, token usage, check for updates) is reachable and operates as before.
- New surfaces:
  - About perm chips reflect TCC state and route to System Settings on click.
  - GitHub row opens `https://github.com/weylandd/NoType` in the browser.
  - Version block "Check for updates" runs the existing Sparkle path.
- `xcodebuild build` is clean.

---

## Out of scope (explicitly)

- Light theme polish (see `UI/CLAUDE.md` "Known gaps").
- Account row in primary sidebar (no accounts in NoType).
- Update banner inside the Settings sub-nav (foot stays on the primary sidebar).
- Slash-/-modifier shortcut for nav jumps (G / R / L / A / B).
