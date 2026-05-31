---
title: "fix: Move Gemini key to the data-protection keychain (survive re-sign, never prompt)"
date: 2026-05-30
type: fix
status: active
depth: deep
module: Keychain
related:
  - docs/solutions/documentation-gaps/keychain-data-protection-migration-2026-05-30.md
  - docs/solutions/tooling-decisions/byok-keychain-storage-2026-05-15.md
  - NoType/Keychain/CLAUDE.md
---

# fix: Move Gemini key to the data-protection keychain (survive re-sign, never prompt)

## Summary

The Gemini API key lives in the **legacy file-based** macOS keychain. Its
ACL is captured at item-creation time and pinned to the *creating build's
code-signing identity*. NoType's dev builds are signed with a rotating
**Apple Development** certificate, so when that cert rotates the installed
app's signature no longer satisfies the ACL — reading the key either pops
the macOS **login-password prompt** (interactive) or fails with
**`errSecAuthFailed` (-25293)** (background / `LSUIElement` cold path). The
key is intact in the keychain; the app just can't read it and renders an
empty key field as if the user never set one.

This plan migrates the key to the **data-protection keychain**
(`kSecUseDataProtectionKeychain`), which scopes access by a Team-ID-derived
**keychain access group** (entitlement) instead of a per-cert
trusted-application ACL. Access then survives re-signing and cert rotation,
and the data-protection store never shows the login-password prompt for the
app's own group. Plus a calm one-time "re-enter your key" surface for users
already stranded by the bug, and corrections to the docs that assert the old
(now-falsified) "stable DR ⇒ silent access across rebuilds" guarantee.

Origin: `docs/solutions/documentation-gaps/keychain-data-protection-migration-2026-05-30.md`
(written this session from a confirmed 2026-05-30 incident — `SecItemCopyMatching failed: -25293`).

---

## Problem Frame

Two observed failure modes, one root cause:

- **Failure 1 — key "disappears".** `KeychainStore.load()` →
  `errSecAuthFailed` → `SecretStore.loadGeminiKey()` falls through to the
  legacy `settings.json` (deleted after the original migration) → `nil` →
  empty key field / onboarding.
- **Failure 2 — login-password prompt.** Same ACL mismatch, interactive
  variant — the macOS *"NoType wants to use your confidential information…
  enter your login password"* dialog. Reads as malware to users.

Root cause: legacy file-keychain ACL is bound to the rotating Apple
Development leaf cert, not to the stable designated requirement
(`identifier "app.notype"`). The "stable DR ⇒ silent access" guarantee in
`NoType/Keychain/CLAUDE.md` and the BYOK solution doc only truly holds for
the stable **Developer ID release** cert — and even there the legacy
keychain's *partition list* can still trigger the prompt.

---

## Requirements Traceability

Carried verbatim from the origin tech-debt doc (the acceptance bar):

- **R1 — readable for every user.** Access survives re-signing, dev-cert
  rotation, and OS updates. Stable as long as Team ID + bundle id +
  entitlement are stable. (see origin: `docs/solutions/documentation-gaps/keychain-data-protection-migration-2026-05-30.md`)
- **R2 — saves correctly.** Write lands in the access-group-scoped store,
  upserts cleanly, and is immediately readable back by the same build.
- **R3 — never prompt for the computer/login password.** Neither read nor
  write may surface the macOS login-password dialog. Non-negotiable; this is
  the scary-to-users symptom.

Plan-local success criteria:

- **S1.** A binary re-signed with a *different* code-signing identity (same
  Team ID + entitlement) reads the key with no prompt and no `errSecAuthFailed`.
- **S2.** Existing users migrate transparently where their legacy item is
  still readable; stranded users (legacy read throws) get a calm one-time
  re-entry, not a silent reset.
- **S3.** The notarized Developer ID *release* build reads an access-group
  item with no prompt (the highest-risk unknown — gated in U1).

---

## Key Technical Decisions

1. **Data-protection keychain over patching the legacy ACL.** Adding
   `kSecUseDataProtectionKeychain: true` + `kSecAttrAccessGroup` makes access
   entitlement-gated (Team-ID + app-id), immune to leaf-cert rotation, and
   prompt-free by construction. Rejected: re-applying a `SecAccess` built
   from the designated requirement on the legacy item — legacy/fiddly API,
   stays in the file-keychain (partition-list prompts can still fire → fails
   R3), must be re-applied on every write. (see origin doc "Rejected /
   partial alternatives")
2. **Access group = `$(AppIdentifierPrefix)app.notype`** → expands to
   `49T6U8DQXZ.app.notype` at sign time. Added to the existing
   `NoType/NoType.entitlements` (no new file). NoType is **not sandboxed**,
   so the entitlement must be explicit (sandboxed apps get it implicitly).
3. **Keep `kSecAttrAccessibleAfterFirstUnlock`.** Valid in both stores;
   preserves "no re-entry after FileVault auto-login" (Keychain invariant 2).
4. **The data-protection flag is a *parameter* on `KeychainStore`, not a
   hardcode.** The one-shot migration (U3) and the `PromptEvalHarness`
   test-key path both need to read the *legacy* keychain. Methods take a
   storage mode (default = data-protection production group); legacy reads
   pass the legacy mode. Without this, U2 silently breaks the eval harness,
   which reads `app.notype.tests.gemini` via `KeychainStore.load()`.
5. **Chained one-shot migration, lossy-by-necessity for stranded users.**
   Resolution order: data-protection item → legacy file-keychain → legacy
   `settings.json` → (stranded vs first-run). Users whose legacy keychain
   read throws `errSecAuthFailed` **cannot** be recovered programmatically
   (the value is unreadable by definition) → one-time re-paste, surfaced
   calmly. Accepted limitation, documented in release notes.
6. **Surface a tri-state key status**, not a bare `String?`. `SecretStore`
   distinguishes *present* / *needs-reentry (stranded)* / *absent (first
   run)* so the UI can tell "your key needs re-entering once" apart from
   "add your first key" — the difference between a calm note and a scary reset.

---

## High-Level Technical Design

*Directional guidance for review, not implementation specification. The
implementing agent should treat it as context, not code to reproduce.*

Key-resolution chain after the change (`SecretStore`):

```
loadKey():
  if env NOTYPE_GEMINI_KEY present            -> .present(env)        // wins, never persisted
  if data-protection item present             -> .present(value)      // steady state
  else read legacy file-keychain (legacy mode):
      success(value)                          -> migrate→DP, delete legacy(best-effort), .present(value)
      throw errSecAuthFailed / auth error     -> remember "stranded"
  if settings.json present                    -> migrate→DP, remove file, .present(value)
  if stranded                                 -> .needsReentry        // calm "paste once" UX
  else                                        -> .absent              // genuine first run
```

Access-group model (why R1/R3 hold):

```
legacy file-keychain:   ACL ── trusted-app list ── pinned to leaf cert (rotates) ──► prompt / errSecAuthFailed
data-protection store:  access group ── "49T6U8DQXZ.app.notype" (entitlement) ──► stable across cert rotation, no prompt
```

---

## System-Wide Impact

| Surface | Impact |
|---|---|
| Code signing / entitlements | New `keychain-access-groups` entitlement; must validate on **Debug (Apple Development)** *and* **notarized Developer ID release** builds |
| `NoType/Keychain/` | `KeychainStore` queries gain storage-mode params; `SecretStore` load chain + tri-state result |
| `NoType/AppState.swift` | `currentAPIKey` / key-status derivation consumes the tri-state |
| Settings + Onboarding | "Re-enter key" calm surface in `GeminiKeyRow` + `OnboardingAPIKeyStep` |
| Tests | New `KeychainStoreTests.swift`; `PromptEvalHarness` legacy-read path preserved; `Fixtures/README.md` setup note |
| Docs | `Keychain/CLAUDE.md`, BYOK solution doc, tech-debt entry closed |

---

## Implementation Units

### U1. Add the keychain access-group entitlement and gate the approach with a signing spike

**Goal:** Add `keychain-access-groups` to the app entitlements and *prove*
the access-group keychain works on the two signing identities that matter —
especially the notarized Developer ID release build (no provisioning
profile). This unit is a **hard gate**: if the Developer ID build can't read
an access-group item, STOP and revisit the approach before building anything
on top.

**Requirements:** R1, R3, S3.

**Dependencies:** none (first).

**Files:**
- `NoType/NoType.entitlements` (add `keychain-access-groups`; possibly
  `com.apple.application-identifier`)
- `project.yml` (no structural change expected — `CODE_SIGN_ENTITLEMENTS`
  already points at the file; add a clarifying comment if the App ID needs
  the Keychain Sharing capability for automatic Debug signing)

**Approach:**
- Add `keychain-access-groups = ["$(AppIdentifierPrefix)app.notype"]` to the
  existing entitlements plist (Xcode expands `$(AppIdentifierPrefix)` →
  `49T6U8DQXZ.` at sign time).
- Confirm whether automatic Debug signing (Apple Development) needs the App
  ID's *Keychain Sharing* capability registered on the developer portal; for
  Developer ID distribution the team-prefixed group is self-asserted (no
  profile) — verify it still notarizes with hardened runtime on.
- **Spike protocol (manual):**
  1. Debug build → write + read a throwaway item in the access group → no prompt.
  2. Re-sign the built bundle with a *different* identity (same Team ID) →
     read again → must succeed with no prompt (simulates cert rotation; this
     is the R1 proof the legacy store fails today).
  3. Run `scripts/release.sh` to produce a notarized Developer ID build →
     read an access-group item on it → **no prompt, no `errSecAuthFailed`**
     (S3). This is the make-or-break check.

**Patterns to follow:** existing `OTHER_CODE_SIGN_FLAGS` DR-pinning in
`project.yml`; the build/notarize flow in `docs/build.md` (do NOT run
`release.sh` from an agent — hand the notarized-build spike to the maintainer).

**Execution note:** Gate. Do not proceed to U2+ until step 3 passes. If it
fails, fall back per Risk R-1 mitigation and re-plan.

**Test scenarios:** `Test expectation: none — entitlement + manual signing
spike. Verification is the three-step protocol above, run by the maintainer
on real signed/notarized builds (unit tests can't exercise notarization).`

**Verification:** All three spike steps pass; notarization succeeds with the
new entitlement; `codesign -d --entitlements - /Applications/NoType.app`
shows the access group.

---

### U2. Migrate `KeychainStore` to the data-protection keychain (storage-mode parameterized)

**Goal:** Route `save` / `load` / `delete` through the data-protection
keychain with the production access group by default, while keeping a
legacy-keychain read mode for migration (U3) and the eval harness.

**Requirements:** R1, R2, R3, S1.

**Dependencies:** U1.

**Files:**
- `NoType/Keychain/KeychainStore.swift`
- `NoTypeTests/KeychainStoreTests.swift` (new — closes the long-standing
  test gap noted in `Keychain/CLAUDE.md`)

**Approach:**
- Add `kSecUseDataProtectionKeychain: true` + `kSecAttrAccessGroup:
  "49T6U8DQXZ.app.notype"` to all three queries.
- Introduce a storage-mode parameter (e.g. `Store.dataProtection` (default)
  / `Store.legacyFile`) so callers can target the legacy keychain without
  the flag/group — required by U3's migration read and by
  `PromptEvalHarness`. Default keeps production on data-protection.
- Preserve `kSecAttrAccessibleAfterFirstUnlock`, the upsert semantics
  (`SecItemUpdate` → `errSecItemNotFound` → `SecItemAdd`), idempotent delete,
  and the `malformedItem` contract.
- **Do not hardcode** the access-group string in scattered places — single
  source of truth (constant) so it stays in lockstep with the entitlement.

**Patterns to follow:** current `KeychainStore` query shape + error model;
keep the existing `KeychainError` cases.

**Execution note:** Test-first for the round-trip + store-isolation
contract — this is the security boundary; lock behavior before refactoring
the queries.

**Test scenarios:** (`NoTypeTests/KeychainStoreTests.swift`)
- Round-trip: `save`→`load`→equal under data-protection store, using a
  **UUID-suffixed service** within the production access group (the group is
  fixed by entitlement; only the service can vary for isolation).
- `delete`→`load`→`nil`.
- Upsert: `save` twice with different values → `load` returns the second.
- Idempotent delete on a missing item → no throw.
- **Store isolation:** an item written via `legacyFile` mode is **not**
  visible to a `dataProtection` `load` (and vice versa) — proves U3's
  migration reads the right store and that U2 doesn't accidentally read
  production from legacy.
- Malformed item (non-UTF-8 data) → throws `malformedItem`.

**Verification:** New tests pass; a key saved by this build reads back with
no prompt; re-signed-binary read (carried by U1's spike) succeeds.

---

### U3. `SecretStore` chained migration + tri-state key status

**Goal:** Resolve the key through data-protection → legacy file-keychain →
`settings.json`, migrating into the data-protection store on the way, and
return a tri-state (`present` / `needsReentry` / `absent`) so the UI can
distinguish a stranded user from a first-run user.

**Requirements:** R1, R2, S2; supports R3 (no prompt on any branch).

**Dependencies:** U2.

**Files:**
- `NoType/Keychain/SecretStore.swift`
- `NoTypeTests/KeychainStoreTests.swift` (extend with `SecretStore`
  migration cases) or a sibling `SecretStoreTests.swift`

**Approach:**
- Replace the current "Keychain → legacy file → nil" chain with the U-design
  resolution order. The legacy file-keychain read uses U2's `legacyFile`
  mode; an `errSecAuthFailed` there marks **stranded** rather than collapsing
  to `nil`.
- On a successful legacy-keychain or `settings.json` read, write into the
  data-protection store and best-effort delete/remove the legacy source
  (don't attempt to delete an item we couldn't read — the stranded case
  never reaches delete).
- Return a tri-state result. Keep `loadFromEnvOrFile()`'s env precedence
  (env wins, never persisted). Map `present(env)`/`present(value)` for
  callers that still want a bare `String?`.
- Migration write failure → return the migrated value, leave the legacy
  source intact for next-launch retry (preserve current resilience).

**Execution note:** Characterization/test-first for the resolution chain —
fiddly, security-sensitive, and the stranded/first-run distinction is easy
to get subtly wrong.

**Test scenarios:** (seed each store/file state with a temp service + temp
App Support dir)
- DP item present → returned directly; legacy sources untouched.
- DP empty + legacy keychain has key → migrated into DP, legacy item
  best-effort deleted, value returned as `present`.
- DP empty + legacy keychain empty + `settings.json` has key → migrated,
  file removed, `present`.
- DP empty + legacy keychain read throws `errSecAuthFailed` + no
  `settings.json` → `needsReentry` (NOT `absent`).
- All sources empty → `absent` (genuine first run).
- `NOTYPE_GEMINI_KEY` set → `present(env)`, wins over all stores, nothing
  written to any keychain.
- Migration write fails → returns migrated value AND leaves the legacy
  source on disk/keychain for retry.

**Verification:** Tests pass; on a machine with the real stranded item, the
app reports `needsReentry` (not a blank first-run), and after one re-entry it
reads from the data-protection store on every subsequent launch.

---

### U4. "Re-enter your key" calm surface (Settings + Onboarding)

**Goal:** When the key status is `needsReentry`, show a short, non-alarming
explanation ("macOS changed this app's signature — paste your key once and it
will stick") in both key-entry surfaces, instead of treating the user as
brand-new. First-run users (`absent`) keep the normal copy.

**Requirements:** R-adjacent (S2 user-facing half).

**Dependencies:** U3.

**Files:**
- `NoType/AppState.swift` (derive/expose the tri-state to the UI)
- `NoType/UI/Settings/GeminiKeyRow.swift`
- `NoType/Onboarding/Steps/OnboardingAPIKeyStep.swift`

**Approach:**
- `AppState` exposes an observable key-status mirror derived from U3's
  tri-state (replacing the bare lazy `cachedAPIKey` gate where the UI needs
  the distinction). `currentAPIKey: String?` stays for call sites that only
  need the value.
- `GeminiKeyRow` and `OnboardingAPIKeyStep` render the calm note only in the
  `needsReentry` state; on successful `updateAPIKey`, status flips to
  `present` and the note clears.
- Copy is reassuring and specific (signature change, one-time). No error HUD,
  no red state — this is expected maintenance, not a failure.

**Patterns to follow:** existing `.missingKey` handling in `GeminiKeyRow`
(line ~110) and `OnboardingAPIKeyStep` (line ~338); existing masked-key
display (`AIzaSy••••••••`) for the post-fix state. Use `DesignTokens` /
`DSComponents` per `NoType/UI/CLAUDE.md` — no inlined colors.

**Execution note:** UI rendering follows the repo's "no UI unit tests;
manual smoke" convention — unit-test the *state derivation* in `AppState`,
smoke the rendering.

**Test scenarios:**
- AppState state derivation: U3 `present` → `.present`; `needsReentry` →
  `.needsReentry`; `absent` → `.absent`.
- After `updateAPIKey(validKey)` from a `needsReentry` state → status →
  `.present` (note should clear).
- `Test expectation (UI render): none — manual smoke per UI convention.`
  Smoke: trigger the stranded state (delete the DP item, leave an
  unreadable legacy item) → Settings + onboarding show the calm note, not the
  generic first-run copy; paste key → note clears.

**Verification:** Manual smoke in both surfaces; state-derivation tests pass;
new users still see first-run copy (no false "re-enter" note).

---

### U5. Update the docs that assert the falsified guarantee

**Goal:** Correct the "stable DR ⇒ silent keychain access across rebuilds"
claims to the access-group model, and close the tech-debt entry.

**Requirements:** documentation integrity (origin doc "Related").

**Dependencies:** U2, U3 (docs describe shipped behavior).

**Files:**
- `NoType/Keychain/CLAUDE.md` ("Why this works silently" + invariants 1/2 +
  the "If you suddenly see Keychain password prompts" troubleshooting block)
- `docs/solutions/tooling-decisions/byok-keychain-storage-2026-05-15.md`
  ("Why This Matters" #4)
- `docs/solutions/documentation-gaps/keychain-data-protection-migration-2026-05-30.md`
  (move guidance from "leave as-is" to "done in PR #N"; keep the institutional
  memory)
- `docs/TECHDEBT.md` (remove the "Current entries" line)
- `NoTypeTests/Fixtures/README.md` (eval-key setup note — see U2's
  storage-mode split; the test key path and whether it stays legacy)

**Approach:** Rewrite the silent-access rationale around the data-protection
access group (entitlement-scoped, cert-rotation-immune, prompt-free). Add the
"Developer ID only; dev-cert rotation broke the legacy ACL" history as the
*why* behind the migration. Reference the closing PR in the tech-debt file's
`## Related`.

**Patterns to follow:** the tech-debt "Closing an entry" procedure in
`docs/TECHDEBT.md`; per-module CLAUDE.md tone.

**Test scenarios:** `Test expectation: none — documentation. No build
required (Markdown only) per the root CLAUDE.md build hard-rule.`

**Verification:** No doc still asserts the legacy guarantee unqualified;
tech-debt index no longer lists the entry; the entry's body reflects the
shipped fix.

---

## Risk Analysis & Mitigation

| ID | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R-1 | Developer ID notarized build (no provisioning profile) doesn't grant a working access group → entire approach fails R1/R3 | Medium | Critical | **U1 spike gates everything.** If step 3 fails: fall back to (a) `SecAccess`+DR on the legacy item, or (b) embed a provisioning profile for the release build, or (c) accept periodic re-paste + ship only U4's calm UX. Re-plan before U2. |
| R-2 | Existing users' legacy item unreadable → forced one-time re-paste | High (by design) | Low | U4 calm surface + release-note. Acceptable per origin doc; the point is it never breaks *again* after re-entry. |
| R-3 | U2 silently breaks `PromptEvalHarness` (reads `app.notype.tests.gemini` via `KeychainStore.load`) | High if unhandled | Medium | KTD #4 — storage-mode parameter; harness reads legacy mode (or README moves the test key). Pinned by U2's store-isolation test. |
| R-4 | Hosted test bundle can't access the access group → `KeychainStoreTests` can't run | Low | Medium | Tests run dlopen'd inside `NoType.app` (carries the entitlement); use the production group + UUID services. Verify in U2. |
| R-5 | Hardened runtime + new entitlement breaks notarization | Low | High | Part of U1's notarized-build spike before any dependent work. |

---

## Scope Boundaries

**In scope:** data-protection migration (KeychainStore + SecretStore +
entitlement), one-shot chained migration, tri-state status, "re-enter key"
calm UX, `KeychainStoreTests`, doc corrections.

### Deferred to Follow-Up Work
- **iCloud Keychain / cross-device sync** of the key — out of the single-
  account BYOK model; not part of this fix.
- **Broader secret-path audit** (env-var path hardening, `validateKey`
  flow, log-surface review, onboarding re-validation) — the user scoped this
  plan to "Fix + UX + docs", not the wider audit. Revisit separately if
  desired.
- **Multi-account keychain** — explicitly out of scope per ADR-011.

### True Non-Goals
- Storing the key anywhere other than the keychain (UserDefaults, plist,
  Info.plist env) — forbidden by the Keychain hard rules.
- Any telemetry on key state.

---

## Deferred to Implementation (execution-time unknowns)

- Exact entitlement keys needed for automatic Debug signing (whether
  `com.apple.application-identifier` / portal Keychain-Sharing capability is
  required) — resolved empirically in U1.
- Final shape of the storage-mode parameter and the tri-state enum names —
  decide against real code in U2/U3.
- Whether the eval test key moves to the data-protection store or stays
  legacy — decide in U2 once the storage-mode split exists; reflect in
  `Fixtures/README.md` (U5).
- Whether `AppState` needs a new observable property or can reuse the
  existing key-load gate for the tri-state — decide in U4.

---

## Sequencing

```
U1 (gate) ──► U2 ──► U3 ──┬──► U4
                          └──► U5
```

U1 is a hard gate. U4 and U5 both depend on U3 and can land in parallel.

---

## Open Questions

- None blocking. The one make-or-break unknown (R-1 / S3) is converted into
  the U1 verification gate rather than left as an assumption.
