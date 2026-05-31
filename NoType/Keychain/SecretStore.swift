import Foundation
import OSLog

/// Persists the user's Gemini API key. Honours ADR-011 — the key lives in
/// the macOS Keychain via `KeychainStore`. See `NoType/Keychain/CLAUDE.md`.
///
/// Public API is intentionally backend-agnostic so callers (`AppState`,
/// the Settings tab's API section, the onboarding wizard) don't need to
/// know whether storage is the data-protection keychain, the legacy
/// keychain, or a file.
///
/// **Storage + one-shot migration.** New writes go to the **data-protection
/// keychain** (`KeychainStore` default), whose access is gated by the
/// `keychain-access-groups` entitlement rather than the rotating
/// code-signing leaf cert — so the key survives re-signing and never prompts
/// for the login password (see `KeychainStore` doc-comment +
/// `docs/solutions/documentation-gaps/keychain-data-protection-migration-2026-05-30.md`).
/// Earlier builds stored the key in the **legacy file-keychain** or, before
/// that, in a 0600 `~/Library/Application Support/NoType/settings.json`
/// (`{ "geminiKey": "..." }`). `migrateAndResolve()` resolves in order:
///
/// 1. Data-protection keychain → use it (steady state).
/// 2. Legacy file-keychain → migrate into data-protection, return it. If the
///    legacy read *throws* (the `errSecAuthFailed` cert-rotation bug), the
///    value is unrecoverable → `.needsReentry` (UI asks for a one-time paste).
/// 3. Legacy `settings.json` → migrate into data-protection, remove the file.
/// 4. Nothing anywhere → `.absent` (genuine first run).
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

    /// Outcome of resolving the stored key. Lets the UI tell a *stranded*
    /// user (a key exists but the legacy keychain ACL won't let us read it)
    /// apart from a genuine first run — the difference between a calm
    /// "paste your key once" note and a scary "your key is gone" reset.
    enum KeyResolution: Sendable, Equatable {
        /// A usable key (env override, data-protection store, or just migrated).
        case present(String)
        /// A legacy key exists but is unreadable (auth failure). Ask the user
        /// to paste it once; it then lands in the data-protection store.
        case needsReentry
        /// No key found anywhere — first run.
        case absent
    }

    // MARK: - Public API

    static func saveGeminiKey(_ key: String) throws {
        do {
            try KeychainStore.save(key)   // defaults to .dataProtection
        } catch {
            throw SecretError.write(error)
        }
        // Drop the legacy settings.json if it's still around. We deliberately
        // do NOT delete the legacy *keychain* item here — an unscoped legacy
        // delete query can also match the data-protection item we just wrote
        // (asymmetric macOS semantics, pinned by KeychainStoreTests) and would
        // nuke it. The orphaned legacy item is harmless: resolution always
        // reads data-protection first.
        legacyFile.removeIfPresent()
    }

    static func deleteGeminiKey() throws {
        do {
            try KeychainStore.delete()    // .dataProtection
        } catch {
            throw SecretError.write(error)
        }
        legacyFile.removeIfPresent()
    }

    /// Env var wins (dev-only, never persisted), otherwise the
    /// migrate-and-resolve chain. This is the tri-state the UI consumes.
    static func currentKeyResolution() -> KeyResolution {
        if let env = ProcessInfo.processInfo.environment[envVar], !env.isEmpty {
            return .present(env)
        }
        return migrateAndResolve()
    }

    /// Back-compat `String?` accessor used by call sites that only need the
    /// value. `.needsReentry` / `.absent` collapse to `nil`.
    static func loadFromEnvOrFile() -> String? {
        switch currentKeyResolution() {
        case .present(let v):          return v
        case .needsReentry, .absent:   return nil
        }
    }

    // MARK: - Migration + resolution (testable core)

    /// Resolves the key and migrates any pre-data-protection storage forward.
    /// No env handling here — see `currentKeyResolution()`. The keychain reads
    /// / writes and the legacy-file URL are injectable so every branch
    /// (including the unrecoverable `errSecAuthFailed` stranded path) is
    /// deterministically unit-testable.
    ///
    /// We deliberately never delete the legacy *keychain* item after a
    /// successful migration: an unscoped legacy delete query can also match
    /// the freshly written data-protection item and remove it. The orphaned
    /// legacy item is invisible to all later reads (data-protection is checked
    /// first), so leaving it is both safe and correct.
    static func migrateAndResolve(
        service: String = KeychainStore.defaultService,
        account: String = KeychainStore.defaultAccount,
        legacyFileURL: URL = legacyFile.url,
        dpRead: (String, String) throws -> String? = {
            try KeychainStore.load(service: $0, account: $1, store: .dataProtection)
        },
        dpWrite: (String, String, String) throws -> Void = {
            try KeychainStore.save($2, service: $0, account: $1, store: .dataProtection)
        },
        legacyKeychainRead: (String, String) throws -> String? = {
            try KeychainStore.load(service: $0, account: $1, store: .legacyFile)
        }
    ) -> KeyResolution {
        // 1. Data-protection store — steady state.
        do {
            if let value = try dpRead(service, account) {
                return .present(value)
            }
        } catch {
            // A data-protection read shouldn't fail on auth (that's the whole
            // point), but don't strand on a transient hiccup — fall through.
            log.error("data-protection read failed: \(error.localizedDescription, privacy: .public)")
        }

        // 2. Legacy file-keychain — pre-migration item.
        var strandedLegacy = false
        do {
            if let value = try legacyKeychainRead(service, account) {
                migrate(value, service: service, account: account, dpWrite: dpWrite, source: "legacy keychain")
                return .present(value)
            }
        } catch {
            // errSecAuthFailed etc. — the exact cert-rotation bug. The value
            // can't be read, so it can't be migrated; the user pastes once.
            log.error("legacy keychain read failed (stranded): \(error.localizedDescription, privacy: .public)")
            strandedLegacy = true
        }

        // 3. Legacy settings.json file.
        if let value = legacyFile.consumeForMigration(url: legacyFileURL) {
            if migrate(value, service: service, account: account, dpWrite: dpWrite, source: "settings.json") {
                legacyFile.removeIfPresent(url: legacyFileURL)
            }
            return .present(value)
        }

        // 4. Verdict.
        return strandedLegacy ? .needsReentry : .absent
    }

    /// Best-effort write of a migrated value into the data-protection store.
    /// Returns whether the write succeeded — callers use it to decide whether
    /// it's safe to remove the migration source. On failure we still return
    /// the value to the user (no lock-out) and leave the source for retry.
    @discardableResult
    private static func migrate(
        _ value: String,
        service: String,
        account: String,
        dpWrite: (String, String, String) throws -> Void,
        source: String
    ) -> Bool {
        do {
            try dpWrite(service, account, value)
            log.info("migrated key from \(source, privacy: .public) into data-protection keychain")
            return true
        } catch {
            log.error("migration write to data-protection failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Legacy file (one-shot migration)

    private enum legacyFile {
        private static let log = Logger(subsystem: "app.notype", category: "secret")

        private struct Settings: Codable {
            var geminiKey: String?
        }

        static let url: URL = {
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

        /// Read the legacy file once. Returns the key it held, or nil if the
        /// file is missing / unreadable / has no key. Does NOT delete the file
        /// — the caller removes it only after a successful Keychain write.
        static func consumeForMigration(url: URL = url) -> String? {
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

        /// Best-effort delete. Called after a successful Keychain write or on
        /// `deleteGeminiKey()`.
        static func removeIfPresent(url: URL = url) {
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
