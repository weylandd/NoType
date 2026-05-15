# Keychain module

Stores the user's Gemini API key in the macOS Keychain. Single-account model — one Gemini key per user; multi-account is out of scope.

## Files

- `KeychainStore.swift` — thin wrapper around `Security.framework`'s `kSecClassGenericPassword` items. Used **only** by `SecretStore`.
- `SecretStore.swift` — backend-agnostic public API for the rest of the app. Handles the one-shot migration from the legacy 0600 JSON file used by earlier builds.

## Invariants

1. **Single Keychain item** — `service = "app.notype.gemini"`, `account = "default"`, `accessible = kSecAttrAccessibleAfterFirstUnlock`.
2. **`AfterFirstUnlock`, not `WhenUnlocked`** — keeps the item readable after FileVault unlock paired with auto-login. Menu-bar app transcribes without re-entry after first interactive login of the session.
3. **`SecretStore` is the only thing the rest of the app talks to.** `KeychainStore` is private to this module. Swapping the backend (iCloud Keychain, hosted proxy) is a one-file change.
4. **`save` is upsert** — try `SecItemUpdate`; on `errSecItemNotFound` fall back to `SecItemAdd`. `load` returns `nil` when the item doesn't exist (not an error). `delete` is idempotent — `errSecItemNotFound` is treated as success.
5. **`loadGeminiKey` is private** (since PR #8) — the only caller is `SecretStore.loadFromEnvOrFile`. Errors are logged and swallowed (return `nil`) rather than thrown.
6. **`NOTYPE_GEMINI_KEY` env var wins over Keychain** for `loadFromEnvOrFile`. Never persisted from env into the Keychain — dev-only path.

## Hard rules

- **Never log the key** (even at `.debug`).
- **Never include the key in error messages or telemetry** (we have no telemetry; in case we add it).
- **Never put the key in `UserDefaults`** or any plist file.
- **Never put the key in environment variables in `Info.plist`** or in launch scripts that ship with the app.
- **Service / account parameters are exposed** so tests can use UUID-suffixed services and avoid polluting the real Keychain.

## Why this works silently on macOS

The macOS Keychain prompts for the user's login password the first time a binary touches a Keychain item, **unless** the binary's code signature passes the item's ACL. The ACL is keyed on the **codesign designated requirement**, not the cdhash directly.

NoType ships a stable DR (`signing/NoType.xcrequirements` — `designated => identifier "app.notype"`) and a stable Apple Developer Team ID (`49T6U8DQXZ` in `project.yml`). Dev rebuilds preserve the same DR / Team-ID pair, so Keychain access stays silent — exactly the same mechanism that already keeps TCC grants surviving rebuilds.

**If you suddenly see Keychain password prompts on launch:** check that `DEVELOPMENT_TEAM` in `project.yml` matches the prior signing identity, `signing/NoType.xcrequirements` is still passed via `OTHER_CODE_SIGN_FLAGS`, and the bundle ID is unchanged (`app.notype`).

## Legacy `settings.json` migration

Earlier builds stored the key in `~/Library/Application Support/NoType/settings.json` (0600 JSON, `{"geminiKey": "..."}`). `SecretStore.loadFromEnvOrFile()` (and the private Keychain read it wraps) performs a one-shot migration on first launch of a Keychain-backed build:

1. Read the Keychain. If it has a key → return it.
2. If empty AND legacy file holds a key → copy to Keychain, return the value (legacy file is removed on success; if the Keychain write fails, we still return the migrated value so the user isn't locked out).
3. On any successful `saveGeminiKey` / `deleteGeminiKey` → remove the legacy file if it's still around.

Net effect: existing users upgrade transparently, no re-paste.

## Testing

`KeychainStoreTests.swift` does not exist yet (tracked alongside the broader test-debt backlog). When written:

- Use a per-test `service` (UUID-suffixed) to avoid polluting the real Keychain.
- Round-trip: save → load → assert equal; delete → load → assert nil.
- Upsert: save twice with different values, load returns the second.
- Idempotent delete: delete on a missing item is a no-op (no throw).

CI: macOS Keychain is available but locked by default — tests must not require user prompts. `AfterFirstUnlock` is safe on a CI runner that has logged in once.

## Pointers

- Why BYOK + Keychain (not hosted key / proxy) → `solutions/tooling-decisions/byok-keychain-storage-2026-05-15.md`.
- Privacy posture (no telemetry; local-only) → `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`.
