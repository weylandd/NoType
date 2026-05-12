import Foundation
import OSLog
import Security

/// Thin, dependency-free wrapper around `Security.framework`'s
/// `kSecClassGenericPassword` items. Used by `SecretStore` to persist the
/// user's Gemini API key.
///
/// **macOS Keychain prompts.** On macOS the legacy Keychain prompts for the
/// user's login password the first time a binary touches a Keychain item,
/// unless that binary's code signature passes the item's ACL. The ACL is
/// keyed on **codesign designated requirement**. NoType ships a stable
/// designated requirement (`signing/NoType.xcrequirements` —
/// `designated => identifier "app.notype"`) and a stable Apple Developer
/// Team ID (`49T6U8DQXZ` in `project.yml`), so dev rebuilds preserve the
/// same DR / Team-ID pair and Keychain access stays silent — same
/// mechanism that already keeps TCC grants (Accessibility, Microphone)
/// surviving rebuilds.
///
/// If you suddenly see Keychain password prompts on launch, check that:
/// 1. `DEVELOPMENT_TEAM` in `project.yml` matches the prior signing identity.
/// 2. `signing/NoType.xcrequirements` is still passed via `OTHER_CODE_SIGN_FLAGS`.
/// 3. The bundle id is unchanged (`app.notype`).
enum KeychainStore {
    private static let log = Logger(subsystem: "app.notype", category: "keychain")

    /// Default service identifier for NoType's items. Per-call override is
    /// allowed (used by tests with UUID-suffixed services to avoid
    /// polluting the real Keychain).
    static let defaultService = "app.notype.gemini"
    /// Default account identifier — NoType is single-account (see ADR-011).
    static let defaultAccount = "default"

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

    // MARK: - Public API

    /// Upsert: try `SecItemUpdate`; on `errSecItemNotFound` fall back to
    /// `SecItemAdd`. Throws on any other failure.
    static func save(
        _ value: String,
        service: String = defaultService,
        account: String = defaultAccount
    ) throws {
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
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
        account: String = defaultAccount
    ) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
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
        account: String = defaultAccount
    ) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        Self.log.error("SecItemDelete failed: \(status, privacy: .public)")
        throw KeychainError.status(status)
    }
}
