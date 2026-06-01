import XCTest
import Security
@testable import NoType

/// Pins `SecretStore.migrateAndResolve` — the data-protection → legacy
/// keychain → settings.json resolution chain and the `.present` /
/// `.needsReentry` / `.absent` tri-state. Keychain reads/writes and the
/// settings.json URL are injected so every branch (including the
/// unrecoverable `errSecAuthFailed` stranded path, which can't be forced
/// against the real keychain) is deterministic and touches no real storage.
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

    func test_resolve_dataProtectionPresent_returnsPresent_noMigration() throws {
        var dpWrites = 0
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            dpRead: { _, _ in "dp-key" },
            dpWrite: { _, _, _ in dpWrites += 1 },
            legacyKeychainRead: { _, _ in XCTFail("legacy must not be read when dp present"); return nil }
        )
        XCTAssertEqual(result, .present("dp-key"))
        XCTAssertEqual(dpWrites, 0)
    }

    // MARK: - Migration

    func test_resolve_legacyKeychain_migratesIntoDataProtection() throws {
        var written: [(String, String, String)] = []
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            dpRead: { _, _ in nil },
            dpWrite: { s, a, v in written.append((s, a, v)) },
            legacyKeychainRead: { _, _ in "legacy-key" }
        )
        XCTAssertEqual(result, .present("legacy-key"))
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written.first?.2, "legacy-key")
    }

    func test_resolve_settingsJson_migratesAndRemovesFile() throws {
        let url = try tempSettingsURL(geminiKey: "file-key")
        var dpWrites = 0
        let result = SecretStore.migrateAndResolve(
            service: service, account: account, legacyFileURL: url,
            dpRead: { _, _ in nil },
            dpWrite: { _, _, _ in dpWrites += 1 },
            legacyKeychainRead: { _, _ in nil }
        )
        XCTAssertEqual(result, .present("file-key"))
        XCTAssertEqual(dpWrites, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "settings.json should be removed after a successful migration"
        )
    }

    // MARK: - Stranded vs first run

    func test_resolve_legacyKeychainAuthFailure_returnsNeedsReentry() throws {
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            dpRead: { _, _ in nil },
            dpWrite: { _, _, _ in XCTFail("nothing should be migrated when legacy read fails") },
            legacyKeychainRead: { _, _ in throw KeychainStore.KeychainError.status(errSecAuthFailed) }
        )
        XCTAssertEqual(result, .needsReentry)
    }

    func test_resolve_nothingAnywhere_returnsAbsent() throws {
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            dpRead: { _, _ in nil },
            dpWrite: { _, _, _ in XCTFail("nothing to migrate") },
            legacyKeychainRead: { _, _ in nil }
        )
        XCTAssertEqual(result, .absent)
    }

    // MARK: - Migration write failure leaves the user usable + retryable

    func test_resolve_legacyMigrationWriteFails_stillReturnsValue() throws {
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            dpRead: { _, _ in nil },
            dpWrite: { _, _, _ in throw KeychainStore.KeychainError.status(errSecIO) },
            legacyKeychainRead: { _, _ in "legacy-key" }
        )
        XCTAssertEqual(result, .present("legacy-key"))
    }

    func test_resolve_settingsJsonMigrationWriteFails_keepsFileForRetry() throws {
        let url = try tempSettingsURL(geminiKey: "file-key")
        let result = SecretStore.migrateAndResolve(
            service: service, account: account, legacyFileURL: url,
            dpRead: { _, _ in nil },
            dpWrite: { _, _, _ in throw KeychainStore.KeychainError.status(errSecIO) },
            legacyKeychainRead: { _, _ in nil }
        )
        XCTAssertEqual(result, .present("file-key"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "settings.json must remain for next-launch retry when the migration write fails"
        )
    }

    // MARK: - Deliberate-delete tombstone (no resurrection / no re-prompt)

    func test_resolve_clearedTombstone_dpEmpty_legacyHasKey_returnsAbsent() throws {
        // Migrated user deleted their key: dp empty, legacy orphan still
        // readable, tombstone set. Must NOT resurrect from legacy.
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: "file-key"),
            cleared: true,
            dpRead: { _, _ in nil },
            dpWrite: { _, _, _ in XCTFail("must not migrate after a deliberate delete") },
            legacyKeychainRead: { _, _ in "legacy-orphan" }
        )
        XCTAssertEqual(result, .absent)
    }

    func test_resolve_clearedTombstone_legacyThrows_returnsAbsent_notNeedsReentry() throws {
        // Stranded user who re-pasted then deleted: an unreadable legacy item
        // remains, tombstone set. Must return .absent, NOT re-prompt.
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            cleared: true,
            dpRead: { _, _ in nil },
            dpWrite: { _, _, _ in XCTFail("must not migrate after a deliberate delete") },
            legacyKeychainRead: { _, _ in throw KeychainStore.KeychainError.status(errSecAuthFailed) }
        )
        XCTAssertEqual(result, .absent)
    }

    func test_resolve_clearedTombstone_dpPresent_stillReturnsPresent() throws {
        // Defensive: a present data-protection key wins over the tombstone
        // (the tombstone is consulted only after dp comes back empty).
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            cleared: true,
            dpRead: { _, _ in "dp-key" },
            dpWrite: { _, _, _ in },
            legacyKeychainRead: { _, _ in XCTFail("dp present — legacy must not be read"); return nil }
        )
        XCTAssertEqual(result, .present("dp-key"))
    }

    // MARK: - Transient data-protection read failure falls through to legacy

    func test_resolve_dpReadThrows_legacyHasKey_migratesAndReturnsPresent() throws {
        var written = 0
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            cleared: false,
            dpRead: { _, _ in throw KeychainStore.KeychainError.status(errSecIO) },
            dpWrite: { _, _, _ in written += 1 },
            legacyKeychainRead: { _, _ in "legacy-key" }
        )
        XCTAssertEqual(result, .present("legacy-key"))
        XCTAssertEqual(written, 1)
    }

    func test_resolve_dpReadThrows_legacyThrows_returnsNeedsReentry() throws {
        let result = SecretStore.migrateAndResolve(
            service: service, account: account,
            legacyFileURL: try tempSettingsURL(geminiKey: nil),
            cleared: false,
            dpRead: { _, _ in throw KeychainStore.KeychainError.status(errSecIO) },
            dpWrite: { _, _, _ in XCTFail("nothing to migrate") },
            legacyKeychainRead: { _, _ in throw KeychainStore.KeychainError.status(errSecAuthFailed) }
        )
        XCTAssertEqual(result, .needsReentry)
    }
}
