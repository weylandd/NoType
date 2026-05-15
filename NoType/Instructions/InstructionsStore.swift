import Foundation
import OSLog

/// In-memory mirror of the on-disk `instructions.json` document. Returned
/// by `InstructionsStore.snapshot()` so callers can prime their `@Observable`
/// state without making three separate awaits.
struct InstructionsSnapshot: Sendable, Equatable {
    var userInstruction: String
    var categoryPromptOverrides: [AppCategory: String]
    var categoryAssignments: [String: AppCategoryAssignment]

    static let empty = InstructionsSnapshot(
        userInstruction: "",
        categoryPromptOverrides: [:],
        categoryAssignments: [:]
    )
}

/// Persistence actor for the user's global instruction, per-category
/// prompt overrides, and cached app→category assignments.
///
/// Schema (`instructions.json`) is a single versioned envelope:
///
/// ```jsonc
/// {
///   "version": 1,
///   "userInstruction": "",
///   "categoryPromptOverrides": { "email": "..." },
///   "categoryAssignments": {
///     "com.apple.mail": { "bundleID": ..., "category": ..., ... }
///   }
/// }
/// ```
///
/// Same operational shape as `HistoryStore`: actor isolation, atomic
/// write, corruption recovery via `.corrupt-<ts>` rename. Caller code
/// (AppState mirror) maintains the SwiftUI-facing snapshot and persists
/// changes via the async methods on this actor.
actor InstructionsStore {
    private static let log = Logger(subsystem: "app.notype", category: "instructions")
    private static let currentVersion = 1

    private let url: URL
    private let encoder = JSONFileStorage.makeEncoder()
    private let decoder = JSONFileStorage.makeDecoder()

    init(url: URL? = nil) {
        self.url = url ?? JSONFileStorage.appSupportURL(filename: "instructions.json")
    }

    // MARK: - Read

    func snapshot() -> InstructionsSnapshot {
        let envelope: Envelope? = JSONFileStorage.read(
            from: url,
            as: Envelope.self,
            decoder: decoder,
            log: Self.log,
            storeName: "instructions"
        )
        return envelope?.toSnapshot() ?? .empty
    }

    // MARK: - Global user instruction

    /// Replace the global user-instruction string. Trims trailing/leading
    /// whitespace+newlines so an empty-after-trim value is treated as
    /// "no instruction" (the prompt section gets omitted entirely).
    @discardableResult
    func updateUserInstruction(_ text: String) -> InstructionsSnapshot {
        var snap = snapshot()
        snap.userInstruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        write(snap)
        return snap
    }

    // MARK: - Category prompt overrides

    /// Set a custom prompt for a category. Passing `nil` or an
    /// empty-after-trim string clears the override (the UI is expected
    /// to fall back to `AppCategory.defaultPrompt`).
    @discardableResult
    func setCategoryPromptOverride(_ category: AppCategory, prompt: String?) -> InstructionsSnapshot {
        var snap = snapshot()
        let cleaned = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleaned, !cleaned.isEmpty {
            snap.categoryPromptOverrides[category] = cleaned
        } else {
            snap.categoryPromptOverrides.removeValue(forKey: category)
        }
        write(snap)
        return snap
    }

    // MARK: - Assignments

    func assignment(for bundleID: String) -> AppCategoryAssignment? {
        snapshot().categoryAssignments[bundleID]
    }

    /// Write an auto-generated assignment from the categorizer. Refuses
    /// to overwrite an existing `.manual` record — manual choices are
    /// sticky. Returns the resulting (possibly unchanged) assignment so
    /// callers can mirror it onto the main-actor state.
    @discardableResult
    func upsertAutoAssignment(_ assignment: AppCategoryAssignment) -> AppCategoryAssignment {
        precondition(assignment.source == .auto, "use setManualAssignment for manual")
        var snap = snapshot()
        if let existing = snap.categoryAssignments[assignment.bundleID],
           existing.source == .manual {
            // Don't overwrite a manual decision. Return what's there.
            return existing
        }
        snap.categoryAssignments[assignment.bundleID] = assignment
        write(snap)
        return assignment
    }

    /// Set a manual assignment from the UI. Always wins — no precondition
    /// on existing state.
    @discardableResult
    func setManualAssignment(
        bundleID: String,
        category: AppCategory,
        now: Date = Date()
    ) -> AppCategoryAssignment {
        var snap = snapshot()
        let record = AppCategoryAssignment(
            bundleID: bundleID,
            category: category,
            confidence: .high,
            classifiedAt: now,
            source: .manual
        )
        snap.categoryAssignments[bundleID] = record
        write(snap)
        return record
    }

    /// Remove the cached assignment for `bundleID`. The next session in
    /// that app will re-trigger classification. No-op if missing.
    @discardableResult
    func removeAssignment(bundleID: String) -> InstructionsSnapshot {
        var snap = snapshot()
        if snap.categoryAssignments.removeValue(forKey: bundleID) != nil {
            write(snap)
        }
        return snap
    }

    // MARK: - Write

    private func write(_ snap: InstructionsSnapshot) {
        let envelope = Envelope(from: snap, version: Self.currentVersion)
        JSONFileStorage.write(envelope, to: url, encoder: encoder, log: Self.log, storeName: "instructions")
    }

    // MARK: - On-disk envelope

    /// On-disk Codable shape. `categoryPromptOverrides` keys are the
    /// `AppCategory` raw strings; we decode into a `[String: String]`
    /// then translate to `[AppCategory: String]` so an unknown key in a
    /// forward-version file is dropped instead of crashing decode.
    private struct Envelope: Codable {
        let version: Int
        let userInstruction: String
        let categoryPromptOverrides: [String: String]
        let categoryAssignments: [String: AppCategoryAssignment]

        init(from snap: InstructionsSnapshot, version: Int) {
            self.version = version
            self.userInstruction = snap.userInstruction
            self.categoryPromptOverrides = Dictionary(
                uniqueKeysWithValues: snap.categoryPromptOverrides.map { ($0.key.rawValue, $0.value) }
            )
            self.categoryAssignments = snap.categoryAssignments
        }

        func toSnapshot() -> InstructionsSnapshot {
            var overrides: [AppCategory: String] = [:]
            for (raw, prompt) in categoryPromptOverrides {
                if let cat = AppCategory(rawValue: raw) {
                    overrides[cat] = prompt
                }
            }
            return InstructionsSnapshot(
                userInstruction: userInstruction,
                categoryPromptOverrides: overrides,
                categoryAssignments: categoryAssignments
            )
        }
    }
}
