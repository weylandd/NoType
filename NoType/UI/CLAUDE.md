# UI module

SwiftUI surfaces: menu-bar icon, history popover, the main app window (Home tab + first-run onboarding wizard), four floating HUDs (recording / transcribing / error / permissions), and the Settings sheet. All visual values reference `DesignTokens.swift`.

## Files

**Design system primitives:**

- `DesignTokens.swift` — `enum DS` namespace: `.Color`, `.Space`, `.Radius`, `.Size`, `.Font`, `.Motion`. Source of truth for all visual values. Mirrors `tokens.css` of the design bundle.
- `DSComponents.swift` — shared building blocks (`DSSeparator`, `DSIconButton`, `DSBadge`, `DSKbd`, `DSCloseButton`, `DSGlyphChip`, `DSPrimaryButton`, `DSSecondaryButton`, `DSLinkButton`, `DSStatusPill`, `DSWordChip`) + `dsHudChrome()` modifier.
- `DSIcon.swift` — typed enum `DSIconName` wrapping the line-icon assets in `Assets.xcassets`.

**Surfaces:**

- `MenuBarIcon.swift` — `MenuBarExtra` label (idle / recording / sending / error states).
- `HistoryPopover.swift` — popover content + footer mic-input picker + "Open NoType" button.
- `MicInputPicker.swift` — shared input-device dropdown. Used by popover footer and onboarding mic-check.
- `HistoryRowView.swift` — single history entry (real macOS app icon via `AppIconCache`).
- `AppIconView.swift` / `AppIconCache.swift` — bundle-id → icon resolution + memoization.
- `MainWindow.swift` — `Window` scene; sidebar + main pane; tab switcher between Home / Instructions / Dictionary.
- `HomeView.swift` — Home tab; stats row + top-apps panel + activity heatmap + recent transcripts.
- `RecordingHUD.swift`, `TranscribingHUD.swift`, `ErrorHUD.swift`, `PermissionsHUD.swift` — the four floating panels.
- `HUDController.swift` — owns and positions every floating panel.
- `HUDPanel.swift` — `NSPanel` subclass with embedded `NSVisualEffectView` blur.
- `AudioSpectrum.swift` — vDSP-backed FFT for the recording-HUD meter.
- `SpectrumMeter.swift` — shared FFT spectrum meter view used by both the recording HUD (`RecordingHUD.swift`) and the onboarding mic-check step (`NoType/Onboarding/Steps/OnboardingMicCheckStep.swift`). Owns the `.task`-driven 30 fps frame loop + `@State` arrays; the two call sites only supply geometry (bar count, spacing, padding, corner radius, max height).
- `Settings/SettingsTabView.swift` — Settings tab in main window (scrolled-with-headers form, 5 sections). Opened via the popover header gear or sidebar nav. Replaces the old sheet-based `SettingsView` (removed in plan 2026-05-18-001).

## Invariants

1. **Errors surface only via `HUDController.showErrorHUD(...)`** — translated from the private `NoTypeErrorKind` table in `AppState.surfaceError`. Adding a new error mode = extend the enum + add a `payload` case + call `surfaceError(.foo)` at the failure site.
2. **`HUDPanel` is `NSPanel` with `NSVisualEffectView` `contentView`** (`material = .menu`, `blendingMode = .behindWindow`, `state = .active`). Embedding the blur inside SwiftUI's `.background(...)` silently fails to pick up `behindWindow` blur context — see comment at the top of `HUDPanel.swift`.
3. **`MenuBarExtra(isInserted: $onboarding.isComplete)`** — tray suppressed during onboarding.
4. **`Scene.defaultLaunchBehavior(_:)` drives first-launch presentation** — `.presented` while onboarding pending, `.automatic` once complete. macOS 15+ API; loss of this is the regression that drove ADR-001.
5. **Onboarding state persists** under `notype.onboarding.{currentStep,furthestStep,complete}` (`UserDefaults`). `isOnboarding == !isComplete`.
6. **Mic input choice persists** under `notype.selectedInputDeviceUID` (`UserDefaults`). `MicInputPicker` is the single picker — used by both popover footer and onboarding mic-check.

## Hard rules

- **All visual values via `DesignTokens`.** Never inline `.opacity(0.16)` or raw hex; if a token is missing for a soft/border variant, add it to `DesignTokens.swift` rather than hard-coding the alpha at the call site.
- **If a button / chip / pill appears in 2+ surfaces with the same spec, it lives in `DSComponents.swift`.** Inlining once is fine; the second time, refactor.
- **Don't introduce new `ObservableObject` / `@Published` view-models.** `@Observable` + `@Environment(_:)` is the pattern (see `solutions/conventions/module-architecture-and-naming-2026-05-15.md`).
- **Two icon sources only.** `DSIcon` (line icons in `Assets.xcassets`, ~60 glyphs) for primary use; `Image(systemName:)` only for system-only concepts (`mic.fill`, `key.fill`, `wifi.slash`, `figure.stand`, etc.). When in doubt, check `DSIconName` first.
- **All buttons have `accessibilityLabel`.** The menu-bar icon's label reflects state ("NoType: idle", "NoType: recording, 5 seconds").
- **`TimelineView` content closures may NOT call instance methods or read instance computed properties on the enclosing View.** On macOS 26 this crashes with `swift_task_isCurrentExecutorWithFlagsImpl` → `objc_opt_class` at a small faulting address — see `solutions/runtime-errors/timelineview-mainactor-instance-method-crash-2026-05-16.md`. Allowed inside the closure: `let` props on `self`, `Self.foo(...)` static helpers, `ctx.date`, SwiftUI view builders. For views with mutable state (spectrum meters, animated bars), use a `.task { while !Task.isCancelled { … assign @State … try? await Task.sleep(...) } }` driver instead of `TimelineView` — `@State` mutation triggers normal SwiftUI re-render without the TimelineView dispatch path.

## HUD slots & widths

| HUD | Width | Trigger | Hides on |
|---|---|---|---|
| Recording | 300 pt | Hotkey press | Hotkey release |
| Transcribing | 220 pt | Hotkey release | Paste success / cancel / error |
| Error | 320 pt | Any user-actionable failure | Dismiss / retry / 8 s auto |
| Permission card | 300 pt each | Launch / menu-bar click / hotkey w/ missing mic | Granted / user X |

Only one of {recording, transcribing} is visible at a time. Permission cards stack underneath. Error HUD shows alone.

## Onboarding wizard contract

Wizard lives in `NoType/Onboarding/` (separate folder so the step files don't drown out the regular UI). Five screens — Welcome → API key → Permissions → Mic check → Hotkey check.

- **Permission HUDs are suppressed during onboarding** — `AppState`'s launch auto-show and `handleMenuBarOpened` both gate on `onboarding.isComplete`. The wizard's permissions step drives its own prompts.
- **Hotkey-test isolation** — the hotkey-check step sets `appState.onboardingHotkeyPressObserver` (and release sibling) on `.appear`. While set, `handleHotkeyPress` short-circuits before starting a `RecordingSession`.
- **Mic check uses `MicProbe`** (`NoType/Onboarding/MicProbe.swift`) — its own `AVAudioEngine` instance, no VAD, no `RecordingSession`. Spectrum renderer duplicated as a step-local `OnboardingSpectrumMeter` (sized 360 × 80 vs the HUD's 36 pt strip).

## Motion

Animations are intentional. Pull duration / easing from `DS.Motion` (`instant` / `fast` / `base` / `slow` / `easeIn` / `easeInOut` / `spring`). HUDs use `dsHudChrome()` which spring-pops via `DS.Motion.spring` (260 ms cubic-bezier `(.34, 1.32, .64, 1)`).

## Known gaps

- `DS.Font` is short of the spec's full scale (missing `fs-16/18/20/24/32/44/64`) and lacks paired line-heights.
- Light theme not implemented; spec defines it. Acceptable for v1.

## Testing

- No dedicated UI tests today.
- Snapshot tests for `HistoryRowView` and the empty-state popover are planned.
- Manual smoke test before each release.

## Pointers

- Architecture overview (Mermaid, modules, integrations, threading) → `docs/architecture/overview.md`.
- Why deployment target = macOS 15 → `solutions/tooling-decisions/macos-15-deployment-target-2026-05-15.md`.
- Sparkle 2 update banner (sidebar pill, not a HUD) → `solutions/tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md` + `NoType/Updates/CLAUDE.md`.
- History list source / lifetime stats → `NoType/History/CLAUDE.md`.
