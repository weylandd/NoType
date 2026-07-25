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
/// **Storage + one-shot migration.** New writes go to
/// `KeychainStore.productionStore` (currently the **legacy file-keychain** —
/// the data-protection store needs a restricted entitlement the app cannot
/// currently carry; see that property's doc-comment). Keys written under a
/// *previous* production store, or by builds predating the Keychain entirely
/// (a 0600 `~/Library/Application Support/NoType/settings.json` holding
/// `{ "geminiKey": "..." }`), are migrated forward on first read.
/// `migrateAndResolve()` resolves in order:
///
/// 1. Production keychain → use it (steady state).
/// 2. Deliberate-delete tombstone set → `.absent`, no resurrection.
/// 3. `KeychainStore.migrationSourceStore` (the other backend) → migrate into
///    production, return it.
/// 4. Legacy `settings.json` → migrate into production, remove the file.
/// 5. Nothing anywhere → `.absent` (genuine first run), or `.needsReentry`
///    when a read failed in a way that means "an item is there but we can't
///    read it" (see `isStrandingFailure`).
///
/// The order is store-neutral on purpose: it reads `productionStore` /
/// `migrationSourceStore` rather than naming a backend, so restoring the
/// data-protection store reverses the migration direction automatically
/// instead of needing this chain rewritten again.
enum SecretStore {
    private static let log = Logger(subsystem: "app.notype", category: "secret")
    private static let envVar = "NOTYPE_GEMINI_KEY"
    private static let clearedKey = "notype.keychain.cleared"

    /// Tombstone for a deliberate delete. Set by `deleteGeminiKey`, cleared by
    /// `saveGeminiKey`. While set, `migrateAndResolve` returns `.absent`
    /// instead of resurrecting / re-prompting from a legacy source — a
    /// deliberate delete must NOT be undone by the migration re-reading an
    /// orphaned (still-readable) or unreadable legacy keychain item. Without
    /// this, a user who migrated from the legacy keychain and then deleted
    /// their key would have it silently re-migrated on the next launch.
    /// Persisted (survives relaunch) and intentionally NOT cleared by an
    /// onboarding reset — the key itself survives a wizard reset, so its
    /// tombstone must too.
    static var deliberatelyCleared: Bool {
        get { UserDefaults.standard.bool(forKey: clearedKey) }
        set { UserDefaults.standard.set(newValue, forKey: clearedKey) }
    }

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
            try KeychainStore.save(key)   // KeychainStore.productionStore
        } catch {
            throw SecretError.write(error)
        }
        // Drop the legacy settings.json if it's still around. We deliberately
        // do NOT touch the *other* keychain backend here — macOS keychain
        // isolation is asymmetric (an unscoped legacy query also matches a
        // data-protection item, pinned by KeychainStoreTests), so a cross-store
        // delete can nuke the item we just wrote. An orphaned item in the other
        // store is harmless: resolution reads the production store first, and
        // the tombstone (below) blocks resurrection after a delete.
        legacyFile.removeIfPresent()
        deliberatelyCleared = false
    }

    static func deleteGeminiKey() throws {
        do {
            try KeychainStore.delete()    // KeychainStore.productionStore
        } catch {
            throw SecretError.write(error)
        }
        legacyFile.removeIfPresent()
        // Tombstone the delete so the migration can't resurrect the key from
        // an orphaned (or unreadable) legacy item on the next resolution.
        deliberatelyCleared = true
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

    /// Whether a keychain read failure means *"an item is probably there but
    /// we can't read it"* — the user must paste their key once
    /// (`.needsReentry`) — rather than *"this backend isn't available at all"*,
    /// which is a quiet fall-through.
    ///
    /// The distinction matters because `migrationSourceStore` is routinely
    /// unavailable: with the production store on `.legacyFile`, every
    /// data-protection read returns `errSecMissingEntitlement` (the app carries
    /// no `keychain-access-groups` entitlement — see `KeychainStore`). Treating
    /// that as stranding would show every genuine first-run user a "paste your
    /// key once" note instead of onboarding.
    ///
    /// The status set lives in `KeychainStore.isStrandingStatus` so the read
    /// side (this classification) and the write side (`KeychainStore.save`'s
    /// stranded-item recovery) can never disagree about which failures mean
    /// "the item is there but unusable".
    static func isStrandingFailure(_ error: Error) -> Bool {
        guard case KeychainStore.KeychainError.status(let status) = error else { return false }
        return KeychainStore.isStrandingStatus(status)
    }

    /// Resolves the key and migrates any older storage forward. No env
    /// handling here — see `currentKeyResolution()`. The keychain reads /
    /// writes and the legacy-file URL are injectable so every branch
    /// (including the unrecoverable `errSecAuthFailed` stranded path, which
    /// can't be forced against the real keychain) is deterministically
    /// unit-testable.
    ///
    /// We deliberately never delete the migration source after a successful
    /// migration: macOS keychain isolation is asymmetric, so a cross-store
    /// delete query can also match the item we just wrote. An orphaned source
    /// item is invisible to later reads (the production store resolves first)
    /// and the `cleared` tombstone blocks resurrection after a delete, so
    /// leaving it is both safe and correct.
    static func migrateAndResolve(
        service: String = KeychainStore.defaultService,
        account: String = KeychainStore.defaultAccount,
        legacyFileURL: URL = legacyFile.url,
        cleared: Bool = deliberatelyCleared,
        primaryRead: (String, String) throws -> String? = {
            try KeychainStore.load(service: $0, account: $1, store: KeychainStore.productionStore)
        },
        // (service, account, value)
        primaryWrite: (String, String, String) throws -> Void = {
            try KeychainStore.save($2, service: $0, account: $1, store: KeychainStore.productionStore)
        },
        fallbackRead: (String, String) throws -> String? = {
            try KeychainStore.load(service: $0, account: $1, store: KeychainStore.migrationSourceStore)
        }
    ) -> KeyResolution {
        var stranded = false

        // 1. Production store — steady state.
        do {
            if let value = try primaryRead(service, account) {
                return .present(value)
            }
        } catch {
            log.error("production keychain read failed: \(error.localizedDescription, privacy: .public)")
            stranded = isStrandingFailure(error)
        }

        // 2. Deliberate-delete tombstone. The user explicitly cleared their key
        // and the production store is empty — do NOT resurrect it from, or
        // re-prompt because of, an orphaned/unreadable item in another store.
        if cleared { return .absent }

        // 3. The other keychain backend — a key written under a previous
        // production store.
        do {
            if let value = try fallbackRead(service, account) {
                migrate(value, service: service, account: account, primaryWrite: primaryWrite, source: "migration-source keychain")
                return .present(value)
            }
        } catch {
            log.error("migration-source keychain read failed: \(error.localizedDescription, privacy: .public)")
            stranded = stranded || isStrandingFailure(error)
        }

        // 4. Legacy settings.json file.
        if let value = legacyFile.consumeForMigration(url: legacyFileURL) {
            if migrate(value, service: service, account: account, primaryWrite: primaryWrite, source: "settings.json") {
                legacyFile.removeIfPresent(url: legacyFileURL)
            }
            return .present(value)
        }

        // 5. Verdict.
        return stranded ? .needsReentry : .absent
    }

    /// Best-effort write of a migrated value into the production store.
    /// Returns whether the write succeeded — callers use it to decide whether
    /// it's safe to remove the migration source. On failure we still return
    /// the value to the user (no lock-out) and leave the source for retry.
    @discardableResult
    private static func migrate(
        _ value: String,
        service: String,
        account: String,
        primaryWrite: (String, String, String) throws -> Void,
        source: String
    ) -> Bool {
        do {
            try primaryWrite(service, account, value)
            log.info("migrated key from \(source, privacy: .public) into the production keychain")
            return true
        } catch {
            log.error("migration write to the production keychain failed: \(error.localizedDescription, privacy: .public)")
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
