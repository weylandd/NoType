# UI module

SwiftUI surfaces: menu-bar icon, history popover, the main app window (Home tab + first-run onboarding wizard), four floating HUDs (recording / transcribing / error / permissions), and the Settings sheet. All visual values reference `DesignTokens.swift`.

## Files

**Design system primitives:**

- `DesignTokens.swift` — `enum DS` namespace: `.Color`, `.Space`, `.Radius`, `.Size`, `.Font`, `.Motion`. Source of truth for all visual values. Mirrors `tokens.css` of the design bundle.
- `DSComponents.swift` — shared building blocks (`DSSeparator`, `DSIconButton`, `DSBadge`, `DSKbd`, `DSCloseButton`, `DSGlyphChip`, `DSPrimaryButton`, `DSSecondaryButton`, `DSDestructiveButton`, `DSLinkButton`, `DSStatusPill`, `DSWordChip`, `DSCard`, `DSCardRow`, `DSSettingsSection`, `DSSettingsRow`) + `dsHudChrome()` modifier.
- `DSIcon.swift` — typed enum `DSIconName` wrapping the line-icon assets in `Assets.xcassets`.

**Surfaces:**

- `MenuBarIcon.swift` — `MenuBarExtra` label (idle / recording / sending states).
- `HistoryPopover.swift` — popover content + footer mic-input picker + "Open NoType" button. Threads `AppState.retryingEntryID` / `canRetry(entryID:)` / `retryEntry(id:)` into each row (see `HistoryRowView.swift`).
- `MicInputPicker.swift` — shared input-device dropdown. Used by popover footer and onboarding mic-check.
- `HistoryRowView.swift` — single history entry, in one of four states: **normal** (real macOS app icon via `AppIconCache`), **broken** (a session that lost chunks — error slot instead of the icon, actions always visible, `[…]` markers rendered where the failed chunks' text should be), **retrying** (spinner in the same slot, no retry and deliberately no cancel per KTD7 — delete always, plus copy while the row is showing text worth copying), and **dead** (broken with no retained audio — broken minus the retry action, which is what a broken row becomes after a relaunch). All three non-normal states occupy the same `iconSlotSize` box so the row never reflows.
- `AppIconView.swift` / `AppIconCache.swift` — bundle-id → icon resolution + memoization.
- `MainWindow.swift` — `Window` scene; sidebar + main pane; tab switcher between Home / Instructions / Dictionary.
- `HomeView.swift` — Home tab; stats row + top-apps panel + activity heatmap + recent transcripts. Its `HomeRecentList` renders the same `HistoryRowView` as the popover and passes the same retry state, so a retry started in either surface reads as in flight in both.
- `RecordingHUD.swift`, `TranscribingHUD.swift`, `ErrorHUD.swift`, `PermissionsHUD.swift` — the four floating panels.
- `HUDController.swift` — owns and positions every floating panel.
- `HUDPanel.swift` — `NSPanel` subclass with embedded `NSVisualEffectView` blur. Every AppKit geometry mutation goes through its `applyValidated(contentSize:)` / `applyValidated(frameOrigin:)` chokepoint.
- `HUDPanelGeometry.swift` — pure validation + top-right placement arithmetic for the above. No AppKit calls, no `NSWindow`; pinned by `HUDPanelGeometryTests`.
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
2. **`HUDPanel` is `NSPanel` with `NSVisualEffectView` `contentView`** (`material = .hudWindow`, `blendingMode = .behindWindow`, `state = .active`). Embedding the blur inside SwiftUI's `.background(...)` silently fails to pick up `behindWindow` blur context — see comment at the top of `HUDPanel.swift`. `.hudWindow` and not `.menu`: `.menu` reads too pale next to the popover (itself `.ultraThinMaterial`); `.hudWindow` is closer to the design's `bg-overlay` and to the recording HUD's darker-glass mood. Rationale is in `HUDPanel.init`.
3. **`MenuBarExtra(isInserted: $onboarding.isComplete)`** — tray suppressed during onboarding.
4. **`Scene.defaultLaunchBehavior(_:)` drives first-launch presentation** — `.presented` while onboarding pending, `.automatic` once complete. macOS 15+ API; loss of this is the regression that drove ADR-001.
5. **Onboarding state persists** under `notype.onboarding.{currentStep,furthestStep,complete}` (`UserDefaults`). `isOnboarding == !isComplete`.
6. **Mic input choice persists** under `notype.selectedInputDeviceUID` (`UserDefaults`). `MicInputPicker` is the single picker — used by both popover footer and onboarding mic-check.
7. **An Error HUD's *consequence* clause is decided by the call site, not by the error.** `.sessionFailure` carries `retainedForRetry:` — the outcome `AppState.recordBrokenRow` reported (`nil` return = no row), never `RecordingSession.shouldRetain(_:)` re-run on the error. The two differ: `shouldRetain` says an error is *eligible* for retention, but a session that retained no chunk still writes no row, and copy built from eligibility would promise a retry the user has no row for. `.partialTranscription` needs no companion flag — its summary already carries `retained`.

## Hard rules

- **All visual values via `DesignTokens`.** Never inline `.opacity(0.16)` or raw hex; if a token is missing for a soft/border variant, add it to `DesignTokens.swift` rather than hard-coding the alpha at the call site.
- **If a button / chip / pill appears in 2+ surfaces with the same spec, it lives in `DSComponents.swift`.** Inlining once is fine; the second time, refactor.
- **Don't introduce new `ObservableObject` / `@Published` view-models.** `@Observable` + `@Environment(_:)` is the pattern (see `solutions/conventions/module-architecture-and-naming-2026-05-15.md`).
- **Two icon sources only.** `DSIcon` (line icons in `Assets.xcassets`, ~60 glyphs) for primary use; `Image(systemName:)` only for system-only concepts (`mic.fill`, `key.fill`, `wifi.slash`, `figure.stand`, etc.). When in doubt, check `DSIconName` first.
- **All buttons have `accessibilityLabel`.** The menu-bar icon's label reflects state ("NoType: idle", "NoType: recording, 5 seconds").
- **A failure HUD names the cause; only the consequence clause varies with retention.** The broken history row deliberately does *not* name the failure reason (plan R7) precisely because the HUD carries it at the moment of failure — so offline / timed out / throttled / server error / region-blocked must stay five distinct sentences, and a change that collapses them into one generic string trades a false statement for a useless one. When the recording was retained, the description ends with `NoTypeErrorKind.retainedRecordingClause` (or `retainedGapClause` for a session that pasted with `[…]` gaps); when it wasn't, the pre-retention advice stands, because nothing was kept and there is no row to point at. **Terminal kinds — rejected key, content block, cancellation, encode failure, no-speech — are built without that helper and must stay that way**: they retain nothing, so their copy must never start advertising a retry that will not be there. Pinned in all three directions by `ErrorCopyRetentionTests`.
- **The history row's retry state is threaded down verbatim, never re-derived per surface.** Both the popover and `HomeRecentList` pass `AppState.retryingEntryID` (the `UUID?` itself, not a reduced `Bool`) plus `AppState.canRetry(entryID:)`; `HistoryRowView` derives *which* row is busy from that one value. Reducing either to a per-surface flag is how the two surfaces start disagreeing about an in-flight retry — `canRetry` folds retained-audio presence, the recording exclusion, and the one-run-at-a-time gate into an answer only `AppState` can give. **The row does add one term of its own**, and the line between the two is what the rule is actually about: `HistoryRowView.actions(...)` gates `.retry` on `RetryMerge.canAcceptRecovery(text)` as well — "is there a marker left for a recovery to land in", which a `TextReplacementEngine` pair on the `…` can rewrite away under a still-`isBroken` row. That predicate reads the row's own stored text, so it is identical in both surfaces by construction, and it lives in the shared row view where a test reaches it (`HistoryRowActionsTests`). So: facts only `AppState` can know are threaded down; predicates over the row's own fields belong in `actions(...)`. Deriving *either* kind at a call site is the regression.
- **`TimelineView` content closures may NOT call instance methods or read instance computed properties on the enclosing View.** Allowed inside the closure: `let` props on `self`, `Self.foo(...)` static helpers, `ctx.date`, SwiftUI view builders. For views with mutable state (spectrum meters, animated bars), use a `.task { while !Task.isCancelled { … assign @State … try? await Task.sleep(...) } }` driver instead of `TimelineView` — `@State` mutation triggers normal SwiftUI re-render without the TimelineView dispatch path. See `solutions/runtime-errors/timelineview-mainactor-instance-method-crash-2026-05-16.md`.
- **All `.onHover` callsites go through `dsOnHover` (in `DSComponents.swift`).** Raw `.onHover { hovered = $0 }` written inside a `@MainActor` View body inherits `@MainActor` per SE-0420, so its prologue performs an executor check. `dsOnHover` strips the inherited isolation via `@Sendable` and then hops back with `Task { @MainActor in … }` for the `@State` write — an async hop costing ~one frame. **`MainActor.assumeIsolated` was considered and rejected as that bridge** (it calls into the same `_taskIsCurrentExecutor` family as the crash and traps unconditionally if SwiftUI ever dispatches `.onHover` off-main); don't "simplify" the helper back into it. The only legal raw `.onHover` in the project is `dsOnHover`'s own definition. See `solutions/runtime-errors/onhover-mainactor-inheritance-crash-2026-05-19.md`.
- **Both rules above are mitigations, not cures — and they stay in force.** Each removed one *reader* of the process's main-executor identity, which on macOS 26.2 was being poisoned by something else entirely: a swallowed ObjC exception unwinding through `libswift_Concurrency` and orphaning the thread's `ExecutorTrackingInfo`. That is why each fix held at its own site and the crash reappeared at the next one (`TimelineView` → `.onHover` → a stock SwiftUI `Button` inside Apple's `_ButtonGesture`, where there is no app closure left to annotate). Keep both rules — fewer executor checks is genuinely better here, and both shapes are good practice on their own merits — but do **not** treat a new crash with this signature as a missing annotation. Read `solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md` first; the actionable move is to read the *other* threads in the crash report and look for `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`.
- **Inside a `Task { @MainActor }` / `MainActor.run` body, an AppKit / AVFoundation / CoreAudio API that can raise is called only after its preconditions have been validated at the call.** This is the rule the two above are the *mitigation* half of. An Objective-C `NSException` raised inside a main-actor Swift-concurrency job unwinds through `libswift_Concurrency`, whose stack-allocated `ExecutorTrackingInfo` node has no unwind landing pad; AppKit swallows the exception at the run-loop boundary and execution resumes, so the *next* executor check anywhere in the process SIGSEGVs, hundreds of milliseconds and one unrelated user action later. Mechanism: `solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`. **Validate the argument; do not wrap the call.** Two containment shapes were considered and rejected as the primary fix — a `DispatchQueue.main.async` bridge (a dispatch block is not a concurrency job, so nothing is orphaned) and an Objective-C `@try/@catch` shim. Both leave the defect in place: the tap still fails to install, the panel still fails to position, and the user gets a dead spectrum meter or a mispositioned HUD instead of a crash. They are the *documented escalation* if validating the argument turns out not to hold — recorded in the family entry, not to be reached for first.

**The audit this rule came out of — a starting point, not a closed set.** Split by whether the precondition is checkable, because that is what decides whether a site can be *fixed* or only *contained*:

| Site | Raise | Precondition checkable? | Status |
|---|---|---|---|
| `MicProbe` tap mutation — `installTap` / `removeTap` | `com.apple.coreaudio.avfaudio`: tap format ≠ the input node's live format; `removeTap` on an untapped bus | **Yes** — `MicProbeFormatGate` | **Raise removed.** Residual: the device switch is async, so the guard narrows the window from "several object constructions wide" to "one call wide" and validates format only. `MicProbe` is exonerated by an *absent* `com.apple.coreaudio.avfaudio` breadcrumb record, not by the absence of a crash. |
| `HUDPanel` geometry — `setContentSize` / `setFrameOrigin` | `NSInvalidArgumentException`: a NaN / infinite `NSHostingView.fittingSize` measured before the view has a stable window-screen context | **Yes** — `HUDPanelGeometry` | **Raise removed.** Rejected size skips (falling back to `seedContentSize`); a rejected origin term is substituted and *reported*, because a silent skip parks the HUD in the screen's bottom-left for the session. |
| `FixedSizeWindowConfigurator.lock` — `styleMask` + `setFrame(_:display:)` | `NSInternalInconsistencyException`: mutating a window AppKit is still configuring | **No** — "AppKit is not mid-configure" has no API | **Containment only — this narrows exposure, it does not remove a raise.** `lockReason` decides whether the mutation is *needed*, never whether it is *safe*, and it skips precisely the steady-state repeats least likely to raise while the first `lock()` from `viewDidMoveToWindow` — the mid-configure one — passes and runs unchanged. It may also never skip anything in practice: `minSize`/`maxSize`/`frame` are frame-space and AppKit's `constrainFrameRect(_:to:)` clamps to the visible screen, so on a display too short for the target the frame limb never matches. If evidence ever names this site, the fix is the containment escalation above, not a sharper predicate. |
| `SileroVAD` actor init (CoreML / Espresso) on `AppState.prime()`'s main-actor `Task` | Espresso / ANE is plain ObjC/C++ and can raise | Not attempted | **Untouched, deferred pending evidence.** Gated on a diagnosis naming a CoreML/Espresso exception; that diagnosis was never obtained. Re-arms on an `OBJC THROW` record naming one, and then **both** load sites move (`AppState.swift:463` and `:936`). |

**Which of these actually throws is not known.** All four are ranked suspects from a static + runtime audit; **none has been observed firing in the wild, and there may be more than one.** The list is where to start, not what to trust. What names the real thrower is `NoType/Diagnostics/ExceptionBreadcrumb.swift` — its `OBJC THROW` `.fault` record carries the exception's own name and throwing stack — and it is the interceptor, not this list, that catches the sites nobody enumerated.

**Mechanically pinned only where a chokepoint makes the set closed.** `RaiseSiteScanner` (in `NoTypeTests/HUDPanelGeometryTests.swift`) scans exactly two files: every `setContentSize` / `setFrameOrigin` / `setFrame` / `setFrameTopLeftPoint` / `setFrameSize` in `HUDPanel.swift` must sit inside `applyValidated`, every `installTap` in `MicProbe.swift` inside `installTapAndStart`, every `removeTap` inside `removeTapIfInstalled`. It carries the presence complement required by `solutions/conventions/source-scan-guard-fidelity-2026-07-25.md` — the mutator still occurs, the chokepoint is declared, something calls it, and **each body that performs the mutation** still contains the validation — because an absence-only scan is green on a file where the chokepoint was deleted or hollowed into a passthrough. Limits, recorded so the green is not over-trusted:

- **Two files only.** `HUDController.swift` also calls `layoutIfNeeded()` and reads `panel.frame`; a geometry call added *there* is outside the closed set and is not caught.
- **A general scan for "raise-prone API inside a main-actor `Task`" was rejected**, and the reasoning is in the family entry so it is not re-derived. Short version: there is no closed set of raising AppKit APIs, so the needle list would be a guess — and every way a source scan fails produces a *passing* test, which is worse than no scan because reviewers stop checking by hand.
- **The mutator list is an enumeration, not a closed set.** Within the two scanned files, only the spellings listed above are seen; a geometry API absent from the list passes silently. The known un-needled case is the `frame` property setter (`self.frame = …`) — `frame =` would also match every `let frame = …`. Adding a mutator kind means adding a `HUDPanelGeometry` predicate **and** a rule beside the others; adding one *inside* an existing wrapper still passes, because `applyValidated(frameOrigin:)` validates a point, not a rect.
- **`mustValidate` is a substring test, not a dataflow one.** A wrapper that calls its predicate and discards the result satisfies it. It pins that the check is still present — the deletion this guard exists to catch — not that it still gates.

The scanner's own doc-comment carries the same list, measured by trying to defeat it rather than reasoned about; the overload-collapse case (a second `applyValidated` overload with no check, excused by its validating sibling) **is** caught, pinned by `test_scanner_presenceFlagsAnUnvalidatingSecondOverloadOfTheChokepoint`.

## Launch ordering

**No type constructed by `NoTypeApp.init()` may schedule `MainActor` work or touch `NSApp` during construction.** That code runs before `NSApplicationMain` has started the application, and scheduling into that window is a latent ordering bug — which is reason enough for the rule.

> It was also, in 2026-07, the leading hypothesis for the macOS-26.2 executor-identity crash family (issue #82). **That hypothesis is disproven**: the reordering shipped as v0.1.13-rc1 (`bfcec4a`) and did not fix the crash, and the proven cause turned out to be a swallowed ObjC exception (see `solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`). The rule stands on its own merits; don't cite it as crash coverage.

- **The one thing that does run eagerly in `init()` is `ExceptionBreadcrumb.install()`, as the very first statement** — a `dlsym` lookup plus an `objc_setExceptionPreprocessor` function-pointer swap. It is not an exception to the rule below, it simply doesn't engage it: it schedules no `MainActor` work and touches no `NSApp`. It goes first so it observes every type the initializer then constructs. Note that `LaunchOrderingTests`' scan **cannot** see this file (it discovers types by construction, and this is a static call), so the rule is pinned for it separately by `ExceptionBreadcrumbTests.test_breadcrumbSource_schedulesNoMainActorWork_andDoesNotTouchNSApp`. See `NoType/Diagnostics/ExceptionBreadcrumb.swift`.
- Launch work lives in `AppState.prime()`, `PermissionsViewModel.prime()`, and `AppearanceController.apply()`.
- All three are driven by closures on `NoTypeAppDelegate`, assigned in `NoTypeApp.init()` (assigning a closure schedules nothing and touches no `NSApp`) and invoked from AppKit's launch callbacks. Two hooks, deliberately:
  - `willFinishLaunchingHandler` → `applicationWillFinishLaunching(_:)` → `appearance.apply()`. This is the last hook before SwiftUI evaluates the first `View.body`, which is what `AppearanceController.init` used to guarantee ("the very first frame already has the correct appearance").
  - `launchHandler` → `applicationDidFinishLaunching(_:)` → `appearance.apply()` again (idempotent fallback), then `state.prime()`, then `updates.start()` (Sparkle). Appearance stays **before** priming so the theme is on `NSApp` ahead of any UI priming can surface; Sparkle goes **last** — background work with no launch-time surface.
- `appDelegate.terminationHandler` is assigned in `init` too, but hangs off **no** launch hook: it is a pure closure assignment (schedules nothing), and the delegate owns it, so assigning it from `launchHandler` would only add a retain cycle. It fires from `applicationWillTerminate(_:)` and restores the user's audio after a `MusicInterruption` mute.
- **Don't move any of this to a scene's `.task`.** NoType is `LSUIElement` and the main window isn't presented at launch once onboarding is complete, so a returning user would never fire it. This is not hypothetical: `updates.start()` and the termination handler both sat on `.task` modifiers on `MainWindowView`, so menu-bar-only users got **no update checks ever**, and quitting from the popover could leave the system muted. Fixed on the launch hook; pinned by `LaunchOrderingTests.test_sparkleAndTerminationHandler_areWiredFromInit_notAWindowTask`, which also asserts `NoTypeApp.swift` contains no `.task` at all.
- `AppState.prime()` calls `permissions.prime()` and then `applyAccessibilityState()` **synchronously, in that order**. `observePermissions()` only reacts to changes *after* its entry snapshot, so an already-`.granted` state would otherwise never install the hotkey tap. Swapping these two lines ships an app whose push-to-talk never installs.
- **No `MainActor.assumeIsolated` in any delegate callback.** It calls into the same `swift_task_isCurrentExecutor` family that faults in this crash family, and it is pure ceremony: `NSApplicationDelegate` conformance already makes the class `@MainActor`, so a direct call to a `@MainActor` closure typechecks under strict concurrency.
- Both `prime()` methods log one `.info` line on entry. That breadcrumb is the only way to distinguish "priming never ran" (a nil/never-fired handler — the app looks alive but the hotkey is dead and every mirror is empty) from a genuinely ungranted install.

Pinned by `NoTypeTests/LaunchOrderingTests.swift` (source scan over every type reachable by construction from `NoTypeApp.init()`, following same-file calls transitively, and covering stored-property defaults) and `NoTypeTests/LaunchPrimingTests.swift` (behaviour, including the delegate hooks themselves). The scan proves the work is *absent* from initializers; `test_launchWork_isActuallyWiredUp_fromNoTypeAppInit` is its complement and proves it is *present* at the hook.

Why each rule exists (rationale, rejected alternatives, the bugs that produced them):

- `solutions/architecture-patterns/scene-task-is-not-a-launch-hook-2026-07-25.md` — why launch work lives on the delegate; the shipped bug where Sparkle never ran for menu-bar-only users.
- `solutions/design-patterns/observation-loop-swallows-initial-state-2026-07-25.md` — why `permissions.prime()` must precede `applyAccessibilityState()`, and why the observer cannot cover the initial state.
- `solutions/conventions/source-scan-guard-fidelity-2026-07-25.md` — how the guard above loses fidelity, and why it needs the presence assertions.
- `solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md` — the crash this rule was originally a hypothesis about, the proven cause that replaced it, and why the rule survives the disproof anyway.

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

- **Permission HUDs are suppressed during onboarding — with one gap.** `AppState`'s launch auto-show and `handleMenuBarOpened` both gate on `onboarding.isComplete`; the wizard's permissions step drives its own prompts. **`handleHotkeyPress` does not gate on it**: once Accessibility is granted (wizard step 3) the tap is live, and a press with the microphone still ungranted calls `hud.presentMissing([.microphone])`. `onboardingHotkeyPressObserver` short-circuits that only on the hotkey-check step, so the permissions and mic-check steps are exposed. Don't cite "HUDs are suppressed during onboarding" as if it were total — it is the reason the crash-family entry can't call `HUDPanel` and `MicProbe` mutually exclusive.
- **Hotkey-test isolation** — the hotkey-check step sets `appState.onboardingHotkeyPressObserver` (and release sibling) on `.appear`. While set, `handleHotkeyPress` short-circuits before starting a `RecordingSession`.
- **Mic check uses `MicProbe`** (`NoType/Onboarding/MicProbe.swift`) — its own `AVAudioEngine` instance, no VAD, no `RecordingSession`. Spectrum renderer duplicated as a step-local `OnboardingSpectrumMeter` (sized 360 × 80 vs the HUD's 36 pt strip).

## Motion

Animations are intentional. Pull duration / easing from `DS.Motion` (`instant` / `fast` / `base` / `slow` / `easeIn` / `easeInOut` / `spring`). HUDs use `dsHudChrome()` which spring-pops via `DS.Motion.spring` (260 ms cubic-bezier `(.34, 1.32, .64, 1)`).

## Known gaps

- `DS.Font` is short of the spec's full scale (missing `fs-16/18/20/24/32/44/64`) and lacks paired line-heights.
- Light theme not implemented; spec defines it. Acceptable for v1.

## Testing

- No dedicated UI tests today.
- `NoTypeTests/HUDPanelGeometryTests.swift` — the pure `HUDPanelGeometry` predicates, plus `RaiseSiteScanner`: the two-file source guard for the raise-prone-call rule above, its presence complement, and fixtures pinning the scanner itself.
- Snapshot tests for `HistoryRowView` and the empty-state popover are planned.
- Manual smoke test before each release.

## Pointers

- Architecture overview (Mermaid, modules, integrations, threading) → `docs/architecture/overview.md`.
- Why the two hard rules above exist, and why per-call-site annotation is mitigation rather than a cure → `solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`. The `TimelineView` and `.onHover` crashes are two of three same-signature incidents on macOS 26.2; the third is a stock SwiftUI `Button` (issue #82), which is why the README carries a known-issue note. The cause is a swallowed ObjC exception, not a SwiftUI dispatch path — the diagnostic that matters is the `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION` breadcrumb on a *non-crashing* thread.
- Why deployment target = macOS 15 → `solutions/tooling-decisions/macos-15-deployment-target-2026-05-15.md`.
- Sparkle 2 update banner (sidebar pill, not a HUD) → `solutions/tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md` + `NoType/Updates/CLAUDE.md`.
- History list source / lifetime stats → `NoType/History/CLAUDE.md`.
