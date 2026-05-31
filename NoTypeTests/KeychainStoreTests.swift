import XCTest
import Security
@testable import NoType

/// Pins `KeychainStore` behaviour against the data-protection keychain.
///
/// Doubles as the local proof for the U1 signing spike, **step 1**: if these
/// pass under the Debug (Apple Development) signed test host, the
/// `keychain-access-groups` entitlement is wired and the access group
/// `49T6U8DQXZ.app.notype` is reachable from our signature. The notarized
/// Developer ID half (spike steps 2–3) is a maintainer task — unit tests
/// can't exercise notarization. See
/// `docs/plans/2026-05-30-001-fix-keychain-data-protection-migration-plan.md`.
///
/// Each test uses a UUID-suffixed service so it never touches the production
/// item (`app.notype.gemini`) and parallel runs don't collide. The access
/// group is fixed by entitlement, so only the service varies for isolation.
final class KeychainStoreTests: XCTestCase {
    private let account = "test-account"

    private func uniqueService() -> String {
        "app.notype.tests.keychainstore.\(UUID().uuidString)"
    }

    // MARK: - Data-protection round trip

    func test_dataProtection_roundTrip() throws {
        let service = uniqueService()
        defer { try? KeychainStore.delete(service: service, account: account) }

        try KeychainStore.save("AIzaSy-secret-value", service: service, account: account)
        let loaded = try KeychainStore.load(service: service, account: account)
        XCTAssertEqual(loaded, "AIzaSy-secret-value")
    }

    func test_dataProtection_deleteThenLoadReturnsNil() throws {
        let service = uniqueService()
        try KeychainStore.save("value", service: service, account: account)
        try KeychainStore.delete(service: service, account: account)
        let loaded = try KeychainStore.load(service: service, account: account)
        XCTAssertNil(loaded)
    }

    func test_dataProtection_upsertReturnsSecondValue() throws {
        let service = uniqueService()
        defer { try? KeychainStore.delete(service: service, account: account) }

        try KeychainStore.save("first", service: service, account: account)
        try KeychainStore.save("second", service: service, account: account)
        let loaded = try KeychainStore.load(service: service, account: account)
        XCTAssertEqual(loaded, "second")
    }

    func test_dataProtection_idempotentDeleteOnMissing() {
        let service = uniqueService()
        // No item was ever written — delete must be a no-op, not a throw.
        XCTAssertNoThrow(try KeychainStore.delete(service: service, account: account))
    }

    func test_load_missingItemReturnsNil() throws {
        let service = uniqueService()
        XCTAssertNil(try KeychainStore.load(service: service, account: account))
    }

    // MARK: - Store isolation (proves the migration reads the right backend)

    func test_storeIsolation_legacyItemInvisibleToDataProtection() throws {
        let service = uniqueService()
        defer { try? KeychainStore.delete(service: service, account: account, store: .legacyFile) }

        // Written to the legacy file keychain...
        try KeychainStore.save("legacy-only", service: service, account: account, store: .legacyFile)

        // ...is NOT visible to a data-protection lookup (different backend).
        XCTAssertNil(try KeychainStore.load(service: service, account: account, store: .dataProtection))

        // ...but IS visible via the legacy backend.
        XCTAssertEqual(
            try KeychainStore.load(service: service, account: account, store: .legacyFile),
            "legacy-only"
        )
    }

    /// macOS keychain isolation is **asymmetric**, and the migration relies on
    /// only one direction (the one `test_storeIsolation_legacyItemInvisibleToDataProtection`
    /// pins): a scoped `.dataProtection` read never surfaces a legacy item, so
    /// the production read path can't accidentally pick up a stale legacy key.
    ///
    /// The reverse does NOT hold and we pin the real behavior here so nobody
    /// assumes bidirectional isolation: an unscoped `.legacyFile` query (no
    /// data-protection flag, no access group) DOES surface the entitled app's
    /// data-protection item. This is harmless for the migration — the only
    /// `.legacyFile` reads are (a) SecretStore's one-shot migration, which runs
    /// *only when the data-protection store is empty* (nothing to leak), and
    /// (b) PromptEvalHarness reading the eval test key. Production reads default
    /// to `.dataProtection` and resolve it first, so the legacy path is never
    /// reached when a data-protection item exists.
    func test_storeIsolation_legacyQuerySurfacesDataProtectionItem_documentedMacOSBehavior() throws {
        let service = uniqueService()
        defer { try? KeychainStore.delete(service: service, account: account, store: .dataProtection) }

        try KeychainStore.save("dp-only", service: service, account: account, store: .dataProtection)

        // Documented (surprising) macOS behavior — NOT relied upon by the migration.
        XCTAssertEqual(
            try KeychainStore.load(service: service, account: account, store: .legacyFile),
            "dp-only"
        )
        // The production-scoped read works as expected.
        XCTAssertEqual(
            try KeychainStore.load(service: service, account: account, store: .dataProtection),
            "dp-only"
        )
    }

    // MARK: - Malformed item

    func test_load_malformedItem_throws() throws {
        let service = uniqueService()
        defer { try? KeychainStore.delete(service: service, account: account, store: .dataProtection) }

        // Seed a raw item with non-UTF-8 data directly, bypassing save().
        // 0xFF is never a valid UTF-8 byte, so decode yields nil →
        // KeychainError.malformedItem.
        let add: [String: Any] = [
            kSecClass as String:                     kSecClassGenericPassword,
            kSecAttrService as String:               service,
            kSecAttrAccount as String:               account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessGroup as String:           KeychainStore.accessGroup,
            kSecValueData as String:                 Data([0xFF, 0xFE, 0xFF]),
            kSecAttrAccessible as String:            kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        try XCTSkipUnless(status == errSecSuccess, "couldn't seed malformed item (status \(status))")

        XCTAssertThrowsError(try KeychainStore.load(service: service, account: account)) { error in
            guard case KeychainStore.KeychainError.malformedItem = error else {
                return XCTFail("expected malformedItem, got \(error)")
            }
        }
    }
}
