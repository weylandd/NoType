---
title: Embed a Developer ID provisioning profile to restore the data-protection keychain
date: 2026-07-25
category: documentation-gaps
module: Keychain
problem_type: documentation_gap
component: tooling
severity: medium
applies_when:
  - "The Gemini API key disappears or macOS prompts for the login password after a code-signing identity change"
  - "Adding any restricted entitlement to NoType"
tags:
  - keychain
  - codesigning
  - entitlements
  - release
related_components:
  - release-script
---

# Embed a Developer ID provisioning profile to restore the data-protection keychain

**Size: M.** Requires Apple Developer portal access — not a code-only change.

## Context

The data-protection keychain is the correct home for the Gemini API key: access
is gated on the `keychain-access-groups` entitlement (Team ID + bundle id), not
on a trusted-application ACL pinned to the signing leaf certificate, so the key
survives certificate rotation and never triggers the macOS login-password
prompt. That was the whole point of the migration in PR #70.

It was reverted on 2026-07-25 because shipping that entitlement **without an
embedded provisioning profile** made the app unlaunchable — AMFI SIGKILLs the
process before `main()`. See
[`runtime-errors/amfi-restricted-entitlement-launch-kill-2026-07-25.md`](../runtime-errors/amfi-restricted-entitlement-launch-kill-2026-07-25.md)
for the full diagnosis.

So NoType is back on the legacy file keychain and back on the bug PR #70 fixed:
when this Mac's Developer ID certificate rotates, reads can fail with
`errSecAuthFailed (-25293)` or pop the login-password prompt, and the user has
to paste their key once (`SecretStore.KeyResolution.needsReentry` already
handles this calmly). Low frequency, real annoyance.

## Guidance

**Leave it as-is until a certificate rotation actually strands users, or until
someone has portal access to hand.** The current state is correct and safe; the
regression is bounded and already has a graceful UI path.

When picking it up, all four steps must land **together** — any subset
re-bricks the app:

1. **Portal.** developer.apple.com → Certificates, Identifiers & Profiles →
   Identifiers → App ID `app.notype` → enable **Keychain Sharing**. Then
   Profiles → `+` → **Developer ID** (macOS, Distribution) → App ID
   `app.notype` → the Developer ID Application certificate → download the
   `.provisionprofile`.
2. **Repo.** Commit the profile (it contains no private key) or document a
   local path. Note its expiry; a profile that outlives its certificate needs
   regenerating and re-shipping.
3. **`scripts/release.sh`.** Copy it to
   `"${APP_PATH}/Contents/embedded.provisionprofile"` **before** the main-app
   `codesign` call. The AMFI gate already mirrors the real bundle's profile
   state into its probe, so it will start passing on its own — do not weaken
   the gate.
4. **Code.** Re-add `keychain-access-groups` to `NoType/NoType.entitlements`
   and flip `KeychainStore.productionStore` to `.dataProtection`.
   `migrationSourceStore` reverses automatically and
   `SecretStore.migrateAndResolve` then migrates legacy → data-protection with
   no further change. The `KeychainStoreTests` data-protection cases stop
   skipping and become the acceptance suite.

Verify with a real `./scripts/release.sh` run: the AMFI gate must pass, and the
installed build must launch and read back an existing key.

## Why This Matters

Both failure modes are user-visible and neither is self-correcting:

- Getting it wrong in one direction (entitlement, no profile) means the app
  cannot start, and a dead app cannot auto-update — every install needs a manual
  reinstall. That is exactly what v0.1.11 cost.
- Getting it wrong in the other (store flipped, no entitlement) means every
  keychain read fails with `errSecMissingEntitlement` and the key silently never
  persists.

The four steps are cheap; splitting them across PRs is what makes this
dangerous.

## When to Apply

- A certificate rotation strands users on the login-password prompt or
  `errSecAuthFailed`, i.e. the cert-rotation bug bites in the wild.
- Any other restricted entitlement becomes necessary — the profile work is the
  same, and the same four-step rule applies.

## Examples

The two half-migrations the tests now catch:

```swift
// BROKEN — entitlement declared, store not flipped. Dead weight that risks the
// launch kill for no benefit. Caught by
// test_restrictedEntitlement_presentIffDataProtectionIsProduction.
// NoType.entitlements: keychain-access-groups present
static let productionStore: Store = .legacyFile

// BROKEN — store flipped, entitlement missing. Every read is
// errSecMissingEntitlement. Same test.
// NoType.entitlements: keychain-access-groups absent
static let productionStore: Store = .dataProtection
```

And the one the release gate catches, which no unit test can (Xcode's automatic
Debug signing embeds a profile, so a Debug host looks healthy while the
hand-signed Release artefact is dead):

```
NoType.entitlements: keychain-access-groups present
Contents/embedded.provisionprofile: MISSING
→ scripts/release.sh: "AMFI REJECTED the entitlements" (probe rc=137), aborts
  before notarization.
```

## Related

- [`runtime-errors/amfi-restricted-entitlement-launch-kill-2026-07-25.md`](../runtime-errors/amfi-restricted-entitlement-launch-kill-2026-07-25.md)
  — the incident that forced the revert.
- [`documentation-gaps/keychain-data-protection-migration-2026-05-30.md`](keychain-data-protection-migration-2026-05-30.md)
  — the original migration and the cert-rotation bug it targeted.
- [`tooling-decisions/byok-keychain-storage-2026-05-15.md`](../tooling-decisions/byok-keychain-storage-2026-05-15.md)
  — why the key lives in the Keychain at all (ADR-011).
- `NoType/Keychain/CLAUDE.md` — current storage contract.
