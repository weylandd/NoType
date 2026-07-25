import Foundation
import OSLog
import Security

/// Thin, dependency-free wrapper around `Security.framework`'s
/// `kSecClassGenericPassword` items. Used by `SecretStore` to persist the
/// user's Gemini API key.
///
/// **Which backend is production: see `productionStore`.** Today it is
/// `.legacyFile`; `.dataProtection` is the better store but is currently
/// unreachable. The trade-off between them:
///
/// - **`.dataProtection`** (`kSecUseDataProtectionKeychain` + `accessGroup`)
///   gates access on the `keychain-access-groups` entitlement — Team ID +
///   bundle id — **not** on a per-cert trusted-application ACL captured at
///   item-creation time. Access therefore survives code-signing-identity
///   rotation, and the store never shows the macOS login-password prompt for
///   the app's own access-group items. **But** macOS classes that entitlement
///   as *restricted*: AMFI SIGKILLs a binary carrying it unless the bundle
///   embeds a matching provisioning profile. v0.1.11 shipped it without one
///   and could not launch at all.
/// - **`.legacyFile`** (no flag, no access group) needs no entitlement and no
///   profile, so it always launches — but it pins each item's ACL to the
///   creating build's leaf cert. When that cert rotates, reads fail with
///   `errSecAuthFailed (-25293)` or pop the login-password prompt. That is the
///   bug the data-protection migration set out to fix, and it is back until a
///   Developer ID provisioning profile is embedded.
///
/// See `NoType/Keychain/CLAUDE.md`,
/// `docs/solutions/runtime-errors/amfi-restricted-entitlement-launch-kill-2026-07-25.md`
/// and `docs/solutions/documentation-gaps/developer-id-provisioning-profile-2026-07-25.md`.
enum KeychainStore {
    private static let log = Logger(subsystem: "app.notype", category: "keychain")

    /// Default service identifier for NoType's items. Per-call override is
    /// allowed (used by tests with UUID-suffixed services to avoid
    /// polluting the real Keychain).
    static let defaultService = "app.notype.gemini"
    /// Default account identifier — NoType is single-account (see ADR-011).
    static let defaultAccount = "default"

    /// Data-protection keychain access group. Used only by `.dataProtection`
    /// queries. **When that store is production, this must match the
    /// `keychain-access-groups` entitlement literal** in
    /// `NoType/NoType.entitlements` verbatim (Team ID prefix + bundle id).
    /// The entitlement is currently absent — see `productionStore` — so the
    /// literal is dormant, kept so restoring the data-protection store is a
    /// one-line flip rather than a re-derivation.
    static let accessGroup = "49T6U8DQXZ.app.notype"

    /// Which keychain backend a query targets.
    enum Store {
        /// Modern data-protection keychain, scoped by `accessGroup`.
        /// Entitlement-gated → survives signing-identity rotation, never
        /// prompts. **Requires an embedded provisioning profile** (see
        /// `productionStore`), so it is not currently reachable.
        case dataProtection
        /// Legacy file-based keychain (no data-protection flag, no access
        /// group). Needs no entitlement, so it always launches; its ACL is
        /// pinned to the creating build's leaf cert. **Production default.**
        case legacyFile
    }

    /// The backend production reads and writes.
    ///
    /// **`.legacyFile` — deliberately, and reversibly.** `.dataProtection` is
    /// the store we want (it is immune to the cert-rotation ACL failure), but
    /// it requires the `keychain-access-groups` entitlement, which macOS
    /// classes as *restricted*: AMFI refuses to exec a bundle carrying it
    /// unless the bundle also embeds a matching Developer ID provisioning
    /// profile. v0.1.11 shipped the entitlement with no profile and was
    /// SIGKILLed before `main()` on every install.
    ///
    /// Flipping this back to `.dataProtection` is **not** sufficient on its
    /// own — it must land together with the entitlement AND an embedded
    /// profile, or the app stops launching again. The portal work and the
    /// release-script change are tracked in
    /// `docs/solutions/documentation-gaps/developer-id-provisioning-profile-2026-07-25.md`.
    static let productionStore: Store = .legacyFile

    /// The other backend — consulted once by `SecretStore.migrateAndResolve`
    /// so a key written under a previous `productionStore` is migrated forward
    /// instead of stranding the user. Derived from `productionStore` so the
    /// migration direction reverses automatically when the production store
    /// flips.
    static var migrationSourceStore: Store {
        productionStore == .dataProtection ? .legacyFile : .dataProtection
    }

    enum KeychainError: Error, LocalizedError {
        /// Wraps any non-success `OSStatus` from `SecItem*` calls.
        case status(OSStatus)
        /// Item found but `kSecValueData` was missing or not UTF-8 decodable.
        case malformedItem

        var errorDescription: String? {
            switch self {
            case .status(let s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
                return "Keychain error: \(msg) (\(s))"
            case .malformedItem:
                return "Keychain item exists but its value couldn't be decoded."
            }
        }
    }

    // MARK: - Query construction

    /// Base match query for an item. For `.dataProtection`, adds the
    /// data-protection flag and the access group so the query resolves
    /// against the right store; `.legacyFile` adds neither (matching the
    /// pre-migration behaviour).
    private static func baseQuery(
        service: String,
        account: String,
        store: Store
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if store == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    // MARK: - Public API

    /// Upsert: try `SecItemUpdate`; on `errSecItemNotFound` fall back to
    /// `SecItemAdd`. Throws on any other failure.
    static func save(
        _ value: String,
        service: String = defaultService,
        account: String = defaultAccount,
        store: Store = productionStore
    ) throws {
        let data = Data(value.utf8)
        let query = baseQuery(service: service, account: account, store: store)
        let updates: [String: Any] = [
            kSecValueData as String:      data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var add = query
            add.merge(updates) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                Self.log.error("SecItemAdd failed: \(addStatus, privacy: .public)")
                throw KeychainError.status(addStatus)
            }
            return
        }
        Self.log.error("SecItemUpdate failed: \(updateStatus, privacy: .public)")
        throw KeychainError.status(updateStatus)
    }

    /// Returns `nil` if no item exists. Throws on any other failure or on
    /// a malformed item.
    static func load(
        service: String = defaultService,
        account: String = defaultAccount,
        store: Store = productionStore
    ) throws -> String? {
        var query = baseQuery(service: service, account: account, store: store)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            Self.log.error("SecItemCopyMatching failed: \(status, privacy: .public)")
            throw KeychainError.status(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.malformedItem
        }
        return value
    }

    /// Idempotent — `errSecItemNotFound` is treated as success.
    static func delete(
        service: String = defaultService,
        account: String = defaultAccount,
        store: Store = productionStore
    ) throws {
        let query = baseQuery(service: service, account: account, store: store)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        Self.log.error("SecItemDelete failed: \(status, privacy: .public)")
        throw KeychainError.status(status)
    }
}
