---
module: Onboarding
date: 2026-05-18
problem_type: convention
component: tooling
severity: medium
related_components:
  - permissions
  - userdefaults
tags:
  - onboarding
  - permissions
  - userdefaults
  - reset-wizard
  - hasasked
applies_when:
  - "Adding a new UserDefaults flag that gates onboarding UI state"
  - "Adding a new TCC permission emulation flag (the Bool-API workaround pattern)"
  - "Touching OnboardingState.resetWizardDefaults"
---

# Onboarding reset must also clear permission `hasAsked` flags

## Context

Two NoType permissions emulate the macOS `.notDetermined` state via UserDefaults `hasAsked` flags — `notype.permissions.accessibility.hasAsked` and `notype.permissions.screenRecording.hasAsked` — because `AXIsProcessTrustedWithOptions` and `CGPreflightScreenCaptureAccess` both return raw `Bool`, leaving fresh-install indistinguishable from explicit denial. The flag is sticky-true once `request()` runs (or once the lazy migration fires for `notype.onboarding.complete`-positive users).

The friction: `OnboardingState.resetWizardDefaults` originally cleared only the three onboarding keys (`currentStep`, `furthestStep`, `complete`). A user who reset onboarding via Settings → Reset Onboarding kept the sticky `hasAsked` flag, so the re-run wizard rendered the Permissions step with **red "DENIED"** on Accessibility and Screen Recording — the exact UX the `hasAsked` pattern was meant to eliminate for users who refused nothing in the current wizard run.

Caught by the `ce-code-review` adversarial reviewer on PR #51 (the original parent fix that introduced AX's `hasAsked` flag). Not pre-existing — the bug shipped the moment AccessibilityPermission gained the `hasAsked` flag, because Reset Onboarding was the second user-visible state-reset surface and nobody propagated the new key into it.

## Guidance

When adding a new persistent `UserDefaults` flag that gates onboarding UI rendering, extend `OnboardingState.resetWizardDefaults(in:)` to clear it alongside the three onboarding keys. Each new flag also gets a corresponding test case in `OnboardingStateTests` (`test_resetWizard_clears<FlagName>`).

For permissions specifically: every `*Permission.hasAskedKey` must be exposed at internal visibility (no access modifier) — not `private` — so `OnboardingState` can reference the canonical key string. `@testable import` does NOT elevate `private` to internal, so the visibility choice is load-bearing for cross-module clear and for unit-test access.

The minimal extension:

```swift
nonisolated static func resetWizardDefaults(in defaults: UserDefaults) {
    defaults.removeObject(forKey: currentStepKey)
    defaults.removeObject(forKey: furthestStepKey)
    defaults.removeObject(forKey: completeKey)
    defaults.removeObject(forKey: AccessibilityPermission.hasAskedKey)
    defaults.removeObject(forKey: ScreenRecordingPermission.hasAskedKey)
}
```

Document the new clear-set in `NoType/Permissions/CLAUDE.md` invariant 6 (the cross-module hard-rule that already pins the `hasAsked` pattern).

## Why This Matters

`hasAsked` flags are deliberately sticky across launch lifetimes — that's the whole point of the pattern (the OS only records `granted`/`refused`, so we record "user has seen our Grant UI" ourselves). But Reset Onboarding is a user-driven *state reset*: the user explicitly asked for a clean wizard. Leaving the flag set means the wizard cannot honor that request for any UI surface that uses the flag.

The same logic generalizes to any future onboarding-gating flag: **state resets must reset all the state, including derived flags persisted by adjacent modules.** Forgetting one flag silently degrades the reset's contract without any compile-time or runtime signal.

## When to Apply

- Adding a new TCC permission whose system API returns `Bool` (no native `.notDetermined`). Always follow the existing `ScreenRecordingPermission` / `AccessibilityPermission` shape AND extend `resetWizardDefaults`.
- Adding any other UserDefaults flag that drives onboarding wizard rendering (e.g., a future "mic-check-passed" or "hotkey-test-completed" sentinel that, once set, suppresses the corresponding step).
- Reviewing PRs that add new `UserDefaults` keys under the `notype.permissions.*` or `notype.onboarding.*` namespaces — check `resetWizardDefaults` was updated in the same diff.

Does NOT apply to flags whose semantics are deliberately session-persistent across resets (e.g., the selected microphone UID, the Gemini API key, the hotkey binding — see the existing `test_resetWizard_preservesKeychainAndHotkeyAndMicKeys` regression guard).

## Examples

### Bad — flag survives reset

```swift
// AccessibilityPermission.swift
enum AccessibilityPermission {
    private static let hasAskedKey = "notype.permissions.accessibility.hasAsked"
    // ...
}

// OnboardingState.swift
nonisolated static func resetWizardDefaults(in defaults: UserDefaults) {
    defaults.removeObject(forKey: currentStepKey)
    defaults.removeObject(forKey: furthestStepKey)
    defaults.removeObject(forKey: completeKey)
    // forgot to clear AccessibilityPermission.hasAskedKey
}
```

User flow:
1. Onboarding completes → `hasAsked = true` (set by the user's Grant click)
2. Settings → Reset Onboarding → only the three onboarding keys are cleared
3. Wizard re-opens → Permissions step renders Accessibility as **red "DENIED + Open Settings"** even though the user hasn't refused anything in this wizard run

### Good — flag rides along with the reset

```swift
// AccessibilityPermission.swift
enum AccessibilityPermission {
    // Internal visibility so OnboardingState can reference the canonical
    // key string. `@testable import` would NOT elevate `private`, so this
    // visibility choice is required for the cross-module clear path AND
    // for unit-test access.
    static let hasAskedKey = "notype.permissions.accessibility.hasAsked"
    // ...
}

// OnboardingState.swift
nonisolated static func resetWizardDefaults(in defaults: UserDefaults) {
    defaults.removeObject(forKey: currentStepKey)
    defaults.removeObject(forKey: furthestStepKey)
    defaults.removeObject(forKey: completeKey)
    defaults.removeObject(forKey: AccessibilityPermission.hasAskedKey)
    defaults.removeObject(forKey: ScreenRecordingPermission.hasAskedKey)
}
```

Pinned by `OnboardingStateTests.test_resetWizard_clearsPermissionHasAskedFlags`.

## Related

- `NoType/Permissions/CLAUDE.md` invariant 6 — the canonical `hasAsked` pattern documentation.
- `NoType/Onboarding/OnboardingState.swift:113` — `resetWizardDefaults` definition.
- `NoType/Permissions/AccessibilityPermission.swift:21` — the first permission to surface this gap.
- `NoType/Permissions/ScreenRecordingPermission.swift:23` — the canonical reference for the `hasAsked` pattern (predates Accessibility's adoption).
- `docs/solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md` — original ADR that established the `hasAsked` workaround for Screen Recording.
- PR #51 — the diff that introduced this guidance, including the `ce-code-review` adversarial finding that surfaced the original gap.
- `docs/plans/2026-05-18-002-fix-accessibility-not-determined-state-plan.md` — parent plan.
