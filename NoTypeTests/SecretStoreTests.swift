import XCTest
import Security
@testable import NoType

/// Pins `SecretStore.migrateAndResolve` — the production → migration-source →
/// settings.json resolution chain and the `.present` / `.needsReentry` /
/// `.absent` tri-state. Keychain reads/writes and the settings.json URL are
/// injected so every branch (including the unrecoverable `errSecAuthFailed`
/// stranded path, which can't be forced against the real keychain) is
/// deterministic and touches no real storage.
///
/// The seams are named for their *role* (`primaryRead` / `fallbackRead`), not
/// for a backend, because which concrete store is which flips with
/// `KeychainStore.productionStore`. These tests therefore stay valid across
/// that flip.
final class SecretStoreTests: XCTestCase {
    private let service = "app.notype.tests.secretstore"
    private let account = "default"

    override func setUp() {
        super.setUp()
        // Reset the deliberate-delete tombstone so the migration tests that
        // rely on the default `cleared` parameter aren't affected by ambient
        // UserDefaults state. The tombstone tests below pass `cleared:`
        // explicitly and don't depend on this.
        SecretStore.deliberatelyCleared = false
    }

    /// A throwaway settings.json URL. When `geminiKey` is non-nil the file is
    /// written with that key; otherwise the path simply doesn't exist.
    private func tempSettingsURL(geminiKey: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notype-secretstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        if let key = geminiKey {
            let data = try JSONSerialization.data(withJSONObject: ["geminiKey": key])
            try data.write(to: url)
        }
        return url
    }

    // MARK: - Steady state

    func test_resolve_primaryPresent_returnsPresent_noMigration() throws {
        var writes = 0
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            primaryRead: { _, _ in "primary-key" },
            primaryWrite: { _, _, _ in writes += 1 },
            fallbackRead: { _, _ in XCTFail("fallback must not be read when primary present"); return nil }
        )
        XCTAssertEqual(result, .present("primary-key"))
        XCTAssertEqual(writes, 0)
    }

    // MARK: - Migration

    func test_resolve_fallbackKeychain_migratesIntoPrimary() throws {
        var written: [(String, String, String)] = []
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            primaryRead: { _, _ in nil },
            primaryWrite: { s, a, v in written.append((s, a, v)) },
            fallbackRead: { _, _ in "fallback-key" }
        )
        XCTAssertEqual(result, .present("fallback-key"))
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written.first?.2, "fallback-key")
    }

    func test_resolve_settingsJson_migratesAndRemovesFile() throws {
        let url = try tempSettingsURL(geminiKey: "file-key")
        var writes = 0
        let result = SecretStore.migrateAndResolve(
            service: service, account: account, legacyFileURL: url,
            primaryRead: { _, _ in nil },
            primaryWrite: { _, _, _ in writes += 1 },
            fallbackRead: { _, _ in nil }
        )
        XCTAssertEqual(result, .present("file-key"))
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "settings.json should be removed after a successful migration"
        )
    }

    // MARK: - Stranded vs first run

    func test_resolve_fallbackAuthFailure_returnsNeedsReentry() throws {
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            primaryRead: { _, _ in nil },
            primaryWrite: { _, _, _ in XCTFail("nothing should be migrated when the read fails") },
            fallbackRead: { _, _ in throw KeychainStore.KeychainError.status(errSecAuthFailed) }
        )
        XCTAssertEqual(result, .needsReentry)
    }

    func test_resolve_primaryAuthFailure_returnsNeedsReentry() throws {
        // The production store is now the one whose ACL is pinned to the
        // signing cert, so it is the likeliest source of errSecAuthFailed.
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            primaryRead: { _, _ in throw KeychainStore.KeychainError.status(errSecAuthFailed) },
            primaryWrite: { _, _, _ in XCTFail("nothing to migrate") },
            fallbackRead: { _, _ in nil }
        )
        XCTAssertEqual(result, .needsReentry)
    }

    func test_resolve_nothingAnywhere_returnsAbsent() throws {
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            primaryRead: { _, _ in nil },
            primaryWrite: { _, _, _ in XCTFail("nothing to migrate") },
            fallbackRead: { _, _ in nil }
        )
        XCTAssertEqual(result, .absent)
    }

    // MARK: - Stranding classification (regression: v0.1.11 aftermath)

    /// The migration-source store is *routinely* unavailable — with the
    /// production store on `.legacyFile`, every data-protection read returns
    /// `errSecMissingEntitlement` because the app carries no
    /// `keychain-access-groups` entitlement. That must read as "backend
    /// unavailable" (quiet fall-through to `.absent`), NOT as "your key is
    /// stranded" — otherwise every genuine first-run user is shown the
    /// "paste your key once" note instead of onboarding.
    func test_resolve_fallbackMissingEntitlement_returnsAbsent_notNeedsReentry() throws {
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            primaryRead: { _, _ in nil },
            primaryWrite: { _, _, _ in XCTFail("nothing to migrate") },
            fallbackRead: { _, _ in throw KeychainStore.KeychainError.status(errSecMissingEntitlement) }
        )
        XCTAssertEqual(result, .absent)
    }

    func test_isStrandingFailure_classification() {
        // "Item is there, we can't read it" → strand the user.
        XCTAssertTrue(SecretStore.isStrandingFailure(
            KeychainStore.KeychainError.status(errSecAuthFailed)))
        XCTAssertTrue(SecretStore.isStrandingFailure(
            KeychainStore.KeychainError.status(errSecInteractionNotAllowed)))
        // "This backend isn't available / nothing to see" → quiet fall-through.
        XCTAssertFalse(SecretStore.isStrandingFailure(
            KeychainStore.KeychainError.status(errSecMissingEntitlement)))
        XCTAssertFalse(SecretStore.isStrandingFailure(
            KeychainStore.KeychainError.status(errSecItemNotFound)))
        XCTAssertFalse(SecretStore.isStrandingFailure(
            KeychainStore.KeychainError.status(errSecIO)))
        XCTAssertFalse(SecretStore.isStrandingFailure(
            KeychainStore.KeychainError.malformedItem))
    }

    /// A transient non-stranding failure on the production store must still
    /// let the fallback + settings.json branches run.
    func test_resolve_primaryTransientFailure_fallbackHasKey_migratesAndReturnsPresent() throws {
        var written = 0
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            cleared: false,
            primaryRead: { _, _ in throw KeychainStore.KeychainError.status(errSecIO) },
            primaryWrite: { _, _, _ in written += 1 },
            fallbackRead: { _, _ in "fallback-key" }
        )
        XCTAssertEqual(result, .present("fallback-key"))
        XCTAssertEqual(written, 1)
    }

    func test_resolve_bothReadsThrowStranding_returnsNeedsReentry() throws {
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            cleared: false,
            primaryRead: { _, _ in throw KeychainStore.KeychainError.status(errSecAuthFailed) },
            primaryWrite: { _, _, _ in XCTFail("nothing to migrate") },
            fallbackRead: { _, _ in throw KeychainStore.KeychainError.status(errSecAuthFailed) }
        )
        XCTAssertEqual(result, .needsReentry)
    }

    /// A stranding failure on the production read must not be masked by a
    /// later non-stranding failure on the fallback read.
    func test_resolve_primaryStrands_fallbackUnavailable_stillNeedsReentry() throws {
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            cleared: false,
            primaryRead: { _, _ in throw KeychainStore.KeychainError.status(errSecAuthFailed) },
            primaryWrite: { _, _, _ in XCTFail("nothing to migrate") },
            fallbackRead: { _, _ in throw KeychainStore.KeychainError.status(errSecMissingEntitlement) }
        )
        XCTAssertEqual(result, .needsReentry)
    }

    // MARK: - Migration write failure leaves the user usable + retryable

    func test_resolve_fallbackMigrationWriteFails_stillReturnsValue() throws {
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            primaryRead: { _, _ in nil },
            primaryWrite: { _, _, _ in throw KeychainStore.KeychainError.status(errSecIO) },
            fallbackRead: { _, _ in "fallback-key" }
        )
        XCTAssertEqual(result, .present("fallback-key"))
    }

    func test_resolve_settingsJsonMigrationWriteFails_keepsFileForRetry() throws {
        let url = try tempSettingsURL(geminiKey: "file-key")
        let result = SecretStore.migrateAndResolve(
            service: service, account: account, legacyFileURL: url,
            primaryRead: { _, _ in nil },
            primaryWrite: { _, _, _ in throw KeychainStore.KeychainError.status(errSecIO) },
            fallbackRead: { _, _ in nil }
        )
        XCTAssertEqual(result, .present("file-key"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "settings.json must remain for next-launch retry when the migration write fails"
        )
    }

    // MARK: - Deliberate-delete tombstone (no resurrection / no re-prompt)

    func test_resolve_clearedTombstone_primaryEmpty_fallbackHasKey_returnsAbsent() throws {
        // Migrated user deleted their key: production empty, an orphan in the
        // other store still readable, tombstone set. Must NOT resurrect it.
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: "file-key"),
            cleared: true,
            primaryRead: { _, _ in nil },
            primaryWrite: { _, _, _ in XCTFail("must not migrate after a deliberate delete") },
            fallbackRead: { _, _ in "orphan" }
        )
        XCTAssertEqual(result, .absent)
    }

    func test_resolve_clearedTombstone_primaryStrands_returnsAbsent_notNeedsReentry() throws {
        // Stranded user who re-pasted then deleted: an unreadable item remains,
        // tombstone set. Must return .absent, NOT re-prompt.
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            cleared: true,
            primaryRead: { _, _ in throw KeychainStore.KeychainError.status(errSecAuthFailed) },
            primaryWrite: { _, _, _ in XCTFail("must not migrate after a deliberate delete") },
            fallbackRead: { _, _ in XCTFail("tombstone short-circuits before the fallback"); return nil }
        )
        XCTAssertEqual(result, .absent)
    }

    func test_resolve_clearedTombstone_primaryPresent_stillReturnsPresent() throws {
        // Defensive: a present production key wins over the tombstone (the
        // tombstone is consulted only after the production store comes back
        // empty).
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            cleared: true,
            primaryRead: { _, _ in "primary-key" },
            primaryWrite: { _, _, _ in },
            fallbackRead: { _, _ in XCTFail("primary present — fallback must not be read"); return nil }
        )
        XCTAssertEqual(result, .present("primary-key"))
    }
}
