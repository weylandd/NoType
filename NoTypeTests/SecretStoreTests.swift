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
}
