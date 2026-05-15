# UI module

SwiftUI surfaces: menu-bar icon, history popover, the main app window (Home tab + first-run onboarding wizard), four floating HUDs (recording, transcribing, error, permissions), and Settings sheet. All visual values reference `DesignTokens.swift`, the Swift port of the dark-theme tokens in `aura/project/shared/tokens.css` from the design handoff bundle.

Files:

**Design system primitives:**
- `DesignTokens.swift` — `enum DS` namespace: `.Color`, `.Space`, `.Radius`, `.Size`, `.Font`, `.Motion`. Source of truth for all visual values. Mirrors `tokens.css` of the design bundle.
- `DSComponents.swift` — shared building blocks: `DSSeparator`, `DSIconButton`, `DSBadge`, `DSKbd`, `DSCloseButton`, `DSGlyphChip`, `DSPrimaryButton`, `DSSecondaryButton`, `DSLinkButton`, `DSStatusPill`, plus the `dsHudChrome()` modifier (border + 1 pt top highlight + spring pop-in). Anything that appears in ≥2 surfaces should live here.
- `DSIcon.swift` — typed enum (`DSIconName`) wrapping the line-icon assets in `Assets.xcassets`.

**Surfaces:**
- `MenuBarIcon.swift` — label for `MenuBarExtra`. Idle/recording/sending/error states; recording state shows the `tray-aura` pill (accent capsule + mic + mm:ss timer + pulsing dot). The tray is suppressed entirely during onboarding via `NoTypeApp.body`'s `MenuBarExtra(isInserted:)` gate, so this view doesn't render until the wizard completes — first-launch window opening is handled separately by `Scene.defaultLaunchBehavior(.presented)` on the main `Window` scene (macOS 15+).
- `HistoryPopover.swift` — popover content + footer mic-input picker + `[Open NoType]` button that opens the main window.
- `MicInputPicker.swift` — shared input-device dropdown (the 30 pt pill that opens an `NSMenu`). Used by the popover footer and the onboarding mic-check screen.
- `HistoryRowView.swift` — single history entry. Real macOS app icon via `AppIconCache` (delegated to `AppIconView`).
- `AppIconView.swift` — shared rounded-tile that renders the real macOS app icon for a bundle ID with a violet letter-tile fallback. Used by `HistoryRowView` and `HomeView`'s top-apps panel.
- `AppIconCache.swift` — memoizes `NSWorkspace.icon(forFile:)` lookups by bundle ID.
- `MainWindow.swift` — `Window` scene contents. While `OnboardingState.isOnboarding == true` it shows `OnboardingFlow` full-bleed (no sidebar, no tabs). Once the wizard is complete it shows the regular layout: 220 pt sidebar (brand mark + nav) + main pane that swaps in the selected `MainTab`. Toggles `NSApp.setActivationPolicy` between `.regular` (open) and `.accessory` (closed) so NoType only appears in the Dock while the window is up. Currently the only tab is `.home`; add new cases to `MainTab` to extend.
- `HomeView.swift` — Home tab. Sticky header (title + scope chip + 7D/30D/90D/All `DSRangeTabs`) + scroll body containing: stats row (`HomeStats`: total words, time saved, computed WPM), top-apps panel (top 5 by words pasted), monthly activity heatmap (`CalendarGridLayout` — bespoke 49-subview Layout, sized to `maxCellSize: 32`), and a recent-transcripts list that reuses `HistoryRowView`. The first three surfaces read from `appState.statsSummary` (lifetime aggregate, see `NoType/History/CLAUDE.md` "Lifetime stats") windowed by the selected `HomeRange`; only the recent-transcripts list pulls from `appState.history` (rolling last 10). Row 2 (apps + calendar) uses an `HStack` where apps fill `.frame(maxWidth: .infinity)` and the calendar Panel is pinned to `HomeActivityCalendar.naturalWidth` (= 7 × maxCellSize + 6 × spacing + 2 × panel padding) so its container hugs the grid instead of stretching with empty space.
- `RecordingHUD.swift` — 300 pt HUD shown while the hotkey is held; live FFT spectrum meter with peak-hold markers (see `AudioSpectrum.swift`).
- `TranscribingHUD.swift` — 220 pt compact HUD that replaces the recording HUD between hotkey release and final paste; spinning ring + "Transcribing…" label + indeterminate progress bar.
- `ErrorHUD.swift` — 320 pt failure surface (network, API quota, paste blocked, missing key, etc.) with title / description / mono error code, dismiss + optional retry/secondary action. Drives the user-facing error pipeline; nothing else surfaces errors visually.
- `PermissionsHUD.swift` — per-permission cards stacked top-right at launch.
- `HUDController.swift` — owns and positions every floating panel.
- `HUDPanel.swift` — `NSPanel` subclass with embedded `NSVisualEffectView` blur (see "HUD glass" below).
- `AudioSpectrum.swift` — vDSP-backed FFT for the recording-HUD meter.
- `SettingsView.swift` — opened from the popover header gear. Currently API key entry only.

---

## Design tokens

`DesignTokens.swift` is the Swift port of the dark-theme tokens in `aura/project/shared/tokens.css`. We do not ship the light theme.

When the design system says `var(--space-3)`, the Swift equivalent is `DS.Space.s3`. The mapping is:

| CSS                                                              | Swift                                                         |
|---|---|
| `--bg-canvas` / `--bg-overlay` / etc.                            | `DS.Color.bgCanvas` / `DS.Color.bgOverlay` / etc.             |
| `--text-primary` / `--text-secondary` / etc.                     | `DS.Color.textPrimary` / `DS.Color.textSecondary` / etc.      |
| `--accent-base`, `--accent-fg`, `--accent-soft`, `--accent-border` | `DS.Color.accent`, `.accentFg`, `.accentSoft`, `.accentBorder` |
| `--space-N`                                                      | `DS.Space.sN`                                                 |
| `--radius-{xs,sm,md,lg,xl,pill}`                                 | `DS.Radius.{xs,sm,md,lg,xl,pill}`                             |
| `--h-{xs,sm,md,lg,xl}`                                           | `DS.Size.h{XS,SM,MD,LG,XL}`                                   |

The accent base (NoType violet `#7C5CFF` — historically called "Aura violet" in the design bundle) is also exposed as an `AccentColor` asset in `Assets.xcassets`, so `Color.accentColor` resolves to the violet anywhere SwiftUI auto-tints (notably `MenuBarExtra`'s `.menuBarExtraStyle(.window)` chrome).

When the spec uses opacity-stacked variants (`accent-soft`, `danger-soft`, etc.), use the named DS token — never inline an `.opacity(0.16)` magic number. If a token is missing for a soft/border variant you need, add it to `DesignTokens.swift` rather than hardcoding the alpha at the call site.

---

## Reusable components — when to extract

Hard rule: if a button/chip/pill appears in two surfaces with the same spec, it lives in `DSComponents.swift`. Inlining once is fine; the second time, refactor.

Current shared inventory: `DSSeparator`, `DSIconButton`, `DSBadge`, `DSKbd`. (More to come — see "Known gaps" below.)

---

## HUD lifecycle

Three primary HUDs share the `HUDPanel` glass shell and live in the same top-right slot. Only one of {recording, transcribing} is visible at a time; permission cards stack underneath; the error HUD shows alone.

| HUD             | Width        | Trigger                                            | Hides on                              |
|---|---|---|---|
| Recording       | 300 pt       | Hotkey press                                       | Hotkey release                        |
| Transcribing    | 220 pt       | Hotkey release                                     | Paste success / cancel / error        |
| Error           | 320 pt       | Any user-actionable failure                        | Dismiss / retry / 8 s auto            |
| Permission card | 300 pt each  | Launch / menu-bar click / hotkey w/ missing mic    | Granted / user X                      |

`AppState` owns the state machine. Errors are translated into `ErrorPayload` via the private `NoTypeErrorKind` table — the **only** UI path for surfacing failures. Adding a new error mode means: extend `NoTypeErrorKind`, add a `payload` case, and call `surfaceError(.foo)` at the failure site.

### HUD glass

Each `HUDPanel` is an `NSPanel` whose `contentView` is an `NSVisualEffectView` configured `.menu` material, `.behindWindow` blending, `.active`. The SwiftUI hosting view is layered on top with a clear background. macOS draws the soft system shadow around the rounded `contentView`. Embedding the blur inside SwiftUI's `.background(...)` silently fails to pick up `behindWindow` blur context — see the comment at the top of `HUDPanel.swift`.

---

## Onboarding wizard

The first-run wizard lives in `NoType/Onboarding/` (separate folder from this module so the step files don't drown out the regular UI). Five screens — Welcome → API key → Permissions → Mic check → Hotkey check — each rendered through `OnboardingChrome` (back button + step-pip indicator + body slot + footer slot for the per-step CTA).

Contract:

- **`OnboardingState`** is the single source of truth. Persisted to `UserDefaults` (`notype.onboarding.{currentStep,furthestStep,complete}`). `isOnboarding == !isComplete`.
- **`MainWindowView`** swaps in `OnboardingFlow` while `isOnboarding`, otherwise the normal sidebar + `HomeView`.
- **Permission HUDs are suppressed during onboarding.** `AppState`'s launch auto-show and `handleMenuBarOpened` both gate on `onboarding.isComplete`. The wizard's permissions step drives its own prompts via `PermissionsViewModel.requestMicrophone()` / `requestAccessibility()`.
- **Hotkey-test isolation.** The hotkey-check step sets `appState.onboardingHotkeyPressObserver` (and the release sibling) on appear. While set, `handleHotkeyPress` short-circuits before starting a `RecordingSession` — the press flips the keycap visual instead. Cleared on disappear.
- **Auto-open on first launch.** Handled by `Scene.defaultLaunchBehavior(_:)` (macOS 15+, see ADR-001 for why this drives the floor) applied to the main `Window` scene in `NoTypeApp.body`. Reads `OnboardingState.hasCompletedOnboarding` once at scene-graph build: `.presented` while pending, `.automatic` once complete. On a fresh install SwiftUI eagerly creates and shows the `Window`, and `MainWindowView`'s `onAppear` raises the Dock icon via `NSApp.setActivationPolicy(.regular)`. Post-onboarding launches stay menu-bar-only (no window auto-opens) — matches the utility-app contract.
- **API key resume state.** Step 1.1 reads `appState.currentAPIKey`; if a key already exists it shows `AIzaSy••••••••` with an Edit link. Editing clears the field. Continue revalidates on edit, otherwise advances directly. The validated key is persisted to `SecretStore` immediately, before the user advances.
- **Mic check.** Uses `MicProbe` (`NoType/Onboarding/MicProbe.swift`) — its own `AVAudioEngine` instance, no VAD, no `RecordingSession`. The recording HUD's spectrum renderer is duplicated as a step-local `OnboardingSpectrumMeter` because it's sized differently (360 × 80 vs the HUD's 36 pt strip).

## Footer mic input picker

The popover's footer pill is a SwiftUI `Button` that opens a native `NSMenu` (not SwiftUI's `Menu` — `Menu` brings styling chrome that breaks the pill). It's driven by `AudioDeviceManager.shared`, lists every audio input on the system, and persists the user's choice (UID) in `UserDefaults` under `notype.selectedInputDeviceUID`. `nil` means "follow system default". `AudioRecorder.start()` reads this and applies it via Core Audio HAL before the engine starts. Device list updates automatically on hotplug.

Visually: 30 pt tall, `bg-inset` fill (recessed input pill, per the design's `.mic-select`), 7 pt radius, accent mic glyph + truncated label + chevron.

---

## Popover layout

Opens on left-click of the menu-bar icon. Width 380 pt, height grows with content (intrinsic, capped at 560 pt per spec).

```
┌────────────────────────────────────────────┐
│ NoType Recent · 10       Hold ⌥ Right Opt  │  ← header (no inline banner)
├────────────────────────────────────────────┤
│ [icon] Linear           Just now      ⎘ ⌫  │  ← newest row, accent stripe
│        "Let's bump the priority…"          │
│        (3 lines, tap to expand)            │
│ ─────────────────────────────────────────  │
│ [icon] Slack — #design-crit · 14m ago      │
│        "Quick thought on the popover…"     │
│ ─────────────────────────────────────────  │
│ …                                          │
├────────────────────────────────────────────┤
│ [🎙 MacBook Pro Mic ▾]                 [✕] │  ← footer
└────────────────────────────────────────────┘
```

Empty state (no entries yet): centered waveform glyph + "No recordings yet." + "Hold Right Option anywhere to start."

The "Microphone access needed" inline banner that older revisions had is **gone** — missing permissions surface as the standalone `PermissionCard` HUDs in the top-right, never inline.

---

## HistoryRowView

- Source app icon: real macOS app icon resolved by bundle ID via `AppIconCache`. Falls back to a violet letter-tile when the app can't be located (typically: uninstalled since the entry was recorded). 28 × 28, 7 pt radius, hairline border.
- Timestamp: relative ("just now", "Xm ago", "Xh ago", "Xd ago") via `TimestampDisplay` on a 15 s `TimelineView`. The newest row gets an accent `Just now` badge that ages out into the regular dot+time after 60 s.
- Text: 3-line preview with `Text(...).lineLimit(3)`. Tap the row to expand (`lineLimit(nil)`).
- Copy button (`DSIconButton(icon: .copy)`): writes to `NSPasteboard.general`, swaps to `.check` for 1.5 s.
- Delete button (`DSIconButton(icon: .trash, isDestructive: true)`): calls the `onDelete` closure passed by `HistoryPopover`, routed to `AppState.deleteHistoryEntry(id:)`. Optimistically updates the in-memory list, then `await store.remove(id:)` persists.
- Newest row: 2 pt accent capsule on the left edge + soft-accent background tint.

Both action buttons are always laid out (so the row never shifts) but rendered at `opacity(0)` until hovered.

---

## Settings scope

The Settings sheet (opened from the popover header gear) currently contains only the **Gemini API key** field with a "Save" button and an external link to Google AI Studio.

Planned additions (not yet implemented — do not describe as present):
- Permissions section (status + grant/open buttons)
- Advanced (paste delay slider, VAD sensitivity)
- About (version, license, GitHub link)

When implementing, port the design system's input/button/checkbox patterns from `aura/project/shared/components.css` into `DSComponents.swift` first rather than reaching for `.textFieldStyle(.roundedBorder)` and friends.

---

## Iconography

Two icon sources, with a clear default rule:

- **`DSIcon`** (line icons in `Assets.xcassets`) — primary. The full ~60-glyph set from `aura/project/shared/icons.js` is shipped as template SVG assets (stroke 1.5, `currentColor`, vector-preserved). See the `DSIconName` enum for the full inventory.
- **`Image(systemName:)`** (SF Symbols) — secondary. Use **only** for system-only concepts without a DS counterpart, e.g. filled status glyphs (`mic.fill`, `key.fill`, `wifi.slash`, `exclamationmark.triangle.fill`), the menu-bar idle/recording mic states, or accessibility-specific glyphs (`figure.stand`).

When in doubt, check `DSIconName` first. If it's there, use it. Don't introduce a third icon source.

---

## Motion

Per the design system, the UI is intentionally animated — the HUD shell pops in with a spring, the recording mic pulses, the dot blinks, the FFT meter runs at 30 fps, the spinner rotates, the indeterminate bar slides. The earlier "no animations beyond SwiftUI defaults" rule was wrong and has been retired.

Durations and easings in use today (will be tokenised under `DS.Motion` — see Known gaps):

| Use                                 | Duration / easing                             |
|---|---|
| Hover/press background fade          | 80–140 ms ease-out                            |
| Color/border transitions             | 140 ms ease-out                               |
| Layout changes, expand/collapse      | 200 ms ease-out                               |
| HUD pop-in                           | 260 ms cubic-bezier(.34, 1.32, .64, 1) (spring) |
| Recording mic pulse ring             | 1.8 s ease-out, infinite                      |
| Blinking record dot                  | 0.6 s ease-in-out, infinite                   |
| FFT meter tick                       | 30 fps                                        |
| Transcribing spinner                 | 1.1 s linear, infinite                        |
| Animated ellipsis                    | 0.35 s per dot                                |
| Indeterminate progress bar           | 1.5 s ease-in-out, infinite                   |

If you add a new animated component, pull the duration/easing from `DS.Motion` (once it lands) rather than hard-coding numbers — that's how the system stays coherent as more surfaces ship.

---

## Accessibility

- All buttons have `accessibilityLabel`.
- The menu-bar icon's `accessibilityLabel` reflects state ("NoType: idle", "NoType: recording, 5 seconds").
- Popover supports keyboard navigation (Tab through entries; Return to copy focused entry's text).

---

## Known gaps (design review, 2026-05-10)

Tracked here so contributors don't accidentally re-introduce the original deviations:

- **Type tokens** — `DS.Font` is short of the spec's full scale (missing `fs-16/18/20/24/32/44/64`) and lacks paired line-heights. Add as needed.
- **Light theme** — not implemented; spec defines it. Acceptable for v1.
- **Average WPM is fixed** — `HomeStats.averageWPM` is hardcoded at 140 (the dictation reference). `HistoryEntry` doesn't store recording duration, so we can't compute true WPM yet. When duration lands on the schema, swap to a real average. Time saved on the same panel uses the same fixed dictation rate vs a 47 WPM typing reference.
- **Range tabs (7D / 30D / 90D / All) on Home** — design includes them above the stats; code omits because the store only retains the last 10 entries, so all ranges would yield the same numbers. Add when history capacity grows.

Resolved in the 2026-05-10 sweep (here for archaeology):

- ~~Grayscale tokens off by ~one shade~~ — recomputed via CSS Color 4 reference algorithm; near-black palette per spec.
- ~~Popover glass + height~~ — `.ultraThinMaterial`; `minHeight: 280, maxHeight: 560`; top-edge highlight.
- ~~Accent-stack opacity tokens missing~~ — `accentSoftSubtle`, `dangerSoft/Border`, `successFg/Soft/Border`, `warningBorder`, `infoFg/Soft/Border` all named tokens now.
- ~~Reusable components missing~~ — `DSCloseButton`, `DSGlyphChip`, `DSPrimaryButton`, `DSSecondaryButton`, `DSLinkButton`, `DSStatusPill` extracted; HUDs converted.
- ~~DS.Motion missing~~ — `instant/fast/base/slow/easeIn/easeInOut/spring` exposed; HUDs use `dsHudChrome()` which spring-pops via `DS.Motion.spring`.
- ~~HUD pop-in spring~~ — `dsHudChrome()` modifier wires up the 260 ms spring.
- ~~Transcribing spinner ghost ring~~ — full 25 %-opacity circle now sits under the rotating arc.
- ~~Two-key kbd in header~~ — `⌥` + `Right Option` as separate `DSKbd` chips.
- ~~Fresh-row tint too saturated~~ — uses `accentSoftSubtle` (8 %) so the accent stripe doesn't compete with a loud background.
- ~~`Color.accentColor` resolving to system blue in tray pill~~ — `AccentColor` asset added; `MenuBarIcon` uses `DS.Color.accent` directly.
- ~~Iconography mixed (custom DS for history-row, SF Symbols everywhere else)~~ — full ~60-glyph DS line-icon set ported as template SVGs; SF Symbols now only for system-only concepts.

---

## Testing

UI testing is light:
- No dedicated UI tests exist yet. There are no separate `HistoryViewModel` / `SettingsViewModel` types — history state lives directly on `AppState` (see `NoType/History/CLAUDE.md`); the Settings sheet is currently small enough not to warrant a view-model.
- Snapshot tests for `HistoryRowView` and the empty-state popover view are planned.
- Manual smoke test before each release.
