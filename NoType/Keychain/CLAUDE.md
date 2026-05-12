# Keychain module

Stores the user's Gemini API key in the macOS Keychain. Honours ADR-011. Single-account model — NoType supports one Gemini key per user. Multi-account is out of scope.

Files:
- `KeychainStore.swift` — thin wrapper around `Security.framework`'s `kSecClassGenericPassword` items. Used **only** by `SecretStore`.
- `SecretStore.swift` — backend-agnostic public API for the rest of the app. Handles the one-shot migration from the legacy 0600 JSON file used by earlier builds.

---

## Item shape

| Attribute | Value |
|---|---|
| `kSecClass` | `kSecClassGenericPassword` |
| `kSecAttrService` | `"app.notype.gemini"` (`KeychainStore.defaultService`) |
| `kSecAttrAccount` | `"default"` (`KeychainStore.defaultAccount`) |
| `kSecValueData` | UTF-8 of the API key |
| `kSecAttrAccessible` | `kSecAttrAccessibleAfterFirstUnlock` |

`AfterFirstUnlock` (not `WhenUnlocked`) keeps the item readable in unattended sessions (e.g. fresh-boot login with FileVault paired with auto-login) — important so the menu-bar app can transcribe without the user re-entering anything after their first interactive login of the session.

---

## API

```swift
enum KeychainStore {
    static func save(_ value: String, service: String = defaultService, account: String = defaultAccount) throws
    static func load(service: String = defaultService, account: String = defaultAccount) throws -> String?
    static func delete(service: String = defaultService, account: String = defaultAccount) throws
}

enum SecretStore {
    static func saveGeminiKey(_ key: String) throws
    static func loadGeminiKey() throws -> String?
    static func deleteGeminiKey() throws

    /// `NOTYPE_GEMINI_KEY` env var wins over Keychain (handy for ephemeral
    /// CI or local-only runs). Never persisted from env into the Keychain.
    static func loadFromEnvOrFile() -> String?
}
```

`save` is upsert: try `SecItemUpdate`; on `errSecItemNotFound` fall back to `SecItemAdd`. `load` returns `nil` when the item doesn't exist (not an error). `delete` is idempotent — `errSecItemNotFound` is treated as success. Service / account parameters are exposed so tests can use UUID-suffixed services and avoid polluting the real Keychain.

`SecretStore` is the only thing the rest of the app talks to. `AppState`, `SettingsView`, and the onboarding wizard see a backend-agnostic interface, so swapping `KeychainStore` for a different secret backend (e.g. iCloud Keychain when we get sync, or a hosted proxy when the paid tier lands) is a one-file change.

---

## Why this works silently on macOS

The macOS Keychain prompts for the user's login password the first time a binary touches a Keychain item, **unless** the binary's code signature passes the item's ACL. The ACL is keyed on the **codesign designated requirement**, not the cdhash directly.

NoType ships a stable DR (`signing/NoType.xcrequirements` — `designated => identifier "app.notype"`) and a stable Apple Developer Team ID (`49T6U8DQXZ` in `project.yml`). Dev rebuilds preserve the same DR / Team-ID pair, so Keychain access stays silent — exactly the same mechanism that already keeps TCC grants (Accessibility, Microphone) surviving rebuilds.

If you suddenly see Keychain password prompts on launch, check that:

1. `DEVELOPMENT_TEAM` in `project.yml` matches the prior signing identity.
2. `signing/NoType.xcrequirements` is still passed via `OTHER_CODE_SIGN_FLAGS`.
3. The bundle ID is unchanged (`app.notype`).

---

## Legacy `settings.json` migration

Earlier builds stored the key in `~/Library/Application Support/NoType/settings.json` as a 0600 JSON file (`{"geminiKey": "..."}`). `SecretStore.loadGeminiKey()` performs a one-shot migration on first launch of a Keychain-backed build:

1. Read the Keychain.
2. If it has a key, return it (legacy file, if any, is left in place — see step 4).
3. If the Keychain is empty AND the legacy file holds a key, copy the key into the Keychain. If the Keychain write succeeds, the legacy file is removed; if it fails, the migrated value is returned to the caller anyway so the user isn't locked out, and the failure is logged so the next launch retries.
4. On any successful `saveGeminiKey` or `deleteGeminiKey`, the legacy file is removed if it's still around.

Net effect: existing users upgrade transparently — no re-paste.

---

## What we never do

- Never log the key, even at debug level.
- Never include the key in error messages or telemetry (we have no telemetry, but in case we add it).
- Never put the key in `UserDefaults` or any plist file.
- Never put the key in environment variables in `Info.plist` or launch scripts that ship with the app.

For local dev convenience, `NOTYPE_GEMINI_KEY` env var is read at startup *only* when neither the Keychain nor the legacy file has an entry, via `loadFromEnvOrFile`. This is a dev-only path; never persisted to the Keychain.

---

## Testing

`KeychainStoreTests.swift` does not exist yet (tracked alongside the broader test-debt backlog). When written:

- Use a per-test `service` (UUID-suffixed) to avoid polluting the real Keychain.
- Round-trip: save → load → assert equal; delete → load → assert nil.
- Upsert: save twice with different values, load returns the second.
- Idempotent delete: delete on a missing item is a no-op (no throw).

`SecretStoreTests.swift` would cover the migration logic with a synthetic legacy `settings.json` fixture in a tmpdir-rooted helper.

In CI the macOS Keychain is available but locked by default — tests must not require user prompts. `AfterFirstUnlock` is safe on a CI runner that has logged in once; if a fresh runner causes issues, `kSecAttrAccessibleAlways` is the escape hatch (test-only — never in production).
