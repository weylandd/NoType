---
title: Restricted entitlement without a provisioning profile → AMFI SIGKILLs the app before main()
date: 2026-07-25
category: runtime-errors
module: Keychain
problem_type: runtime_error
component: tooling
severity: critical
symptoms:
  - "App quits instantly on launch with NO crash report in ~/Library/Logs/DiagnosticReports"
  - "`amfid: <app> not valid: Error Domain=AppleMobileFileIntegrityError Code=-413 \"No matching profile found\"`"
  - "`AMFI: Code has restricted entitlements, but the validation of its code signature failed. Unsatisfied Entitlements:` (empty list)"
  - "`kernel: proc N: load code signature error 4 for file \"NoType\"`"
  - "`codesign --verify --deep --strict`, notarization, stapling and `spctl --assess` ALL pass on the same bundle"
root_cause: config_error
resolution_type: code_fix
tags:
  - codesigning
  - entitlements
  - amfi
  - keychain
  - release
related_components:
  - release-script
  - sparkle
---

# Restricted entitlement without a provisioning profile → AMFI SIGKILLs the app before main()

## Problem

NoType v0.1.11 shipped a bundle that **could not launch on any machine**. Users
who auto-updated from 0.1.10 saw the app "crash immediately"; users who
downloaded the DMG got the same. Because a Sparkle-updated app must run in order
to check for updates, **the broken build could not self-heal** — every affected
install needed a manual reinstall.

The bundle was correctly signed with a Developer ID Application certificate,
notarized, stapled, and accepted by Gatekeeper. It still could not execute.

## Symptoms

No crash report exists, which is the first and most misleading clue: the process
is refused at `exec` by the kernel, so it never runs, never faults, and
`ReportCrash` never fires. `~/Library/Logs/DiagnosticReports/` stays empty for
the app and the usual "where's the stack trace" reflex goes nowhere.

The evidence is in the unified log instead:

```
taskgated-helper: Disallowing NoType because no eligible provisioning profiles found
amfid: /Applications/NoType.app/Contents/MacOS/NoType not valid:
       Error Domain=AppleMobileFileIntegrityError Code=-413 "No matching profile found"
AMFI:  When validating /Applications/NoType.app/Contents/MacOS/NoType:
       Code has restricted entitlements, but the validation of its code signature failed.
       Unsatisfied Entitlements:
kernel: mac_vnode_check_signature: ... code signature validation failed fatally
kernel: proc 95036: load code signature error 4 for file "NoType"
ASP:    Security policy would not allow process: 95036, /Applications/NoType.app/Contents/MacOS/NoType
```

Note that `Unsatisfied Entitlements:` prints an **empty list**. It does not name
the offending key — a second reason the message is hard to act on.

Retrieve it with:

```bash
/usr/bin/log show --last 30m --style compact \
  --predicate 'process == "amfid" OR (process == "kernel" AND eventMessage CONTAINS "AMFI")'
```

## Root cause

`keychain-access-groups` is a **restricted** entitlement on macOS. A binary that
declares one is only allowed to execute if the bundle also embeds a provisioning
profile authorising it, at `Contents/embedded.provisionprofile`. NoType's bundle
had no profile.

The chain:

1. PR #70 (2026-06-01) migrated the Gemini API key to the data-protection
   keychain, which requires `keychain-access-groups` — added to
   `NoType/NoType.entitlements`.
2. `xcodebuild archive` then failed with `"NoType" requires a provisioning
   profile`. **This error was correct**; it was read as Xcode being obstructive.
3. PR #73 tried clearing `PROVISIONING_PROFILE_SPECIFIER`. Still failed.
4. PR #75 removed Xcode from the signing path entirely: archive with
   `CODE_SIGNING_ALLOWED=NO`, `ditto` the bundle out, then hand-`codesign` it
   with `--entitlements NoType/NoType.entitlements`. The profile requirement was
   bypassed rather than satisfied, on the stated premise that *"a non-sandboxed
   macOS Developer ID app needs no provisioning profile for this entitlement —
   the Team-ID-prefixed access group is authorized by the Developer ID signature
   directly."* **That premise is false.**
5. v0.1.11 was the first release carrying the entitlement (0.1.10 shipped
   2026-05-29, three days before PR #70 landed on 2026-06-01), so the breakage
   appeared exactly at that version and not before.

**Only an *embedded* profile counts.** Verified empirically on 2026-07-25: a
probe bundle claiming `app.notype`, signed with the Developer ID identity and
the restricted entitlement, was SIGKILLed even with a provisioning profile
granting `49T6U8DQXZ.*` present in *both* machine profile stores
(`~/Library/Developer/Xcode/UserData/Provisioning Profiles` and
`~/Library/MobileDevice/Provisioning Profiles`). The identical bundle with that
profile copied to `Contents/embedded.provisionprofile` ran (rc=0). Installing a
profile on the build machine therefore does **not** satisfy AMFI and cannot mask
a missing embedded profile — which is also why the release gate below stays
honest once the portal work lands.

## What didn't work

- **Clearing the provisioning-profile specifier** (PR #73). The build system
  demands the profile because the entitlement needs one, not because a setting
  named it.
- **Bypassing Xcode's signing entirely** (PR #75). This removed the *error*
  without removing the *requirement*, converting a loud build failure into a
  silent runtime brick — strictly worse.
- **Trusting the static verification chain.** PR #75 validated with
  `codesign --verify --deep --strict`, a designated-requirement check, an
  entitlements dump, and `spctl --assess`. All four passed on the broken bundle,
  and all four still pass on it today. **None of them evaluate restricted
  entitlements** — AMFI does that, and only at `exec`.

## Solution

Two independent changes:

**1. Remove the restricted entitlement** (`NoType/NoType.entitlements`) and move
the Gemini key back to the legacy file keychain. `KeychainStore.productionStore`
is now the single switch that selects the backend, and
`KeychainStore.migrationSourceStore` derives the other one so
`SecretStore.migrateAndResolve` migrates in whichever direction is current. This
reinstates the cert-rotation bug PR #70 fixed — an accepted, tracked regression
(see Related), because a key that occasionally needs re-pasting beats an app
that cannot start.

**2. Gate the release on an actual `exec`** (`scripts/release.sh`). After
signing and before notarization, the script builds a do-nothing binary inside a
minimal `.app`, signs it with the **same identity, the same entitlements file
and the same embedded-profile state** as the real bundle, and runs it. If the
kernel kills it, the release aborts with the diagnosis. Verified against both
inputs:

```
v0.1.11 entitlements (with keychain-access-groups) → GATE FAILS (rc=137)
fixed entitlements (this branch)                   → GATE PASSES
```

## Why this works

AMFI's restricted-entitlement check is a property of *executing* a signature,
not of *validating* one. Any gate built from `codesign`/`spctl`/`notarytool` is
structurally blind to it. Signing a throwaway binary with the identical
entitlement + profile inputs reproduces the kernel's decision exactly, without
launching the real app (which would install a CGEventTap, open the microphone
and show a menu-bar item on the maintainer's Mac mid-release).

Mirroring the bundle id (`app.notype`) in the probe matters: a provisioning
profile only satisfies AMFI for the App ID it was issued for, so a probe with a
different id would fail even on a correctly-profiled build.

## Prevention

- **`scripts/release.sh` — AMFI gate.** Authoritative for the shipped artefact;
  runs before notarization so a bad build costs seconds, not a notary round-trip.
- **`NoTypeTests/KeychainStoreTests`** — `test_restrictedEntitlement_requiresEmbeddedProvisioningProfile`
  (declared restricted entitlement ⇒ `embedded.provisionprofile` exists) and
  `test_restrictedEntitlement_presentIffDataProtectionIsProduction` (no orphaned
  entitlement, no store flip without one). Fast local half; the release gate is
  the half that covers the Release artefact, which Xcode does not sign.
- **`NoType/NoType.entitlements`** carries a comment stating the rule at the one
  place someone would add the next restricted entitlement.
- **Rule of thumb:** when Xcode says a build *requires a provisioning profile*,
  that is a statement about the entitlements, not a build-system quirk. Satisfy
  it or drop the entitlement — never route around it.

## Related Issues

- `docs/solutions/documentation-gaps/developer-id-provisioning-profile-2026-07-25.md`
  — the tracked path back to the data-protection keychain (portal work).
- `docs/solutions/documentation-gaps/keychain-data-protection-migration-2026-05-30.md`
  — the migration this reverts, and the cert-rotation bug it was fixing.
- `NoType/Keychain/CLAUDE.md` — current storage contract.
- PRs #70 (entitlement added), #73 (specifier cleared), #75 (signing bypassed).
