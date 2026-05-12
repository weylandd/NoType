import Foundation

/// Cached classification record for a single application. Keyed on
/// `bundleID`. Written by `AppCategorizer` (after a successful classifier
/// call with `source = .auto`) or by `AppState.moveAppToCategory(...)` /
/// equivalents (with `source = .manual`).
///
/// `source` matters because the categorizer is allowed to overwrite an
/// existing `.auto` assignment (re-classification), but **never** an
/// existing `.manual` one — a manual choice is sticky until the user
/// explicitly removes or replaces it. Enforced inside
/// `InstructionsStore.upsertAutoAssignment`.
struct AppCategoryAssignment: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable, Equatable {
        case auto
        case manual
    }

    enum Confidence: String, Codable, Sendable, Equatable {
        case high
        case medium
        case low

        init?(rawClassifierValue raw: String) {
            self.init(rawValue: raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    let bundleID: String
    let category: AppCategory
    let confidence: Confidence
    let classifiedAt: Date
    let source: Source
}
