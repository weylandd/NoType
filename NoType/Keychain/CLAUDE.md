# Keychain module

Stores the user's Gemini API key in the macOS Keychain. Single-account model — one Gemini key per user; multi-account is out of scope.

## Files

- `KeychainStore.swift` — thin wrapper around `Security.framework`'s `kSecClassGenericPassword` items. Parametrised on a `Store` backend; `productionStore` selects which one production uses (currently `.legacyFile`) and `migrationSourceStore` derives the other. Used by `SecretStore` and the eval harness's legacy-key read.
- `SecretStore.swift` — backend-agnostic public API for the rest of the app. Owns the chained one-shot migration (production ← migration source ← legacy `settings.json`) and the `KeyResolution` tri-state.

> **Storage is currently the LEGACY file keychain, not data-protection.** The data-protection store needs the `keychain-access-groups` entitlement, which macOS classes as *restricted* — AMFI SIGKILLs an unprofiled bundle that declares it. v0.1.11 shipped exactly that and could not launch anywhere. See `docs/solutions/runtime-errors/amfi-restricted-entitlement-launch-kill-2026-07-25.md`; the path back is `docs/solutions/documentation-gaps/developer-id-provisioning-profile-2026-07-25.md`.

## Invariants

1. **Production storage is `KeychainStore.productionStore`** — today `.legacyFile` (no data-protection flag, no access group). `service = "app.notype.gemini"`, `account = "default"`, `accessible = kSecAttrAccessibleAfterFirstUnlock`. Nothing outside `KeychainStore` names a concrete backend.
2. **Access is cert-gated, and that is a known regression.** A file-keychain item's ACL is bound to the creating build's code-signing identity, so a cert rotation can produce `errSecAuthFailed (-25293)` or the login-password prompt — see "Why this works (and when it doesn't)". `.dataProtection` fixes this but is currently unreachable.
3. **`AfterFirstUnlock`, not `WhenUnlocked`** — keeps the item readable after FileVault unlock paired with auto-login. Valid in both stores.
4. **`Store.dataProtection` is dormant, not deleted.** Every `.dataProtection` query fails with `errSecMissingEntitlement` while the entitlement is absent. It stays wired (and `accessGroup` stays defined) so restoring it is a one-line `productionStore` flip plus the entitlement + profile, not a re-derivation.
5. **`SecretStore` is the only app-facing entry.** `KeychainStore` is module-internal. Swapping the backend (iCloud Keychain, hosted proxy) is a one-file change.
6. **`save` is upsert** — try `SecItemUpdate`; on `errSecItemNotFound` fall back to `SecItemAdd`. `load` returns `nil` when the item doesn't exist (not an error). `delete` is idempotent — `errSecItemNotFound` is treated as success.
7. **`migrateAndResolve` returns a tri-state** `KeyResolution { present / needsReentry / absent }`. A read that throws a *stranding* status (`errSecAuthFailed`, `errSecInteractionNotAllowed` — see `SecretStore.isStrandingFailure`) → `.needsReentry` (UI shows a calm "paste once" note), distinct from `.absent` (genuine first run). `loadFromEnvOrFile()` collapses both to `nil` for value-only callers.
8. **A non-stranding read failure falls through quietly.** `errSecMissingEntitlement` in particular is the *expected* result of every `migrationSourceStore` read today; treating it as stranding would show every first-run user the "paste your key once" note instead of onboarding. Pinned by `SecretStoreTests.test_resolve_fallbackMissingEntitlement_returnsAbsent_notNeedsReentry`.
9. **`NOTYPE_GEMINI_KEY` env var wins** for `currentKeyResolution` / `loadFromEnvOrFile`. Never persisted into the Keychain — dev-only path.

## Hard rules

- **Never log the key** (even at `.debug`).
- **Never include the key in error messages or telemetry** (we have no telemetry; in case we add it).
- **Never put the key in `UserDefaults`** or any plist file.
- **Never put the key in environment variables in `Info.plist`** or in launch scripts that ship with the app.
- **Never add a restricted entitlement without embedding a matching provisioning profile** at `Contents/embedded.provisionprofile`. `codesign --verify --deep --strict`, notarization, stapling and `spctl --assess` all pass on a bundle that violates this; AMFI kills it at `exec`, with no crash report. `scripts/release.sh` gates on it and `KeychainStoreTests` pins the local half. This is the v0.1.11 brick — do not relearn it.
- **Restoring `.dataProtection` is a four-part change, all in one PR** — portal capability + downloaded profile, `release.sh` embedding it, the entitlement, and the `productionStore` flip. Any subset breaks launch or breaks every read.
- **`KeychainStore.accessGroup` must equal the entitlement literal** whenever that entitlement exists. Change one → change both, or every data-protection read fails with `errSecMissingEntitlement`.
- **Never delete the migration source after migrating.** Keychain isolation is **asymmetric**: an unscoped `.legacyFile` query (no flag, no group) *also* surfaces an entitled app's data-protection item, so a cross-store delete of the same service can nuke the item just written. An orphaned source item is harmless — `migrateAndResolve` reads the production store first, so it's never consulted again. Pinned by `KeychainStoreTests.test_storeIsolation_legacyQuerySurfacesDataProtectionItem_documentedMacOSBehavior`. (The legacy `settings.json` *file* is safe to delete — it's not a keychain query.)

## Why this works (and when it doesn't)

Two mechanisms, and the trade between them is the whole story of this module:

- **Legacy file keychain (production, current).** An item's ACL is captured at creation and bound to the creating build's **code-signing identity** (trusted-application list / partition list). The stable designated requirement (`signing/NoType.xcrequirements`) keeps access silent across rebuilds under *one* cert — fine for the stable **Developer ID** release cert, fragile for the rotating **Apple Development** dev cert. When that rotates (Xcode regen, new Mac, expiry), the new signature no longer satisfies the ACL → `errSecAuthFailed (-25293)` on the background / `LSUIElement` cold path, or the login-password prompt interactively. **Needs no entitlement, so it always launches.**

- **Data-protection keychain (dormant).** Access is granted to any process whose `keychain-access-groups` entitlement includes the item's access group. The group (`49T6U8DQXZ.app.notype`) is keyed on **Team ID + bundle id** — both stable across rebuilds, re-signing and cert rotation — and the store does not use the interactive trusted-application ACL mechanism, so it **never** prompts for the login password. Strictly better storage. **But the entitlement is restricted, so it needs an embedded provisioning profile to launch at all.**

**If you see Keychain password prompts or the key "disappears" on a build:** that is invariant 2 biting — the cert-rotation regression. The user pastes once via the `.needsReentry` surface. If it becomes common, that is the trigger to do the provisioning-profile work.

**If the app quits instantly with no crash report:** that is the restricted-entitlement kill, not a keychain problem. Check `log show --last 30m --predicate 'process == "amfid"'` for `-413 "No matching profile found"`.

## Storage backends + migration

`SecretStore.migrateAndResolve` resolves the key in order and migrates whatever it finds into the data-protection store:

1. **`KeychainStore.productionStore`** (today `.legacyFile`) → use it (steady state).
2. **Deliberate-delete tombstone** set → `.absent`, no resurrection.
3. **`KeychainStore.migrationSourceStore`** (the other backend — today `.dataProtection`) → migrate into the production store, return it. We do **not** delete the source (asymmetry hard rule above). Today this read always fails with `errSecMissingEntitlement`, which is a quiet fall-through, not a strand.
4. **Legacy `settings.json`** (`~/Library/Application Support/NoType/settings.json`, 0600 `{"geminiKey": "..."}`) → migrate into the production store, remove the file on success.
5. Nothing anywhere → `.absent` (first run), or `.needsReentry` if a read threw a stranding status.

The chain is written against `productionStore` / `migrationSourceStore` rather than naming a backend, so flipping the production store reverses the migration direction automatically instead of needing this rewritten again.

A migration write that fails returns the value anyway (no lock-out) and leaves the source for next-launch retry. `saveGeminiKey` / `deleteGeminiKey` also remove the legacy `settings.json` file if present.

**Deliberate-delete tombstone.** `deleteGeminiKey` sets a `notype.keychain.cleared` UserDefaults flag (cleared by `saveGeminiKey`). When set, `migrateAndResolve` returns `.absent` immediately after an empty production read — *before* consulting the migration source or `settings.json`. Without it, a user who migrated and then deleted their key would have it silently **resurrected** (the orphaned source item, which we deliberately never delete per the asymmetry hard rule, gets re-migrated), or — for a stranded user who re-pasted then deleted — be **re-prompted** by the unreadable item. The flag is persisted (survives relaunch) and intentionally **not** cleared by an onboarding reset, mirroring the key itself surviving a wizard reset. Pinned by `SecretStoreTests` (`…clearedTombstone…` cases).

**Stranded users.** Anyone whose keychain read throws `errSecAuthFailed` (the cert-rotation bug — live again since 0.1.12, see invariant 2) can't be recovered programmatically: the value is unreadable. They re-paste once via the calm `AppState.apiKeyNeedsReentry` surface (Settings → API key / onboarding's `ReenterKeyNote`). The re-pasted key lands in the production store under the *current* signing identity and is stable until that identity rotates again.

## Testing

- `NoTypeTests/KeychainStoreTests.swift` — round-trip / upsert / idempotent-delete / malformed-item against the **production** store (UUID-suffixed services), which needs no entitlement and so runs everywhere. The `.dataProtection` cases and the **asymmetric** store-isolation cases `XCTSkip` while the entitlement is absent — kept as the acceptance suite for restoring that store. Plus two entitlement guards: `test_restrictedEntitlement_requiresEmbeddedProvisioningProfile` (the v0.1.11 defect) and `test_restrictedEntitlement_presentIffDataProtectionIsProduction` (no half-migration).
- `NoTypeTests/SecretStoreTests.swift` — the `migrateAndResolve` chain: production-present, migration-source migrate, settings.json migrate+remove, stranding classification (`errSecAuthFailed` → `.needsReentry` vs `errSecMissingEntitlement` → `.absent`), tombstone cases, and migration-write-failure resilience (injected keychain closures — touches no real storage). Seams are named `primaryRead` / `fallbackRead` so they survive a `productionStore` flip.
- `NoTypeTests/AppStateKeyStateTests.swift` — `AppState.keyUIState` mapping (`.needsReentry` not collapsed into the first-run state).
- CI: macOS Keychain is available but locked by default — tests must not require prompts. The production (legacy) store needs no entitlement, so its tests run unconditionally; `AfterFirstUnlock` is safe on a CI runner logged in once.

## Pointers

- Why BYOK + Keychain (not hosted key / proxy) → `solutions/tooling-decisions/byok-keychain-storage-2026-05-15.md`.
- Why the data-protection store is currently off (the v0.1.11 launch kill) → `docs/solutions/runtime-errors/amfi-restricted-entitlement-launch-kill-2026-07-25.md`.
- The path back to it (portal + profile, four-part change) → `docs/solutions/documentation-gaps/developer-id-provisioning-profile-2026-07-25.md`.
- Data-protection migration (cert-rotation bug + fix, R1/R2/R3) → `docs/solutions/documentation-gaps/keychain-data-protection-migration-2026-05-30.md`.
- Privacy posture (no telemetry; local-only) → `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`.
