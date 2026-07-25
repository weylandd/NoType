import XCTest
import Security
@testable import NoType

/// Pins `KeychainStore` behaviour against both backends.
///
/// **Production (`KeychainStore.productionStore`, currently `.legacyFile`)**
/// needs no entitlement, so its round-trip tests run everywhere including CI.
///
/// **`.dataProtection`** only works when the host process carries the
/// `keychain-access-groups` entitlement. The app deliberately does **not**
/// carry it right now — macOS classes it as restricted and AMFI SIGKILLs an
/// unprofiled bundle that declares it (that shipped as v0.1.11; see
/// `docs/solutions/runtime-errors/amfi-restricted-entitlement-launch-kill-2026-07-25.md`).
/// Those tests therefore `XCTSkip` today. They are kept, not deleted: they are
/// the acceptance suite for restoring the data-protection store once a
/// Developer ID provisioning profile is embedded
/// (`docs/solutions/documentation-gaps/developer-id-provisioning-profile-2026-07-25.md`).
///
/// Each test uses a UUID-suffixed service so it never touches the production
/// item (`app.notype.gemini`) and parallel runs don't collide.
final class KeychainStoreTests: XCTestCase {
    private let account = "test-account"

    private func uniqueService() -> String {
        "app.notype.tests.keychainstore.\(UUID().uuidString)"
    }

    /// Skip when the data-protection keychain access group isn't usable in
    /// this environment. Probes with a throwaway save+delete against
    /// `.dataProtection` explicitly; any thrown `OSStatus` (typically
    /// `errSecMissingEntitlement`) means the access group is unavailable.
    private func skipIfDataProtectionUnavailable() throws {
        let probe = "app.notype.tests.keychainstore.probe.\(UUID().uuidString)"
        do {
            try KeychainStore.save("probe", service: probe, account: account, store: .dataProtection)
            try KeychainStore.delete(service: probe, account: account, store: .dataProtection)
        } catch {
            throw XCTSkip(
                "data-protection keychain access group unavailable (\(error.localizedDescription)); "
                + "needs the keychain-access-groups entitlement + an embedded Developer ID "
                + "provisioning profile. Expected to skip while productionStore == .legacyFile."
            )
        }
    }

    // MARK: - Production store round trip (runs everywhere)

    func test_production_roundTrip() throws {
        let service = uniqueService()
        defer { try? KeychainStore.delete(service: service, account: account) }

        try KeychainStore.save("AIzaSy-secret-value", service: service, account: account)
        let loaded = try KeychainStore.load(service: service, account: account)
        XCTAssertEqual(loaded, "AIzaSy-secret-value")
    }

    func test_production_deleteThenLoadReturnsNil() throws {
        let service = uniqueService()
        try KeychainStore.save("value", service: service, account: account)
        try KeychainStore.delete(service: service, account: account)
        XCTAssertNil(try KeychainStore.load(service: service, account: account))
    }

    func test_production_upsertReturnsSecondValue() throws {
        let service = uniqueService()
        defer { try? KeychainStore.delete(service: service, account: account) }

        try KeychainStore.save("first", service: service, account: account)
        try KeychainStore.save("second", service: service, account: account)
        XCTAssertEqual(try KeychainStore.load(service: service, account: account), "second")
    }

    func test_production_idempotentDeleteOnMissing() throws {
        let service = uniqueService()
        // No item was ever written — delete must be a no-op, not a throw.
        XCTAssertNoThrow(try KeychainStore.delete(service: service, account: account))
    }

    func test_production_loadMissingItemReturnsNil() throws {
        XCTAssertNil(try KeychainStore.load(service: uniqueService(), account: account))
    }

    // MARK: - Data-protection round trip (skips until a profile is embedded)

    func test_dataProtection_roundTrip() throws {
        try skipIfDataProtectionUnavailable()
        let service = uniqueService()
        defer { try? KeychainStore.delete(service: service, account: account, store: .dataProtection) }

        try KeychainStore.save("AIzaSy-secret-value", service: service, account: account, store: .dataProtection)
        let loaded = try KeychainStore.load(service: service, account: account, store: .dataProtection)
        XCTAssertEqual(loaded, "AIzaSy-secret-value")
    }

    func test_dataProtection_upsertReturnsSecondValue() throws {
        try skipIfDataProtectionUnavailable()
        let service = uniqueService()
        defer { try? KeychainStore.delete(service: service, account: account, store: .dataProtection) }

        try KeychainStore.save("first", service: service, account: account, store: .dataProtection)
        try KeychainStore.save("second", service: service, account: account, store: .dataProtection)
        XCTAssertEqual(
            try KeychainStore.load(service: service, account: account, store: .dataProtection),
            "second"
        )
    }

    // MARK: - Store isolation (proves the migration reads the right backend)

    func test_storeIsolation_legacyItemInvisibleToDataProtection() throws {
        try skipIfDataProtectionUnavailable()
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
    /// pins): a scoped `.dataProtection` read never surfaces a legacy item.
    ///
    /// The reverse does NOT hold and we pin the real behavior here so nobody
    /// assumes bidirectional isolation: an unscoped `.legacyFile` query (no
    /// data-protection flag, no access group) DOES surface the entitled app's
    /// data-protection item. This is why `SecretStore` never deletes the
    /// migration source after migrating — a cross-store delete can match the
    /// item it just wrote.
    func test_storeIsolation_legacyQuerySurfacesDataProtectionItem_documentedMacOSBehavior() throws {
        try skipIfDataProtectionUnavailable()
        let service = uniqueService()
        defer { try? KeychainStore.delete(service: service, account: account, store: .dataProtection) }

        try KeychainStore.save("dp-only", service: service, account: account, store: .dataProtection)

        // Documented (surprising) macOS behavior — NOT relied upon by the migration.
        XCTAssertEqual(
            try KeychainStore.load(service: service, account: account, store: .legacyFile),
            "dp-only"
        )
        XCTAssertEqual(
            try KeychainStore.load(service: service, account: account, store: .dataProtection),
            "dp-only"
        )
    }

    // MARK: - Malformed item

    func test_load_malformedItem_throws() throws {
        let service = uniqueService()
        defer { try? KeychainStore.delete(service: service, account: account) }

        // Seed a raw item with non-UTF-8 data directly, bypassing save().
        // 0xFF is never a valid UTF-8 byte, so decode yields nil →
        // KeychainError.malformedItem.
        let add: [String: Any] = [
            kSecClass as String:          kSecClassGenericPassword,
            kSecAttrService as String:    service,
            kSecAttrAccount as String:    account,
            kSecValueData as String:      Data([0xFF, 0xFE, 0xFF]),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        try XCTSkipUnless(status == errSecSuccess, "couldn't seed malformed item (status \(status))")

        XCTAssertThrowsError(try KeychainStore.load(service: service, account: account)) { error in
            guard case KeychainStore.KeychainError.malformedItem = error else {
                return XCTFail("expected malformedItem, got \(error)")
            }
        }
    }

    // MARK: - Store / entitlement consistency

    func test_migrationSourceStore_isTheOtherBackend() {
        // The migration must read the store production is NOT using, or an
        // upgrading user's key is never found.
        switch KeychainStore.productionStore {
        case .legacyFile:      XCTAssertEqual(KeychainStore.migrationSourceStore, .dataProtection)
        case .dataProtection:  XCTAssertEqual(KeychainStore.migrationSourceStore, .legacyFile)
        }
    }

    /// **Regression guard for the v0.1.11 launch kill.**
    ///
    /// `keychain-access-groups` is a *restricted* entitlement: AMFI SIGKILLs a
    /// bundle that declares it without an embedded provisioning profile, before
    /// `main()` runs. `codesign --verify`, notarization and `spctl` all pass on
    /// such a bundle, so nothing else catches it.
    ///
    /// The entitlement is therefore only legitimate when the data-protection
    /// store is actually in use. Pinning the biconditional catches both
    /// half-migrations:
    /// - entitlement re-added without flipping `productionStore` → dead weight
    ///   that risks the launch kill for no benefit;
    /// - `productionStore` flipped to `.dataProtection` without the entitlement
    ///   → every keychain read fails with `errSecMissingEntitlement`.
    ///
    /// (Re-adding the entitlement with no profile at all doesn't reach this
    /// assertion — the test host itself fails to launch, which is a louder
    /// signal. `scripts/release.sh` gates the shipped artefact separately.)
    func test_restrictedEntitlement_presentIffDataProtectionIsProduction() {
        XCTAssertEqual(
            Self.hostCarriesAccessGroup(),
            KeychainStore.productionStore == .dataProtection,
            "keychain-access-groups must be declared iff productionStore == .dataProtection. "
            + "Declaring it also requires Contents/embedded.provisionprofile — without one the "
            + "app is SIGKILLed at launch (v0.1.11). See NoType/NoType.entitlements."
        )
    }

    /// The defect itself: v0.1.11 declared the restricted entitlement in a
    /// bundle with **no** embedded provisioning profile. Every static check we
    /// ran (`codesign --verify --deep --strict`, notarization, `spctl --assess`)
    /// passed; the failure only appeared at `exec`, as a SIGKILL.
    ///
    /// Scope caveat — this asserts against the *bundle under test*. A Debug
    /// build signed by Xcode's automatic signing embeds a profile, so this can
    /// pass locally while the Release artefact (hand-signed by
    /// `scripts/release.sh`, which does not embed one) would still be dead.
    /// The authoritative guard for the shipped artefact is the AMFI gate in
    /// `scripts/release.sh`; this test is the fast local half.
    func test_restrictedEntitlement_requiresEmbeddedProvisioningProfile() throws {
        try XCTSkipUnless(
            Self.hostCarriesAccessGroup(),
            "host declares no restricted entitlement — nothing to profile-check"
        )
        let profile = Bundle.main.bundleURL
            .appendingPathComponent("Contents/embedded.provisionprofile")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: profile.path),
            "This bundle declares the restricted entitlement keychain-access-groups but embeds no "
            + "provisioning profile at Contents/embedded.provisionprofile. AMFI will SIGKILL it "
            + "before main() with amfid -413 'No matching profile found' — exactly how v0.1.11 "
            + "bricked every install."
        )
    }

    /// Whether the process hosting these tests declares NoType's keychain
    /// access group in its code-signing entitlements.
    private static func hostCarriesAccessGroup() -> Bool {
        let declaredGroups = SecTaskCreateFromSelf(nil).flatMap {
            SecTaskCopyValueForEntitlement($0, "keychain-access-groups" as CFString, nil) as? [String]
        }
        return declaredGroups?.contains(KeychainStore.accessGroup) ?? false
    }
}
