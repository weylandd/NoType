import Foundation
import OSLog

/// Abstracts the categorizer's REST call so unit tests can stub it
/// without spinning up a network stack. The real implementation is
/// `GeminiClient`; tests use a synthetic `MockAppClassifying`.
protocol AppClassifying: Sendable {
    func classifyApp(
        displayName: String,
        bundleID: String,
        apiKey: String
    ) async throws -> GeminiClient.AppCategoryClassification
}

extension GeminiClient: AppClassifying {}

/// Side-channel notifier so the `@MainActor` `AppState` mirror can update
/// when the categorizer persists a new auto-assignment in the background.
/// The categorizer doesn't depend on AppState directly — the closure
/// hops back to the main actor on the caller's side.
typealias AssignmentChangedHandler = @Sendable (AppCategoryAssignment) async -> Void

/// Owns the fire-and-forget classification path: on session start the
/// recording layer calls `classifyIfNeeded(...)` with the active app's
/// bundle id; the categorizer dedupes concurrent calls for the same
/// bundle, sends one classify request to Gemini, writes the result to
/// `InstructionsStore`, and notifies the AppState mirror.
///
/// Doesn't block recording — the current session uses whatever category
/// was already cached (or `.uncategorized` when none). The next session
/// in that app sees the cached value.
actor AppCategorizer {
    private static let log = Logger(subsystem: "app.notype", category: "categorizer")

    private let client: any AppClassifying
    private let store: InstructionsStore
    private var onAssignmentChanged: AssignmentChangedHandler

    /// Bundle ids whose classifier call is currently in flight on this
    /// categorizer. Re-checked after each `await` to deduplicate
    /// quick-fire repeat sessions in the same app.
    private var inFlight: Set<String> = []

    init(
        client: any AppClassifying,
        store: InstructionsStore,
        onAssignmentChanged: @escaping AssignmentChangedHandler = { _ in }
    ) {
        self.client = client
        self.store = store
        self.onAssignmentChanged = onAssignmentChanged
    }

    /// Replace the change handler post-construction. Used by `AppState`
    /// to wire its main-actor mirror after the categorizer has been
    /// passed into `AppState.init` (resolves the construction-order
    /// catch-22 between AppState and AppCategorizer).
    func setOnAssignmentChanged(_ handler: @escaping AssignmentChangedHandler) {
        self.onAssignmentChanged = handler
    }

    /// Kick off a classification for `bundleID` if (a) we don't already
    /// have a cached assignment, and (b) no call for that bundle is in
    /// flight. Returns immediately to the caller — the actual work
    /// happens on this actor.
    ///
    /// `apiKey` is the caller's responsibility (typically read from
    /// `AppState.currentAPIKey`); the categorizer doesn't reach into
    /// `SecretStore` on its own.
    func classifyIfNeeded(
        bundleID: String,
        displayName: String,
        apiKey: String
    ) async {
        let trimmedBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundle.isEmpty, !trimmedKey.isEmpty else { return }

        // Already cached? Either via a previous auto classification or
        // a manual user override — both block re-classification.
        if await store.assignment(for: trimmedBundle) != nil { return }
        if inFlight.contains(trimmedBundle) { return }

        inFlight.insert(trimmedBundle)
        defer { inFlight.remove(trimmedBundle) }

        let result: GeminiClient.AppCategoryClassification
        do {
            result = try await client.classifyApp(
                displayName: displayName,
                bundleID: trimmedBundle,
                apiKey: trimmedKey
            )
        } catch {
            Self.log.error(
                "classify failed for \(trimmedBundle, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        // Honest "I don't know" — don't poison the cache; the next
        // session in this app will retry.
        if result.confidence == .low {
            Self.log.info("classifier low-confidence for \(trimmedBundle, privacy: .public) — not caching")
            return
        }
        // The classifier may legitimately return `.uncategorized` when
        // it can't place the app despite web search. We treat that the
        // same as low confidence: do not cache.
        if result.category == .uncategorized {
            Self.log.info("classifier returned uncategorized for \(trimmedBundle, privacy: .public) — not caching")
            return
        }

        let record = AppCategoryAssignment(
            bundleID: trimmedBundle,
            category: result.category,
            confidence: result.confidence,
            classifiedAt: Date(),
            source: .auto
        )
        let written = await store.upsertAutoAssignment(record)
        await onAssignmentChanged(written)
    }
}
