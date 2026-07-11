---
slug: keychain-data-protection-migration
created: 2026-05-30
status: closed
size: L
category: documentation-gaps
---

# Move the Gemini key to the data-protection keychain (survive re-sign, never prompt)

> **Resolved — shipped in #70 (commit `de230d7`).** U1–U5 landed: the
> `keychain-access-groups` entitlement, `KeychainStore` data-protection
> migration (`Store` param), `SecretStore.migrateAndResolve` chained
> migration + `KeyResolution` tri-state, the calm "re-enter your key" UX
> (`ReenterKeyNote` + `AppState.apiKeyNeedsReentry`), and the doc updates. 18
> unit tests green (`KeychainStoreTests` / `SecretStoreTests` /
> `AppStateKeyStateTests`). The steady state — access-group-scoped
> data-protection storage that survives re-sign and never prompts — is now
> documented in `NoType/Keychain/CLAUDE.md`; this file stays for institutional
> memory (what was tried, what was rejected, what shipped). Two follow-ups
> from the notarized-Developer-ID verification (spike step 3 / **S3**): (a)
> the new entitlement makes `xcodebuild archive` / `-exportArchive` demand a
> provisioning profile, resolved in the release pipeline by archiving unsigned
> + manually code-signing the Developer ID app inside-out (see
> `scripts/release.sh`); (b) legacy↔data-protection keychain isolation is
> **asymmetric** (an unscoped legacy query surfaces data-protection items),
> which is why the migration never deletes the legacy keychain item — pinned
> by `KeychainStoreTests` and documented in `NoType/Keychain/CLAUDE.md`.

## Context

The Gemini API key lives in the **legacy file-based** macOS keychain via
`KeychainStore` (`kSecClassGenericPassword`, `service = "app.notype.gemini"`,
`account = "default"`, `kSecAttrAccessibleAfterFirstUnlock`). Two failure
modes have been observed in practice, both rooted in the same mechanism.

**Failure 1 — the key "disappears".** Confirmed incident, 2026-05-30
(`subsystem == "app.notype"`):

```
E  NoType[91211] [app.notype:keychain] SecItemCopyMatching failed: -25293
E  NoType[91211] [app.notype:secret]   keychain read failed, falling through to legacy file: … (-25293)
```

`-25293` = `errSecAuthFailed`. The key was **still in the keychain** the
whole time (CLI `security find-generic-password -s app.notype.gemini`
returned the value; item `cdat` 2026-05-11, `mdat` 2026-05-19). What broke
is **read authorization**, not the data:

1. `SecItemCopyMatching` → `errSecAuthFailed` (current build's signature no
   longer satisfies the item's ACL).
2. `KeychainStore.load()` throws → `SecretStore`'s key-load chain falls
   through to the legacy `settings.json`.
3. That file was deleted after the original one-shot migration → returns
   `nil` → the app renders an empty key field as if the user never set one.

**Failure 2 — the login-password prompt.** Intermittently, reading the key
on launch popped the macOS *"NoType wants to use your confidential
information stored in … in your keychain — enter your login password"*
dialog. Same root cause, interactive variant: when the keychain decides the
caller's signature doesn't cleanly satisfy the item's ACL / partition list,
it **prompts** instead of failing (interactive session) or **fails with
`errSecAuthFailed`** (background / no UI session — an `LSUIElement` app on a
cold path). Users read that prompt as the app being broken or malware.

**Root cause.** A legacy file-keychain item's ACL (trusted-application list
+ partition list) is captured **at item creation** and pinned to the
creating build's **code-signing identity**. Dev builds are signed with an
**Apple Development** certificate (`Apple Development: Alexandr Kopachev
(869MW63B86)` on the currently-installed bundle), and Apple Development
certs **rotate** — Xcode regenerates them on cert expiry, "revoke &
regenerate", a new Mac, or automatic-signing churn. When the leaf cert
changes, later builds no longer match the May-11 ACL → prompt or
`errSecAuthFailed`.

The "stable designated requirement ⇒ silent keychain access across
rebuilds" guarantee documented in `NoType/Keychain/CLAUDE.md` ("Why this
works silently") and in
`solutions/tooling-decisions/byok-keychain-storage-2026-05-15.md` ("Why This
Matters" #4) **only actually holds for the stable Developer ID *release*
cert.** It does **not** survive Apple Development dev-cert rotation, and even
on Developer ID the legacy keychain's *partition list* can still trigger the
interactive prompt. That assumption is the bug.

## Guidance

Migrate the Gemini key to the **data-protection keychain**
(`kSecUseDataProtectionKeychain: true`) and gate access by **keychain access
group** instead of a per-cert trusted-application ACL. Three hard
requirements drive this, in priority order:

- **R1 — readable for every user.** Access must survive re-signing,
  dev-cert rotation, and OS updates. As long as Team ID + bundle id +
  entitlement are stable, the item stays readable.
- **R2 — saves correctly.** Write must land in the access-group-scoped
  store, upsert cleanly, and be immediately readable back by the same build.
- **R3 — never prompt for the computer/login password.** Neither read nor
  write may ever surface the macOS login-password dialog. This is the
  scary-to-users symptom and is non-negotiable.

Data-protection keychain items are scoped by an **access group** derived
from the app's entitlements (`application-identifier` /
`keychain-access-groups`), e.g. `49T6U8DQXZ.app.notype` =
`$(AppIdentifierPrefix)app.notype`. Access is granted to any process whose
**entitlements** put it in the group — that's Team-ID + app-id, *not* the
rotating leaf cert. And the data-protection store does **not** use the
user-interactive ACL mechanism, so it never shows the login-password prompt
for the app's own group. R1 + R3 fall out of the architecture; R2 is a
straight upsert.

Concrete work:

1. **Entitlement.** NoType is **not sandboxed**, so the data-protection
   keychain needs an **explicit** `keychain-access-groups` entitlement
   (sandboxed apps get it implicitly). Add an entitlements plist with
   `keychain-access-groups = ["$(AppIdentifierPrefix)app.notype"]` (plus
   `application-identifier` / `com.apple.application-identifier` as the
   provisioning requires) and wire it via `CODE_SIGN_ENTITLEMENTS` in
   `project.yml`. **Verify the notarized Developer ID release build still
   validates with the entitlement** — Developer ID has no provisioning
   profile, but a team-prefixed `keychain-access-groups` is allowed because
   the prefix matches the signing Team ID. This is the highest-risk step;
   smoke it on a real notarized build before shipping.
2. **`KeychainStore`.** Add `kSecUseDataProtectionKeychain: true` (and
   `kSecAttrAccessGroup`) to all three queries (`save` / `load` / `delete`).
   Keep `kSecAttrAccessibleAfterFirstUnlock` (valid in both stores;
   preserves the "no re-entry after FileVault auto-login" behaviour from
   invariant 2).
3. **Migration (chained, one-shot).** On first launch of a data-protection
   build, `SecretStore.migrateAndResolve()` resolves in order:
   1. Data-protection item present → use it (steady state).
   2. Else best-effort read the **legacy file-keychain** item (omit the
      flag). If it returns a value → write into the data-protection store
      and return it. *Most* users migrate transparently here. (As shipped,
      the legacy keychain item is **not** deleted — an asymmetric-isolation
      hazard, see the status block — and a delete tombstone prevents
      resurrection.)
   3. Else the existing `settings.json` legacy-file path (kept as the
      third source).
   4. Else `nil`.
   - **Accepted limitation:** users already in Failure 1 (legacy read =
     `errSecAuthFailed`) **cannot be recovered programmatically** — the
     value is unreadable by definition. They re-paste **once**; after that
     the data-protection item is stable forever. Document this in the
     release notes and surface a one-time "re-enter your key" path, not a
     scary error.
4. **Tests.** Write the long-overdue `NoTypeTests/KeychainStoreTests.swift`
   (already tracked as missing in `Keychain/CLAUDE.md`): round-trip under
   the data-protection store with a per-test UUID-suffixed service + access
   group; idempotent delete; upsert-returns-second-value; and a migration
   test (seed a legacy item → assert it lands in the data-protection store
   and reads back).

## Why This Matters

- **Silent data loss from the user's POV.** The key isn't gone, but the app
  acts like it is — dropping the user back into onboarding and a re-paste,
  with no explanation. For a menu-bar dictation tool that's a "the app
  broke" moment.
- **The password prompt reads as malware.** A background utility popping
  *"enter your login password to access your keychain"* on launch is exactly
  the pattern users are trained to distrust. It actively erodes confidence
  in an OSS app whose whole pitch is "your key never leaves your device."
- **It will recur on a fixed cadence.** This isn't a one-off — every Apple
  Development cert rotation re-triggers it for dev/internal users, and
  partition-list quirks can hit Developer ID users too. The current
  "fall through to legacy file" recovery is dead (the file is deleted post-
  migration), so there's no safety net left.
- **It contradicts shipped docs.** Two solution docs and a module CLAUDE.md
  assert keychain access is silent and rebuild-stable. Until this lands,
  those need a caveat; once it lands, they get rewritten to the
  access-group model.

## When to Apply

- **Do it before the next public beta bump** — every released build that a
  user keeps installed across a cert rotation is a latent Failure-1/2.
- Whenever the signing identity, Team ID, or entitlements are being touched
  anyway (piggyback the entitlement change).
- If a user reports either symptom (empty key field after an update, or a
  login-password prompt on launch), this is the fix — not a re-paste
  band-aid.

## Examples

**Immediate manual recovery (until the fix ships).** The stale ACL rejects
`SecItemUpdate` too, so the app can't overwrite in place — delete the stale
item, then re-enter the key so a fresh `SecItemAdd` rebinds the ACL to the
current build:

```bash
security delete-generic-password -s "app.notype.gemini"
# then paste the key again in Settings → API & Usage
```

This recovers *this* cert generation only; it breaks again on the next
rotation. The data-protection migration is what makes it durable.

**Query shape after the fix** (all three of `save`/`load`/`delete`):

```swift
let query: [String: Any] = [
    kSecClass as String:                 kSecClassGenericPassword,
    kSecAttrService as String:           service,
    kSecAttrAccount as String:           account,
    kSecAttrAccessGroup as String:       "49T6U8DQXZ.app.notype",
    kSecUseDataProtectionKeychain as String: true,   // ← the load-bearing flag
    // load adds: kSecReturnData, kSecMatchLimit
]
```

**Rejected / partial alternatives:**

- **Set an explicit `SecAccess` on the legacy item using the designated
  requirement** (`SecAccessCreate` + `SecRequirementCreateWithString` for
  `identifier "app.notype"`). Possible, but the `SecAccess` API is
  legacy/fiddly, it stays in the file-keychain (partition-list prompts can
  still fire → fails R3), and it has to be re-applied on every write. The
  data-protection keychain solves R1+R3 by construction instead of patching
  the ACL.
- **Re-create the item on each `errSecAuthFailed`.** Effectively the current
  behaviour — but the value can't be read back when auth fails, so it forces
  a re-paste every rotation. Fails R1.
- **Sign dev builds with Developer ID instead of Apple Development.** Lowers
  the rotation frequency but doesn't address partition-list prompts (R3) and
  is an unusual Debug-signing setup. Partial mitigation, not the fix.
- **`kSecAttrAccessControl` with `.userPresence` / biometrics.** Wrong
  direction — that *adds* a prompt. Explicitly violates R3.

## Related

- **Closed by #70** (commit `de230d7` — "migrate Gemini key to the
  data-protection keychain (survive re-sign, never prompt)"). The
  release-signing follow-up (archive unsigned + manual Developer ID codesign
  for the new `keychain-access-groups` entitlement) lives in
  `scripts/release.sh`.
- `NoType/Keychain/KeychainStore.swift` — the three `SecItem*` queries to
  migrate; current `load()` throws `errSecAuthFailed` on cert mismatch.
- `NoType/Keychain/SecretStore.swift` — `migrateAndResolve()` fall-through
  chain (+ `currentKeyResolution()` env wrapper, `deliberatelyCleared` tombstone).
- `NoType/Keychain/CLAUDE.md` — "Why this works silently" + invariant 1/2;
  rewritten to the access-group / data-protection model when #70 shipped.
- `solutions/tooling-decisions/byok-keychain-storage-2026-05-15.md` — "Why
  This Matters" #4 makes the rebuild-stable claim that this entry qualifies.
- `project.yml` — `DEVELOPMENT_TEAM = 49T6U8DQXZ`, `CODE_SIGN_ENTITLEMENTS`
  wiring for the new entitlements plist.
- Apple TN3137 "On Mac keychain APIs and implementations" + WWDC "Using the
  keychain to manage user secrets" — rationale for preferring the
  data-protection keychain on macOS.
- Incident log: `subsystem == "app.notype"`, categories `keychain` /
  `secret`, 2026-05-30 (`SecItemCopyMatching failed: -25293`).
