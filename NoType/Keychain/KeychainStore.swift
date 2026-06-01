import Foundation
import OSLog
import Security

/// Thin, dependency-free wrapper around `Security.framework`'s
/// `kSecClassGenericPassword` items. Used by `SecretStore` to persist the
/// user's Gemini API key.
///
/// **Why the data-protection keychain.** The production path
/// (`Store.dataProtection`, the default) stores items in the
/// **data-protection keychain** (`kSecUseDataProtectionKeychain`) scoped by
/// a **keychain access group** (`accessGroup`). Access is gated by the
/// app's `keychain-access-groups` entitlement — i.e. by Team ID + bundle id,
/// **not** by a per-cert trusted-application ACL captured at item-creation
/// time. This means:
///
/// - Access survives code-signing-identity rotation (Apple Development certs
///   rotate; Developer ID is stable) and OS updates, as long as the Team ID +
///   bundle id + entitlement are unchanged.
/// - The data-protection keychain never shows the macOS login-password
///   prompt for the app's own access-group items.
///
/// The **legacy file-based keychain** (`Store.legacyFile`) — no flag, no
/// access group — pins each item's ACL to the creating build's leaf cert.
/// When that cert rotated, reads failed with `errSecAuthFailed (-25293)` or
/// popped the login-password prompt. We keep `legacyFile` only to *read*
/// pre-migration items (the one-shot migration in `SecretStore`) and the
/// eval-suite test key. New production writes always go to `dataProtection`.
///
/// See `NoType/Keychain/CLAUDE.md` and
/// `docs/solutions/documentation-gaps/keychain-data-protection-migration-2026-05-30.md`.
enum KeychainStore {
    private static let log = Logger(subsystem: "app.notype", category: "keychain")

    /// Default service identifier for NoType's items. Per-call override is
    /// allowed (used by tests with UUID-suffixed services to avoid
    /// polluting the real Keychain).
    static let defaultService = "app.notype.gemini"
    /// Default account identifier — NoType is single-account (see ADR-011).
    static let defaultAccount = "default"

    /// Data-protection keychain access group. **Must match the
    /// `keychain-access-groups` entitlement literal** in
    /// `NoType/NoType.entitlements` verbatim (Team ID prefix + bundle id).
    /// Hardcoded (not derived) so the Swift side and the entitlement stay in
    /// lockstep; the Team ID is already fixed in `project.yml`.
    static let accessGroup = "49T6U8DQXZ.app.notype"

    /// Which keychain backend a query targets.
    enum Store {
        /// Modern data-protection keychain, scoped by `accessGroup`.
        /// Entitlement-gated → survives signing-identity rotation, never
        /// prompts. **Production default.**
        case dataProtection
        /// Legacy file-based keychain (no data-protection flag, no access
        /// group). Read-only in practice: the `SecretStore` migration reads
        /// pre-migration items here, and `PromptEvalHarness` reads its
        /// broad-ACL test key here. New production writes never target this.
        case legacyFile
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
        store: Store = .dataProtection
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
        store: Store = .dataProtection
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
        store: Store = .dataProtection
    ) throws {
        let query = baseQuery(service: service, account: account, store: store)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        Self.log.error("SecItemDelete failed: \(status, privacy: .public)")
        throw KeychainError.status(status)
    }
}
