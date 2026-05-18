---
status: active
type: fix
created: 2026-05-18
---

# fix: Accessibility permission shows red "DENIED" on first onboarding launch

## Summary

On a fresh install, the onboarding **Permissions** step renders the Accessibility row in red with a "DENIED" pill and an "Open Settings" CTA — *before* the user has refused anything. This is alarming and inconsistent with Microphone (yellow "REQUIRED") and Screen Recording ("OPTIONAL").

Root cause: `AccessibilityPermission.current()` returns only `.granted` or `.denied` — the macOS API (`AXIsProcessTrustedWithOptions`) yields a `Bool`, so we cannot distinguish "user has not been asked yet" from "user explicitly denied". On first launch, TCC has no record → `current() == .denied` → red row.

Fix: mirror the existing `ScreenRecordingPermission` pattern (same TCC `Bool` limitation, already solved there). Persist a `hasAsked` flag in `UserDefaults`; return `.notDetermined` until the user clicks Grant at least once. The onboarding UI already routes `.notDetermined` through the same path as Microphone's first-run state (`tagState == .required` → yellow pill, primary "Grant" button) — no UI changes needed.

## Problem Frame

Reference: screenshot from a first-launch session shows Microphone (yellow REQUIRED), Accessibility (**red DENIED — wrong**), Screen Recording (OPTIONAL).

- **Who is affected:** every new user during onboarding, plus any existing user who reset TCC for `app.notype` between launches.
- **What's surprising:** the wizard explicitly tells the user "Enable required permissions" — but one of the rows is already styled as if the user did something bad. The first-run UX should be neutral, not punitive.
- **What's not surprising:** after the user clicks Grant and macOS records a decision, the `.denied` state is the correct visual when the user actually denied.

Screen Recording solved this exact problem at `NoType/Permissions/ScreenRecordingPermission.swift:14-34`. The doc-comment there spells out the design — copy it for Accessibility.

## Scope Boundaries

**In scope**
- Add `.notDetermined` first-run state to `AccessibilityPermission`.
- Backfill the `hasAsked` flag for existing users whose onboarding already completed, so they aren't downgraded from red "DENIED" back to yellow "REQUIRED" after upgrade (would mask a real denial).
- Update `NoType/Permissions/CLAUDE.md` to document the new invariant alongside the existing Screen Recording one.

**Out of scope**
- UI redesign of the permission rows. The existing tri-state styling (REQUIRED / DENIED / GRANTED) already handles `.notDetermined` correctly because `denied: permissions.accessibility == .denied` evaluates false when state is `.notDetermined`.
- Microphone's first-run state. `MicrophonePermission.current()` already returns `.notDetermined` natively via `AVCaptureDevice.authorizationStatus` — no change.
- Changing the polling cadence in `PermissionsViewModel`. The fix is upstream of polling.
- Re-prompting macOS on launch. `AXIsProcessTrustedWithOptions(prompt: true)` only prompts once per launch lifetime; we deliberately don't auto-call it.

### Deferred to Follow-Up Work

None — the change is bounded enough to land as one PR.

---

## Key Technical Decisions

### Mirror the Screen Recording pattern exactly

`ScreenRecordingPermission` already documents and ships the same `Bool`-API workaround (file header comment + `hasAskedKey` UserDefaults flag). Use the same shape — same key naming (`notype.permissions.accessibility.hasAsked`), same `current()` branching (`granted → .granted`, else `hasAsked ? .denied : .notDetermined`), same `request()` side effect (set the flag).

**Why:** consistency. The next person reading either file finds the same pattern. A second source-of-truth for "how do we emulate notDetermined" invites drift.

### Backfill the flag for existing users whose onboarding completed

On the first `current()` call under the new build, if the flag is unset AND `UserDefaults.standard.bool(forKey: "notype.onboarding.complete")` is true, set the flag to true.

**Why:** without backfill, an existing user who explicitly denied AX in a prior launch would suddenly see the row flip from red "DENIED" back to yellow "REQUIRED" on the next launch — which is wrong (they were asked) and worse, clicking Grant would silently no-op because macOS only prompts once per launch lifetime. Backfill preserves the correct "DENIED + Open Settings" CTA for users who explicitly refused.

**Why this signal:** `notype.onboarding.complete` is the closest available proxy for "this user has been through the permissions step at least once." Reading a single UserDefaults key keeps the migration self-contained inside `AccessibilityPermission` — no cross-module dependency, no app-launch migration call.

Alternative considered: introduce a separate "app has been launched before" key. Rejected — adds a new persistence key for a one-time migration that the existing `onboarding.complete` already implies.

### Inline the migration in `current()`, lazy and idempotent

Rather than wiring a one-shot migration call into `AppState` init or `NoTypeApp.body`, put the migration inside `AccessibilityPermission.current()`:

```
if !hasAsked && UserDefaults.bool(forKey: "notype.onboarding.complete") {
    UserDefaults.set(true, forKey: hasAskedKey)
}
```

**Why:** the migration is a single UserDefaults read + conditional write. It runs at most a handful of times (until the flag is set, then becomes a no-op). Inlining keeps the entire AX-vs-TCC state machine in one file.

### Extract a pure `mapStatus(isAxGranted:hasAsked:) -> PermissionStatus` for tests

The system call (`AXIsProcessTrustedWithOptions`) is not mockable, but the mapping logic is pure. Extract it as a `static` helper so unit tests can pin the state-machine intent without touching TCC.

**Why:** matches the existing `Permissions/CLAUDE.md` testing guidance — "TCC status → `PermissionStatus` mapping helpers" are listed as the testable surface. Without this extraction, the only test path is manual smoke.

---

## Implementation Units

### U1. Add `.notDetermined` first-run state to `AccessibilityPermission`

**Goal:** the AX permission emits `.notDetermined` on first launch (no record in TCC, no prior Grant click) so the onboarding row renders as yellow "REQUIRED" instead of red "DENIED".

**Requirements:** address the observed first-launch UX defect; preserve the correct red "DENIED" surface for users who explicitly denied.

**Dependencies:** none.

**Files:**
- `NoType/Permissions/AccessibilityPermission.swift` — modify.
- `NoTypeTests/AccessibilityPermissionTests.swift` — new.

**Approach:**
- Add a `private static let hasAskedKey = "notype.permissions.accessibility.hasAsked"`.
- Refactor `current()` to:
  1. Read `AXIsProcessTrustedWithOptions(prompt: false)` → if true, return `.granted`.
  2. Run the migration: if the `hasAsked` flag is unset AND `UserDefaults.standard.bool(forKey: "notype.onboarding.complete")` is true, set `hasAsked = true`.
  3. Return `hasAsked ? .denied : .notDetermined`.
- Modify `request()` to set `UserDefaults.standard.set(true, forKey: hasAskedKey)` *before* calling `AXIsProcessTrustedWithOptions(prompt: true)`. This guarantees that even if macOS suppresses the prompt (e.g. the user previously chose Deny in an earlier launch lifetime), subsequent `current()` calls correctly report `.denied`.
- Extract the mapping decision into a `static func mapStatus(isAxGranted: Bool, hasAsked: Bool) -> PermissionStatus` so the test in U1 can pin it.
- Keep the existing file-header doc-comment and explain the pattern parallel to `ScreenRecordingPermission`'s header.

**Patterns to follow:**
- `NoType/Permissions/ScreenRecordingPermission.swift:14-34` — file header comment shape, `hasAskedKey` naming, `current()` branching.
- `NoType/Permissions/PermissionsViewModel.swift:128` — `.denied / .notDetermined / .granted` are all already consumed correctly by the view-model; no change there.

**Test scenarios:**
- `mapStatus(isAxGranted: true, hasAsked: false) == .granted` — granted always wins, regardless of the flag.
- `mapStatus(isAxGranted: true, hasAsked: true) == .granted` — same.
- `mapStatus(isAxGranted: false, hasAsked: false) == .notDetermined` — fresh install path.
- `mapStatus(isAxGranted: false, hasAsked: true) == .denied` — user was asked and refused.
- Migration smoke (drives `current()` directly with controlled UserDefaults):
  - Reset both `hasAsked` and `notype.onboarding.complete` → first `current()` call leaves `hasAsked` unset → returns `.notDetermined` when AX is ungranted.
  - Set `notype.onboarding.complete = true`, leave `hasAsked` unset → first `current()` call sets `hasAsked = true` → returns `.denied` (assuming AX ungranted in the test environment).
  - Idempotence: with `hasAsked` already true, `current()` does not overwrite it (verify the write is gated).
- `request()` flips `hasAsked` to true on call (regardless of AX outcome, since macOS may suppress the prompt).

> Test scope: the AX syscall itself is not mocked — tests on the live `current()` path read the real TCC state. Run with TCC ungranted for the test target (the default state for a freshly-built test bundle). The migration assertions only check the UserDefaults side effect, not the `.granted/.denied` boundary, so they pass regardless of host AX state.

**Verification:** the new tests pass; existing `PermissionsViewModel` tests (if any) still pass; the `AccessibilityPermission` file compiles under Swift 6 strict concurrency.

---

### U2. Update `NoType/Permissions/CLAUDE.md` to document the new invariant

**Goal:** the next maintainer reading the permission module finds the AX `.notDetermined` workaround documented alongside the Screen Recording one.

**Requirements:** project convention — load-bearing invariants live in the module CLAUDE.md.

**Dependencies:** U1.

**Files:**
- `NoType/Permissions/CLAUDE.md` — modify.

**Approach:**
- Add a new invariant under the existing list (after the current invariant 5 about `withObservationTracking`) along the lines of:
  > **Accessibility and Screen Recording emulate `.notDetermined` via a UserDefaults `hasAsked` flag.** Both APIs return `Bool`, so a fresh install is indistinguishable from an explicit denial. Until `request()` has been called once, `current()` returns `.notDetermined` and the onboarding row renders as "REQUIRED" rather than "DENIED". The flag is backfilled to `true` on first call under the new build if `notype.onboarding.complete` is already set, preserving the correct "DENIED" surface for existing users who explicitly refused.
- In the **Files** list, update the `AccessibilityPermission.swift` line to mention the `hasAsked` mirror.
- In the **Status enum** block, update the `// denied` comment for Accessibility's case (or add a short note above the block) to spell out that `.denied` now means "user explicitly refused" and `.notDetermined` means "user hasn't been asked yet" — same as Screen Recording.
- Add a `Hard rules` bullet:
  > **`AccessibilityPermission.request()` must set the `hasAsked` flag before calling `AXIsProcessTrustedWithOptions`.** If macOS suppresses the system prompt (it only prompts once per launch lifetime), the flag is still the only signal that distinguishes refusal from never-asked. Flipping the order would let an existing-denial state silently regress to `.notDetermined` on first call after upgrade.

**Patterns to follow:**
- `NoType/Permissions/CLAUDE.md` Invariants 1-5 — same tone, same "one-sentence claim + one-sentence justification" shape.

**Test expectation:** none — doc-only change.

**Verification:** the new invariant + hard rule appear in the file; the `AccessibilityPermission.swift` line in the Files list is updated; the Status enum block reflects the new semantics.

---

### U3. Manual smoke verification

**Goal:** confirm that a fresh-install scenario renders Accessibility as yellow "REQUIRED" (not red "DENIED"), and that an explicit denial still renders red.

**Requirements:** the original defect was screenshot-level — automated tests can pin the state machine but not the rendered chrome.

**Dependencies:** U1, U2.

**Files:** none.

**Approach:** run the standard build / deploy / TCC-reset cycle and step through the wizard manually. Sequence:

1. Build per `docs/build.md` rules (xcodebuild Debug → delete DerivedData `NoType.app` → user deploys to `/Applications`).
2. Wipe TCC + UserDefaults for the bundle:
   - `tccutil reset Accessibility app.notype`
   - `tccutil reset ScreenCapture app.notype` (so Screen Recording behaves identically and you can sanity-compare)
   - `defaults delete app.notype 2>/dev/null || true`
3. Launch `/Applications/NoType.app`. Walk to the Permissions step.
4. **Assert:** Accessibility row is yellow with the "REQUIRED" pill and a primary "Grant" button — *not* red, *not* "Open Settings".
5. Click **Grant**. macOS prompt appears.
   - **Path A — Deny:** row flips to red "DENIED" + "Open Settings" + Re-check. ✓
   - **Path B — Open System Settings, flip switch:** row flips green "Granted" within ~1 s (polling tick). ✓
6. Reset TCC + UserDefaults again, relaunch.
7. **Assert (migration path):** set `defaults write app.notype notype.onboarding.complete -bool true` *before* launch. Walk to the Permissions step. Accessibility row should render red "DENIED" (not yellow REQUIRED) — backfill picked up the completed-onboarding signal.

**Test expectation:** none — manual.

**Verification:** all five assertion checkpoints pass; report observations in the PR description.

---

## System-Wide Impact

- **Onboarding wizard (`NoType/Onboarding/Steps/OnboardingPermissionsStep.swift`):** no source change. The existing `denied: permissions.accessibility == .denied` predicate evaluates false for `.notDetermined`, routing through the `isRequired` branch — yellow REQUIRED + Grant. Verified by reading the row's `tagState` / `glyphSeverity` / `rowBackground` switches.
- **`PermissionsViewModel`:** no change. It already mirrors all three `PermissionStatus` cases. The polling tick already handles `.notDetermined → .granted` transitions because `needsPolling` checks `!isGranted`.
- **`AppState`:** no change. `AppState` observes `permissions.accessibility` via `withObservationTracking` and only takes action on `.granted` (installs the CGEventTap). `.notDetermined` is functionally equivalent to `.denied` from `AppState`'s perspective — the tap stays uninstalled until granted.
- **Hotkey path (`NoType/Hotkey/`):** no change. The CGEventTap install/uninstall is gated on `.granted` only.
- **Menu-bar icon dot:** the icon's "yellow warning" vs "red broken" surfacing today is driven by `permissions.allGranted`. Since `.notDetermined` and `.denied` both yield `!isGranted`, the menu-bar icon dot stays unchanged for both states. Acceptable — the post-onboarding HUD is the surface that distinguishes them, and that surface is suppressed during onboarding anyway.

---

## Risk Analysis

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Existing users who explicitly denied AX see the row flip back to yellow "REQUIRED" after upgrade, click Grant, get no prompt (macOS suppresses), and are stuck. | Medium without migration, near-zero with U1's backfill. | High — user can't recover without finding System Settings themselves. | Migration path in U1 reads `notype.onboarding.complete` and sets `hasAsked = true` on first `current()` call. Verified in U3 step 7. |
| `request()` sets the flag too eagerly — even when called via the onboarding "Re-check" link or polling tick by accident. | Low. | Low. The flag is sticky-true forever; a stray pre-set just means we surface `.denied` slightly earlier than necessary. | `request()` is only called from the explicit Grant button (`PermissionsViewModel.requestAccessibility`). `refresh()` and the polling tick call `current()`, never `request()`. Verified by grep on `requestAccessibility(` and `AccessibilityPermission.request(`. |
| Test environment has AX granted for the test runner (host machine has been granted Accessibility for Xcode/the test target). | Medium on developer machines, low on a freshly-provisioned CI runner. | Low — only affects the `current()`-driven migration tests in U1. | Migration test cases assert only the UserDefaults side effect, not the returned status. The pure-helper tests (`mapStatus`) are unaffected by host state. |
| Backfill heuristic fires for a user mid-onboarding (onboarding incomplete) — flag stays false until first Grant click. | n/a — that's the correct behaviour. Mid-onboarding users are exactly who should see `.notDetermined`. | n/a | No action needed. |

---

## Open Questions

None at planning time. The migration heuristic (`notype.onboarding.complete`) is the strongest available signal short of asking the user, and the cost of a wrong call (one extra Grant click) is bounded.
