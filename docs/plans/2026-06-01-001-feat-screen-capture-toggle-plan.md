---
title: "feat: In-app toggle for the screen-capture (OCR) context fallback"
date: 2026-06-01
type: feat
status: completed
depth: lightweight
module: UI
related:
  - docs/solutions/documentation-gaps/screen-capture-settings-section-2026-05-15.md
  - docs/solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md
  - NoType/UI/CLAUDE.md
  - NoType/Recording/CLAUDE.md
  - NoType/Permissions/CLAUDE.md
---

# feat: In-app toggle for the screen-capture (OCR) context fallback

## Summary

The screenshot + OCR context fallback (ADR-014) is gated **only** by the
Screen Recording TCC permission. Once a user grants it, the *only* way to
turn OCR off again is to revoke the system permission in System Settings —
a blunt, out-of-app round-trip. There is no soft in-app off-switch.

This plan adds a **"Use screen capture for context"** toggle to Settings →
Recording. It gates the OCR limb at runtime **independently** of the TCC
permission: a user can keep Screen Recording granted but tell NoType to stop
screenshotting. Default **on** (existing installs keep current behaviour),
frozen at session start, surfaced as one `DSCard` next to the Input-device
card.

Origin: `docs/solutions/documentation-gaps/screen-capture-settings-section-2026-05-15.md`
(severity **low**, "apply when users ask" — no report yet; this is a
privacy/control cleanup, not a reported pain).

---

## Problem Frame

**User-facing.** NoType feeds Gemini on-screen text for accuracy. In
Electron / web-view apps (Slack, Discord, VS Code, browsers) the
accessibility API returns nothing, so — *if* Screen Recording is granted —
NoType screenshots the active window, OCRs it, scrubs secrets, and sends only
the filtered text (no raw screenshot is stored or sent). A user who granted
the permission once (onboarding, or for accuracy) and later wants OCR off has
no in-app recourse short of revoking the system permission.

**Code-level.** The OCR limb is gated at a single point in
`NoType/Recording/RecordingSession.swift:337`:

```swift
let ocrEnabled = (ScreenRecordingPermission.current() == .granted) && pid > 0
```

`runOCRIfEnabled(enabled:)` begins with `guard enabled else { return nil }`,
so this one boolean is the whole gate — no other path spawns OCR. Adding a
user toggle means adding one more `&&` term to it, plumbed and frozen the
same way `userLanguages` / `dictionary` / `instructions` already are.

---

## Scope Boundaries

**In scope**
- A persistent, default-on `screenCaptureFallbackEnabled` flag on `AppState`.
- Folding it into the `ocrEnabled` gate, frozen at session start.
- A "Screen capture" card in the Recording settings pane.
- A pure decision helper + unit tests.
- Closing the origin doc-gap + the `TECHDEBT.md` index line.

**Non-goals**
- Changing the OCR feature itself (what's captured, scrubbed, or sent).
- Per-app OCR control.
- Touching the Screen Recording **permission** flow (`PermissionsViewModel`,
  onboarding card, About-pane chip stay as they are).

**Deferred to Follow-Up Work**
- A full permission **status badge** inside the Recording card (the origin
  doc's "granted / denied / needed" badge). The About-pane chip already owns
  permission *status* display; this card only needs the toggle + the
  grant-redirect interaction (see KTD-6), not a second status surface.

---

## Key Technical Decisions

1. **Default ON, decoded as `object(forKey:) as? Bool ?? true`** — *not*
   `.bool(forKey:)` (which defaults `false`). Mirrors `dictionaryEnabled`
   (`NoType/AppState.swift:99`). The absent-key path must keep OCR on, or
   every upgrading user silently loses the fallback.
2. **Frozen at session start.** The flag is passed into
   `RecordingSession.start(...)` and frozen, exactly like
   `userLanguagesFrozen` / `dictionaryFrozen`. A mid-session toggle flip must
   not affect the in-flight session (the "context frozen at session start"
   invariant). Never read `appState` mid-session for this.
3. **Single gate point.** Fold into `ocrEnabled` at
   `RecordingSession.swift:337`. Because `runOCRIfEnabled` short-circuits on
   `enabled == false`, nothing else changes.
4. **Pure helper for testability.** Extract
   `RecordingSession.shouldRunOCR(fallbackEnabled:permissionGranted:pid:)` as
   a `nonisolated static`, mirroring `shouldUseLitePath`. The branching logic
   gets pinned without standing up a real session.
5. **Cache-prefix is safe.** Toggle off → `screenText: nil` → the OCR
   sub-block isn't attached. This is an **already-supported state** (it's
   identical to "AX had content" or "permission off"). The `On-screen
   context:` section stays present (AX tree); only the optional OCR sub-block
   is omitted. `GeminiRequestBuilderTests` is untouched — pinned contract
   `test_partOrderAndLabels_stableWithAndWithoutOCR` already covers both
   shapes.
6. **Switch model — stored intent vs displayed position.** The stored flag is
   the user's *intent* ("I want OCR when it's available"), default `true`. The
   **displayed** switch position is the *effective* state:
   `permissions.screenRecording == .granted && screenCaptureFallbackEnabled`.
   The toggle's `set` is conditional:
   - **Permission granted** → flip the stored flag (normal toggle).
   - **Permission not granted** → don't flip; call
     `ScreenRecordingPermission.openSystemSettings()` **and** set intent
     `true` (tap = "I want this on"). The displayed position stays off until
     `PermissionsViewModel` polling picks up the grant, at which point it
     springs to on automatically. (Edge case this resolves: a user who
     manually turned it off, then lost permission, then taps to re-enable —
     "tap = intent to enable" wins over sticky-off. Flip this rule only if
     sticky manual-off is preferred.)
   Reactivity is free: `PermissionsViewModel` is `@Observable`, polls every
   1 s while Screen Recording is ungranted, and refreshes on app-activation,
   so the switch updates on return from System Settings with no restart.

---

## Implementation Units

### U1. Pure decision helpers + tests

**Goal:** Land the two pure, testable decisions — the runtime OCR gate and the
toggle-tap action — before any wiring, so the branching logic is pinned up
front.

**Dependencies:** none.

**Files:**
- `NoType/Recording/RecordingSession.swift` — add `shouldRunOCR`.
- `NoType/AppState.swift` — add the `ScreenCaptureToggleAction` enum + the
  `screenCaptureToggleAction(...)` pure static.
- `NoTypeTests/RecordingSessionOCRGateTests.swift` — new test file (gate).
- `NoTypeTests/ScreenCaptureToggleActionTests.swift` — new test file (toggle).

**Approach:**
- **Runtime gate.** `nonisolated static func shouldRunOCR(fallbackEnabled: Bool, permissionGranted: Bool, pid: pid_t) -> Bool`
  returning `fallbackEnabled && permissionGranted && pid > 0`. Not wired into
  `start()` yet (that's U2).
- **Toggle action (KTD-6).** A small enum
  `enum ScreenCaptureToggleAction: Equatable { case setIntent(Bool); case openSettings }`
  + `nonisolated static func screenCaptureToggleAction(permissionGranted: Bool, requestedOn: Bool) -> ScreenCaptureToggleAction`
  returning `.setIntent(requestedOn)` when granted, else `.openSettings`. The
  view (U3) executes the action: `.setIntent` → call the setter; `.openSettings`
  → set intent `true` **and** `ScreenRecordingPermission.openSystemSettings()`.

**Patterns to follow:** `RecordingSession.shouldUseLitePath` and its test file
`NoTypeTests/RecordingSessionShortPathTests.swift` (nonisolated static +
XCTest truth-table, no live session). The toggle helper is a `nonisolated`
static on the `@MainActor` `AppState` — reachable from tests via
`@testable import NoType` without standing up the object.

**Test scenarios:**

`RecordingSessionOCRGateTests`:
- All true (`fallbackEnabled: true, permissionGranted: true, pid: 1234`) → `true` (happy path).
- Off-switch wins (`fallbackEnabled: false`, others true) → `false`.
- No permission (`permissionGranted: false`, others true) → `false`.
- No frontmost pid (`pid: 0`, others true) → `false`.

`ScreenCaptureToggleActionTests`:
- Granted + requestedOn `true` → `.setIntent(true)`.
- Granted + requestedOn `false` → `.setIntent(false)` (normal turn-off).
- Ungranted + requestedOn `true` → `.openSettings` (redirect, not a flip).
- Ungranted + requestedOn `false` → `.openSettings` (defensive — ungranted
  switch already shows off, but the function must never silently flip).

**Verification:** Both test files compile and all cases pass.

---

### U2. AppState flag + freeze into the session gate

**Goal:** Persist the user choice and route it into the (now-pure) gate,
frozen at session start.

**Dependencies:** U1.

**Files:**
- `NoType/AppState.swift` — flag, key, setter, call-site plumb.
- `NoType/Recording/RecordingSession.swift` — `start(...)` param + freeze +
  replace the inline `ocrEnabled` expression with `Self.shouldRunOCR(...)`.

**Approach:**
- On `AppState`: add `screenCaptureFallbackEnabled` defaulting to
  `UserDefaults.standard.object(forKey: Self.screenCaptureFallbackKey) as? Bool ?? true`,
  key `notype.screenCaptureFallbackEnabled`, and a `setScreenCaptureFallbackEnabled(_:)`
  setter mirroring `setDictionaryEnabled` (persist immediately).
- On `RecordingSession`: add `screenCaptureFallbackEnabled: Bool` to
  `start(...)`, store it in a frozen field (e.g. `screenCaptureFallbackFrozen`),
  and at line 337 replace the inline boolean with
  `Self.shouldRunOCR(fallbackEnabled: screenCaptureFallbackFrozen, permissionGranted: ScreenRecordingPermission.current() == .granted, pid: pid)`.
- At the `session.start(...)` call site (`NoType/AppState.swift:832`), pass
  `screenCaptureFallbackEnabled: screenCaptureFallbackEnabled`.
- **Split the diagnostic log tag.** The `ocrTag` block (just below line 406)
  currently maps every `!ocrEnabled` to `"ocr=off (no-permission)"`. The gate
  now has two off-reasons; distinguish them: permission missing →
  `"ocr=off (no-permission)"`; permission present but the frozen flag off →
  `"ocr=off (disabled-by-setting)"`. Keeps the logs honest for the
  verification step below.

**Patterns to follow:** `dictionaryEnabled` + `setDictionaryEnabled`
(`AppState.swift:99`, `~1500`); frozen fields `userLanguagesFrozen` /
`dictionaryFrozen` in `RecordingSession.start`.

**Test scenarios:** Test expectation: none for the plumbing itself — the
branching logic is fully pinned by U1, and `AppState` property initializers
read `UserDefaults.standard` directly (no DI seam, consistent with the other
toggles which are also unit-test-exempt). Manual verification instead:
- Fresh defaults (key absent) → OCR still runs in an AX-empty app (default-on).
- Toggle off, relaunch → choice persists (`notype.screenCaptureFallbackEnabled == false`).

**Verification:** Builds clean under strict concurrency; the two manual
checks above hold.

---

### U3. "Screen capture" card in the Recording pane

**Goal:** Surface the toggle in Settings → Recording with the three-state
behaviour from KTD-6.

**Dependencies:** U1, U2.

**Files:**
- `NoType/UI/Settings/Panes/RecordingPane.swift`.

**Approach:** Add `@Environment(PermissionsViewModel.self) private var permissions`
(same as `AboutPane`) so the card reacts to grant changes. Add a private
`screenCaptureCard` — `DSCard(title: "Screen capture")` with a `DSCardRow`
(subtitle: "Fires only when accessibility returns no content for the active
app — primarily Electron / web-views"). Its accessory is a `Toggle` driven by
a **computed `Binding<Bool>`**, not `$appState.screenCaptureFallbackEnabled`
directly:
- `get`: `permissions.screenRecording == .granted && appState.screenCaptureFallbackEnabled`
  (the *effective* position — off whenever permission is missing).
- `set(newValue)`: switch on
  `AppState.screenCaptureToggleAction(permissionGranted: permissions.screenRecording == .granted, requestedOn: newValue)`:
  - `.setIntent(v)` → `appState.setScreenCaptureFallbackEnabled(v)`.
  - `.openSettings` → `appState.setScreenCaptureFallbackEnabled(true)` then
    `ScreenRecordingPermission.openSystemSettings()`.

When permission is missing, add one muted helper line under the row
("Requires Screen Recording — turning this on opens System Settings") so the
redirect isn't a surprise. Insert `screenCaptureCard` after `inputDeviceCard`
in the body `VStack`.

**Patterns to follow:** `inputDeviceCard` (`@Bindable` shadow, `DSCardRow`,
the `musicInterruption` accessory) in the same file; `AboutPane`'s
`@Environment(PermissionsViewModel.self)` + `ScreenRecordingPermission.openSystemSettings()`;
`DSCard` / `DSCardRow` from `DSComponents.swift`. All visual values via
`DesignTokens` (no inline alphas).

**Test scenarios:** Test expectation: none for the view itself — pure SwiftUI,
no UI tests in the project (`NoType/UI/CLAUDE.md` "Testing"); the branching
logic it consumes is already pinned by U1's `ScreenCaptureToggleActionTests`.
Manual smoke before push:
- Permission granted → switch reflects the stored flag; flipping it persists
  across relaunch.
- Permission granted, flag off → switch off; OCR suppressed next session.
- Permission **not** granted → switch shows off; tapping it opens System
  Settings; after granting + returning, the switch springs to on with no
  restart (polling).

**Verification:** Builds clean; manual visual + interaction check in
Settings → Recording. **User visually verifies the card before commit/push**
(`BUILD SUCCEEDED` ≠ layout correct).

---

### U4. Close the docs

**Goal:** Reflect the shipped state in the knowledge store and the tech-debt
index.

**Dependencies:** U3.

**Files:**
- `docs/solutions/documentation-gaps/screen-capture-settings-section-2026-05-15.md`
  — move Guidance from "when users start asking…" to "**done in PR #N**";
  add the closing PR to `## Related`.
- `docs/TECHDEBT.md` — remove the "Settings section for screen-capture
  fallback" line from **Current entries**.
- `NoType/UI/CLAUDE.md` — add the new card to the Recording-pane description
  in the Settings file list.

**Approach:** Documentation only — no build (per the CLAUDE.md "don't build
for doc edits" rule).

**Test expectation:** none — documentation.

**Verification:** The doc-gap file reads as closed with a PR reference; the
`TECHDEBT.md` index no longer lists the item.

---

## Risks & Mitigations

- **Default regression.** Decoding with `.bool(forKey:)` would default OCR
  **off** for upgraders. → Mitigated by `object(forKey:) as? Bool ?? true`
  (KTD-1) + the fresh-defaults manual check in U2.
- **Mid-session mutation.** Reading `appState.screenCaptureFallbackEnabled`
  mid-session would let a toggle flip change an in-flight session. →
  Mitigated by passing it into `start()` and freezing (KTD-2); the gate reads
  only the frozen field.
- **Build hygiene.** Three Swift files change (U1–U3). Build into the default
  DerivedData, then `rm -rf` the freshly built `NoType.app` from DerivedData
  (CLAUDE.md hard rule — `lsregister -u` alone won't hold), and deploy the
  dev build to `/Applications` per the session convention.

---

## Sequencing Notes

- **Branch off `origin/main`**, not the current `fix/keychain-data-protection-migration`
  branch — this work is unrelated. (Fetch first; local `main` lags behind
  merged PRs.)
- Order is strict: **U1 → U2 → U3 → U4**. Each is an atomic commit; U4 is
  doc-only and needs the PR number, so it lands last (or in the PR-finalising
  commit).

## Overall Verification

1. `RecordingSessionOCRGateTests` green (U1).
2. Manual: Settings → Recording shows the "Screen capture" card. With Screen
   Recording **granted**, toggling **off** → the next session logs
   `ocr=off (disabled-by-setting)` even though permission is on (watch
   `log stream` for subsystem `app.notype`); toggling **on** → OCR runs in an
   AX-empty app (e.g. a web-view). With permission **not** granted, tapping
   the switch opens System Settings and, after granting + returning, the
   switch springs to on (polling, no restart).
3. Origin doc-gap closed + `TECHDEBT.md` index trimmed (U4).
