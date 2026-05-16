import Foundation
import OSLog

/// Persists the user's Gemini API key. Honours ADR-011 — the key lives in
/// the macOS Keychain via `KeychainStore`. See `NoType/Keychain/CLAUDE.md`.
///
/// Public API is intentionally backend-agnostic so callers (`AppState`,
/// `SettingsView`, the onboarding wizard) don't need to know whether
/// storage is Keychain, a file, or anything else.
///
/// **One-shot migration from legacy storage.** Earlier builds stored the
/// key in `~/Library/Application Support/NoType/settings.json` (a 0600
/// JSON file — see ADR-011 deviation note in `Keychain/CLAUDE.md`). On
/// first launch of a Keychain-backed build:
///
/// 1. `loadGeminiKey()` reads the Keychain first.
/// 2. If the Keychain has nothing AND the legacy file has a key, we copy
///    the key into the Keychain and remove the legacy file. The user
///    keeps their key without a re-paste.
/// 3. Subsequent loads hit the Keychain only.
///
/// The legacy `settings.json` shape was `{ "geminiKey": "..." }`. Future
/// settings will not go in that file — Keychain holds secrets; non-secret
/// settings are tracked under `UserDefaults` (the existing
/// `notype.selectedInputDeviceUID` and `notype.onboarding.*` keys).
enum SecretStore {
    private static let log = Logger(subsystem: "app.notype", category: "secret")
    private static let envVar = "NOTYPE_GEMINI_KEY"

    enum SecretError: Error, LocalizedError {
        case write(Error)

        var errorDescription: String? {
            switch self {
            case .write(let e): "Couldn't save the key: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Public API

    static func saveGeminiKey(_ key: String) throws {
        do {
            try KeychainStore.save(key)
        } catch {
            throw SecretError.write(error)
        }
        // If the legacy file is still around from a pre-Keychain build,
        // remove it now that we have the key safely in the Keychain.
        legacyFile.removeIfPresent()
    }

    private static func loadGeminiKey() -> String? {
        do {
            if let kc = try KeychainStore.load() {
                return kc
            }
        } catch {
            // Don't bail yet — a transient Keychain read failure on a
            // fresh first-launch (locked keychain, ACL hiccup) must
            // still fall through to the legacy-file migration. ADR-011
            // guarantees no re-paste for upgrading users.
            Self.log.error("keychain read failed, falling through to legacy file: \(error.localizedDescription, privacy: .public)")
        }
        // Keychain miss (or transient throw) → check the legacy file
        // once. If it has a key, migrate it into the Keychain and clean
        // the file up.
        if let migrated = legacyFile.consumeForMigration() {
            do {
                try KeychainStore.save(migrated)
                Self.log.info("migrated legacy settings.json key into Keychain")
                return migrated
            } catch {
                // Migration write failed — return the migrated value
                // anyway so the user isn't suddenly locked out, but
                // surface the failure to the caller's logs.
                Self.log.error("legacy key migration to Keychain failed: \(error.localizedDescription, privacy: .public)")
                return migrated
            }
        }
        return nil
    }

    static func deleteGeminiKey() throws {
        do {
            try KeychainStore.delete()
        } catch {
            throw SecretError.write(error)
        }
        legacyFile.removeIfPresent()
    }

    /// `NOTYPE_GEMINI_KEY` env var wins over stored keys (handy for
    /// ephemeral CI or local-only runs). Never persisted from env into
    /// the Keychain.
    static func loadFromEnvOrFile() -> String? {
        if let env = ProcessInfo.processInfo.environment[envVar], !env.isEmpty {
            return env
        }
        return loadGeminiKey()
    }

    // MARK: - Legacy file (one-shot migration)

    private enum legacyFile {
        private static let log = Logger(subsystem: "app.notype", category: "secret")

        private struct Settings: Codable {
            var geminiKey: String?
        }

        private static let url: URL = {
            let appSupport = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.temporaryDirectory
            let dir = appSupport.appendingPathComponent("NoType", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("settings.json")
        }()

        /// Read the legacy file once. Returns the key it held, or nil if
        /// the file is missing / unreadable / has no key. Does NOT delete
        /// the file — the caller does that after a successful Keychain
        /// write (so a partial migration doesn't lose the user's key).
        static func consumeForMigration() -> String? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let data = try Data(contentsOf: url)
                let settings = try JSONDecoder().decode(Settings.self, from: data)
                guard let k = settings.geminiKey, !k.isEmpty else { return nil }
                return k
            } catch {
                Self.log.error("legacy settings.json unreadable: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        /// Best-effort delete. Called after a successful Keychain write
        /// or on `deleteGeminiKey()`.
        static func removeIfPresent() {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.removeItem(at: url)
                Self.log.info("legacy settings.json removed (key now in Keychain)")
            } catch {
                Self.log.error("legacy settings.json removal failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
