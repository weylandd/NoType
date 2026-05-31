---
title: BYOK Gemini API key, stored in Keychain
date: 2026-05-15
category: tooling-decisions
module: Keychain
problem_type: tooling_decision
component: authentication
severity: high
applies_when:
  - Adding any new third-party API integration
  - Considering a hosted-key model or proxy
  - Auditing how credentials are stored
tags: [keychain, byok, api-key, secrets, oss, beta-scope]
---

# BYOK Gemini API key, stored in Keychain

## Context

NoType is OSS and free. Transcription costs money (paid to Google per Gemini call). Two ways to handle billing:

1. **Hosted key** — NoType operator pays Google; users get a "free" experience until we install rate limits / accounts / a paid tier.
2. **BYOK (bring your own key)** — user supplies their own Gemini API key in Settings; we store it locally; their bill, their relationship with Google.

## Guidance

**BYOK.** The user supplies their key in Settings (or onboarding step 1.1) and **we store it in macOS Keychain** via `SecretStore` (`NoType/Keychain/SecretStore.swift` → `KeychainStore.swift`). No proxy, no hosted key, no telemetry that could let us infer user behaviour.

The Keychain entry uses:

- The **data-protection keychain** (`kSecUseDataProtectionKeychain`) scoped by the access group `49T6U8DQXZ.app.notype` (`keychain-access-groups` entitlement) — entitlement-gated access that survives signing-cert rotation, see the migration doc below.
- `kSecAttrService = "app.notype.gemini"`
- `kSecAttrAccount = "default"` (single-account model — multi-account is out of scope)
- `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock`

## Why This Matters

- **No billing relationship.** Operating a hosted-key model means handling user accounts, API quota, abuse mitigation, and the legal apparatus of a paid SaaS — none of which the v1 product asks for.
- **OSS positioning.** A user can read the source, build the binary, and confirm the key never leaves their device. Hosted keys would force them to trust a server they can't audit.
- **Future-proof.** The paid SaaS tier (when it lands) can add a hosted option as a Pro feature; the OSS app continues to work standalone with BYOK.
- **Keychain over a 0600 JSON file.** Earlier builds used `~/Library/Application Support/NoType/settings.json`; `SecretStore.migrateAndResolve()` (via `loadFromEnvOrFile()` / `currentKeyResolution()`) migrates the file's contents — and any pre-existing legacy-keychain item — into the data-protection keychain on first launch, removing the legacy file on a successful write. Keychain wins on: ACL-aware access, `AfterFirstUnlock` semantics, and **surviving signing-identity rotation silently** once on the data-protection keychain.
  - **Correction (2026-05-30):** an earlier version of this note claimed the legacy file-keychain "survives rebuilds quietly when the codesign designated requirement is stable (fixed DR via `signing/NoType.xcrequirements`)". That held only for cdhash changes under the stable **Developer ID** release cert — **not** for **Apple Development** dev-cert rotation, which broke the legacy ACL and made the key vanish (`errSecAuthFailed`) or pop the login-password prompt. The data-protection keychain access group fixes this at the architecture level. See `docs/solutions/documentation-gaps/keychain-data-protection-migration-2026-05-30.md` and `NoType/Keychain/CLAUDE.md` "Why this works silently".

## When to Apply

- Default for any new third-party API integration where the user holds the relationship.
- Reconsider only for the future paid tier — and even then, BYOK should remain available for OSS users.

## Examples

**The path** (`SecretStore.swift`):

```swift
enum SecretStore {
    static func saveGeminiKey(_ key: String) throws
    static func deleteGeminiKey() throws
    static func currentKeyResolution() -> KeyResolution  // env, then migrateAndResolve()
    static func loadFromEnvOrFile() -> String?           // value-only; needsReentry/absent → nil
    // migrateAndResolve(): data-protection → legacy keychain → settings.json → tri-state
}
```

**Trade-off accepted:** Onboarding friction. Mitigated by clear instructions in step 1.1 and a deep link to Google AI Studio for key creation. Validation happens via a no-cost `GET /v1beta/models` call before persisting (`GeminiClient.validateKey`).

## Related

- `NoType/Keychain/CLAUDE.md` — implementation detail (item shape, ACL, why Keychain access stays silent).
- `docs/decisions.md` ADR-011 — legacy index entry, redirects here.
