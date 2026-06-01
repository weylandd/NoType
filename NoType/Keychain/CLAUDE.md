# Keychain module

Stores the user's Gemini API key in the macOS Keychain. Single-account model — one Gemini key per user; multi-account is out of scope.

## Files

- `KeychainStore.swift` — thin wrapper around `Security.framework`'s `kSecClassGenericPassword` items. Parametrised on a `Store` backend (`.dataProtection` default / `.legacyFile`). Used by `SecretStore` and the eval harness's legacy-key read.
- `SecretStore.swift` — backend-agnostic public API for the rest of the app. Owns the chained one-shot migration (data-protection ← legacy keychain ← legacy `settings.json`) and the `KeyResolution` tri-state.

## Invariants

1. **Production storage is the data-protection keychain.** New writes go to `kSecUseDataProtectionKeychain` items scoped by the access group `49T6U8DQXZ.app.notype` (`KeychainStore.accessGroup`, which **must** match the `keychain-access-groups` entitlement in `NoType/NoType.entitlements`). `service = "app.notype.gemini"`, `account = "default"`, `accessible = kSecAttrAccessibleAfterFirstUnlock`.
2. **Access is entitlement-gated, not cert-gated.** The access group is keyed on Team ID + bundle id (entitlement), so access survives code-signing-identity rotation and never prompts for the login password — see "Why this works silently". This is the fix for the `errSecAuthFailed` / login-password-prompt bug in `docs/solutions/documentation-gaps/keychain-data-protection-migration-2026-05-30.md`.
3. **`AfterFirstUnlock`, not `WhenUnlocked`** — keeps the item readable after FileVault unlock paired with auto-login. Valid in both stores.
4. **`Store.legacyFile` is read-mostly.** It targets the old file-based keychain (no data-protection flag, no access group) and exists only to (a) read pre-migration items during `SecretStore.migrateAndResolve` and (b) let `PromptEvalHarness` read its broad-ACL eval key. New production writes never target it.
5. **`SecretStore` is the only app-facing entry.** `KeychainStore` is module-internal. Swapping the backend (iCloud Keychain, hosted proxy) is a one-file change.
6. **`save` is upsert** — try `SecItemUpdate`; on `errSecItemNotFound` fall back to `SecItemAdd`. `load` returns `nil` when the item doesn't exist (not an error). `delete` is idempotent — `errSecItemNotFound` is treated as success.
7. **`migrateAndResolve` returns a tri-state** `KeyResolution { present / needsReentry / absent }`. A legacy-keychain read that *throws* (the `errSecAuthFailed` cert-rotation bug) → `.needsReentry` (UI shows a calm "paste once" note) — distinct from `.absent` (genuine first run). `loadFromEnvOrFile()` collapses both to `nil` for value-only callers.
8. **`NOTYPE_GEMINI_KEY` env var wins** for `currentKeyResolution` / `loadFromEnvOrFile`. Never persisted into the Keychain — dev-only path.

## Hard rules

- **Never log the key** (even at `.debug`).
- **Never include the key in error messages or telemetry** (we have no telemetry; in case we add it).
- **Never put the key in `UserDefaults`** or any plist file.
- **Never put the key in environment variables in `Info.plist`** or in launch scripts that ship with the app.
- **Service / account parameters are exposed** so tests can use UUID-suffixed services within the production access group (the group is fixed by entitlement — only the service can vary for isolation).
- **`KeychainStore.accessGroup` must equal the entitlement literal.** Change one → change both, or every data-protection read fails with `errSecMissingEntitlement`.
- **Never delete the legacy *keychain* item after migrating.** Legacy↔data-protection isolation is **asymmetric**: an unscoped `.legacyFile` query (no flag, no group) *also* surfaces the entitled app's data-protection item, so a `.legacyFile` delete of the same service can nuke the freshly written data-protection key. The orphaned legacy item is harmless — `migrateAndResolve` reads data-protection first, so it's never consulted again. Pinned by `KeychainStoreTests.test_storeIsolation_legacyQuerySurfacesDataProtectionItem_documentedMacOSBehavior`. (The legacy `settings.json` *file* is safe to delete — it's not a keychain query.)

## Why this works silently on macOS

Two different mechanisms, and the difference is the whole point of the data-protection migration:

- **Data-protection keychain (production, current).** Access is granted to any process whose `keychain-access-groups` entitlement includes the item's access group. The group (`49T6U8DQXZ.app.notype`) is keyed on **Team ID + bundle id** — both stable across rebuilds, re-signing, and Apple Development cert rotation. The data-protection store also does not use the interactive trusted-application ACL mechanism, so it **never** shows the login-password prompt for the app's own group. Stable Team ID + bundle id + entitlement ⇒ silent, durable access.

- **Legacy file keychain (pre-migration — the bug).** A file-keychain item's ACL is captured at creation and bound to the creating build's **code-signing identity** (trusted-application list / partition list). The old "stable designated requirement (`signing/NoType.xcrequirements`) keeps access silent across rebuilds" guarantee held only for cdhash changes under one cert, and only for the stable **Developer ID** release cert. When the **Apple Development** dev cert rotated (Xcode regen, new Mac, expiry), the new signature no longer satisfied the ACL → `errSecAuthFailed (-25293)` (background / `LSUIElement` cold path) or the login-password prompt (interactive). That is exactly what the data-protection migration fixes.

**If you see Keychain password prompts or the key "disappears" on a build:**
1. Confirm `keychain-access-groups` is present in `NoType/NoType.entitlements` and the build is actually signed with it (`codesign -d --entitlements - <app>`); a Debug build needs the "Keychain Sharing" capability on the App ID / a matching provisioning profile.
2. Confirm `KeychainStore.accessGroup` matches the entitlement literal.
3. Confirm `DEVELOPMENT_TEAM` (`49T6U8DQXZ`) and bundle id (`app.notype`) are unchanged.

## Storage backends + migration

`SecretStore.migrateAndResolve` resolves the key in order and migrates whatever it finds into the data-protection store:

1. **Data-protection keychain** → use it (steady state).
2. **Legacy file-keychain** (`.legacyFile`) → migrate into data-protection, return it. If this read *throws* (`errSecAuthFailed`), the value is unrecoverable → `.needsReentry` (one-time paste). We do **not** delete the legacy keychain item (asymmetry hard rule above).
3. **Legacy `settings.json`** (`~/Library/Application Support/NoType/settings.json`, 0600 `{"geminiKey": "..."}`) → migrate into data-protection, remove the file on success.
4. Nothing anywhere → `.absent` (first run).

A migration write that fails returns the value anyway (no lock-out) and leaves the source for next-launch retry. `saveGeminiKey` / `deleteGeminiKey` also remove the legacy `settings.json` file if present.

**Deliberate-delete tombstone.** `deleteGeminiKey` sets a `notype.keychain.cleared` UserDefaults flag (cleared by `saveGeminiKey`). When set, `migrateAndResolve` returns `.absent` immediately after an empty data-protection read — *before* consulting the legacy keychain or `settings.json`. Without it, a user who migrated from the legacy keychain and then deleted their key would have it silently **resurrected** (the orphaned legacy item, which we deliberately never delete per the asymmetry hard rule, gets re-migrated), or — for a stranded user who re-pasted then deleted — be **re-prompted** by the unreadable legacy item. The flag is persisted (survives relaunch) and intentionally **not** cleared by an onboarding reset, mirroring the key itself surviving a wizard reset. Pinned by `SecretStoreTests` (`…clearedTombstone…` cases).

**Stranded users.** Anyone whose legacy keychain read already throws `errSecAuthFailed` (the bug, pre-fix) can't be recovered programmatically — the value is unreadable. They re-paste once via the calm `AppState.apiKeyNeedsReentry` surface (Settings → API key / onboarding's `ReenterKeyNote`); the key then lands in the data-protection store and is stable thereafter.

## Testing

- `NoTypeTests/KeychainStoreTests.swift` — round-trip / upsert / idempotent-delete / malformed-item under the data-protection store (UUID-suffixed services in the production access group), plus the **asymmetric** store-isolation semantics (legacy item invisible to data-protection; data-protection item visible to an unscoped legacy query).
- `NoTypeTests/SecretStoreTests.swift` — the `migrateAndResolve` chain: dp-present, legacy-keychain migrate, settings.json migrate+remove, `errSecAuthFailed → .needsReentry`, absent, and migration-write-failure resilience (injected keychain closures — touches no real storage).
- `NoTypeTests/AppStateKeyStateTests.swift` — `AppState.keyUIState` mapping (`.needsReentry` not collapsed into the first-run state).
- CI: macOS Keychain is available but locked by default — tests must not require prompts. The data-protection access group works in the hosted test process (it runs inside `NoType.app`, which carries the entitlement). `AfterFirstUnlock` is safe on a CI runner logged in once.

## Pointers

- Why BYOK + Keychain (not hosted key / proxy) → `solutions/tooling-decisions/byok-keychain-storage-2026-05-15.md`.
- Data-protection migration (cert-rotation bug + fix, R1/R2/R3) → `docs/solutions/documentation-gaps/keychain-data-protection-migration-2026-05-30.md`.
- Privacy posture (no telemetry; local-only) → `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`.
