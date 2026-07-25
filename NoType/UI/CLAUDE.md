# UI module

SwiftUI surfaces: menu-bar icon, history popover, the main app window (Home tab + first-run onboarding wizard), four floating HUDs (recording / transcribing / error / permissions), and the Settings sheet. All visual values reference `DesignTokens.swift`.

## Files

**Design system primitives:**

- `DesignTokens.swift` — `enum DS` namespace: `.Color`, `.Space`, `.Radius`, `.Size`, `.Font`, `.Motion`. Source of truth for all visual values. Mirrors `tokens.css` of the design bundle.
- `DSComponents.swift` — shared building blocks (`DSSeparator`, `DSIconButton`, `DSBadge`, `DSKbd`, `DSCloseButton`, `DSGlyphChip`, `DSPrimaryButton`, `DSSecondaryButton`, `DSDestructiveButton`, `DSLinkButton`, `DSStatusPill`, `DSWordChip`, `DSCard`, `DSCardRow`, `DSSettingsSection`, `DSSettingsRow`) + `dsHudChrome()` modifier.
- `DSIcon.swift` — typed enum `DSIconName` wrapping the line-icon assets in `Assets.xcassets`.

**Surfaces:**

- `MenuBarIcon.swift` — `MenuBarExtra` label (idle / recording / sending states).
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
- `Settings/SettingsTabView.swift` — Settings tab in main window. Two-column shell: a 200 pt secondary sidebar (`SettingsSidebar`) drives a 5-pane switch (General / Recording / Language & Paste / API & Usage / About) inside a `ScrollView` with a sticky `SettingsContentHeader` (title + breadcrumb pill). Each pane composes one or more `DSCard`s. Opened via the popover header gear or sidebar nav. Replaces the older single-column scrolled-with-headers shell from plan 2026-05-18-001 (see plan 2026-05-18-003 for the redesign rationale + window-width pivot to 1180×820).
- `Settings/SettingsCategory.swift` — enum + label/crumb/icon for the 5 secondary panes.
- `Settings/SettingsSidebar.swift` — secondary nav rail (`bgBase` recess + hairline-trailing border).
- `Settings/SettingsContentHeader.swift` — sticky title + mono breadcrumb pill over an `.ultraThinMaterial` backdrop.
- `Settings/Panes/{General,Recording,LanguagePaste,APIUsage,About}Pane.swift` — pane bodies; each composes `DSCard` + `DSCardRow` from `DSComponents.swift` (the new card primitive family — `DSSettingsSection` / `DSSettingsRow` stays in DSComponents for any future consumer but the Settings panes no longer use it).
- `Settings/Components/{VersionBlock,PermissionChip,GitHubRow,MicSourcePill,HowRecordingWorksCallout}.swift` — leaf chips and blocks the panes consume.

## Invariants

1. **Errors surface only via `HUDController.showErrorHUD(...)`** — translated from the `internal NoTypeErrorKind` table in `AppState.surfaceError`. Adding a new error mode = extend the enum + add a `payload` case + call `surfaceError(.foo)` at the failure site. Visibility is `internal` so `MissingKeyHUDRetryTests` can pin the catalog's regression guard ("every `payload.retryLabel != nil` kind must ship a non-`nil` `retryHandler`") via `@testable import NoType`.
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
- **All `.onHover` callsites go through `dsOnHover` (in `DSComponents.swift`).** Raw `.onHover { hovered = $0 }` written inside a `@MainActor` View body inherits `@MainActor` per SE-0420; on macOS 26.2 the closure's prologue executor check faults at `swift_getObjectType` because the SerialExecutorRef SwiftUI hands the concurrency runtime via `HoverResponder.updatePhase(_:)` carries an invalid identity — see `solutions/runtime-errors/onhover-mainactor-inheritance-crash-2026-05-19.md`. `dsOnHover` strips the inherited isolation via `@Sendable` and then hops back with `Task { @MainActor in … }` for the `@State` write — an async hop costing ~one frame. **`MainActor.assumeIsolated` was considered and rejected as that bridge** (it calls into the same `_taskIsCurrentExecutor` family as the crash and traps unconditionally if SwiftUI ever dispatches `.onHover` off-main); don't "simplify" the helper back into it. The only legal raw `.onHover` in the project is `dsOnHover`'s own definition.

## Launch ordering

**No type constructed by `NoTypeApp.init()` may schedule `MainActor` work or touch `NSApp` during construction.** That code runs before `NSApplicationMain` has started the application; scheduling into that window is a latent ordering bug and the leading hypothesis for the macOS-26.2 executor-identity crash family (issue #82).

- Launch work lives in `AppState.prime()`, `PermissionsViewModel.prime()`, and `AppearanceController.apply()`.
- All three are driven by `NoTypeAppDelegate.launchHandler`, assigned in `NoTypeApp.init()` (assigning a closure schedules nothing) and invoked from `applicationDidFinishLaunching(_:)`. Appearance is applied **before** priming so the theme is on `NSApp` ahead of any UI priming can surface.
- **Don't move this to a scene's `.task`.** NoType is `LSUIElement` and the main window isn't presented at launch once onboarding is complete, so a returning user would never fire it. `wireTerminationHandler()` is the counter-example, not the precedent.
- `AppState.prime()` calls `permissions.prime()` and then `applyAccessibilityState()` **synchronously, in that order**. `observePermissions()` only reacts to changes *after* its entry snapshot, so an already-`.granted` state would otherwise never install the hotkey tap.
- `applicationDidFinishLaunching(_:)` deliberately does **not** use `MainActor.assumeIsolated` (unlike `applicationWillTerminate(_:)`): it calls into the same `swift_task_isCurrentExecutor` family that faults in this crash family.

Pinned by `NoTypeTests/LaunchOrderingTests.swift` (source scan over every type reachable by construction from `NoTypeApp.init()`, following same-file calls transitively) and `NoTypeTests/LaunchPrimingTests.swift` (behaviour).

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
- Why the two hard rules above exist, and why per-call-site annotation is mitigation rather than a cure → `solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`. The `TimelineView` and `.onHover` crashes are two of three same-signature incidents on macOS 26.2; the third is a stock SwiftUI `Button` (issue #82), which is why the README carries a known-issue note.
- Why deployment target = macOS 15 → `solutions/tooling-decisions/macos-15-deployment-target-2026-05-15.md`.
- Sparkle 2 update banner (sidebar pill, not a HUD) → `solutions/tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md` + `NoType/Updates/CLAUDE.md`.
- History list source / lifetime stats → `NoType/History/CLAUDE.md`.
