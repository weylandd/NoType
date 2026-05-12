import XCTest
@testable import NoType

/// Pins the categorizer:
/// - JSON response parsing (`GeminiClient.parseClassifierResponse`)
/// - actor dedupes concurrent calls for the same bundle
/// - low-confidence / uncategorized results aren't persisted
/// - manual overrides survive a subsequent auto-classification
final class AppCategorizerTests: XCTestCase {

    // MARK: - JSON parsing

    func test_parseClassifierResponse_happyPath() throws {
        let parsed = try GeminiClient.parseClassifierResponse(
            #"{"category": "email", "confidence": "high"}"#
        )
        XCTAssertEqual(parsed.category, .email)
        XCTAssertEqual(parsed.confidence, .high)
    }

    func test_parseClassifierResponse_unknownCategory_collapsesToUncategorized() throws {
        let parsed = try GeminiClient.parseClassifierResponse(
            #"{"category": "wat", "confidence": "high"}"#
        )
        XCTAssertEqual(parsed.category, .uncategorized)
        XCTAssertEqual(parsed.confidence, .high)
    }

    func test_parseClassifierResponse_unknownConfidence_collapsesToLow() throws {
        let parsed = try GeminiClient.parseClassifierResponse(
            #"{"category": "email", "confidence": "tbd"}"#
        )
        XCTAssertEqual(parsed.category, .email)
        XCTAssertEqual(parsed.confidence, .low,
                       "unknown confidence must collapse to .low so we don't cache")
    }

    func test_parseClassifierResponse_stripsFencedCodeBlock() throws {
        let payload = """
        ```json
        {"category": "code", "confidence": "high"}
        ```
        """
        let parsed = try GeminiClient.parseClassifierResponse(payload)
        XCTAssertEqual(parsed.category, .code)
        XCTAssertEqual(parsed.confidence, .high)
    }

    func test_parseClassifierResponse_missingFields_returnsUncategorizedLow() throws {
        let parsed = try GeminiClient.parseClassifierResponse("{}")
        XCTAssertEqual(parsed.category, .uncategorized)
        XCTAssertEqual(parsed.confidence, .low)
    }

    func test_parseClassifierResponse_malformedThrows() {
        XCTAssertThrowsError(try GeminiClient.parseClassifierResponse("not json at all"))
    }

    // MARK: - Actor behaviour

    func test_classifyIfNeeded_persistsHighConfidenceResult() async throws {
        let env = makeEnv()
        await env.client.set(.init(category: .email, confidence: .high))

        await env.categorizer.classifyIfNeeded(
            bundleID: "com.apple.mail",
            displayName: "Mail",
            apiKey: "fake"
        )

        let snap = await env.store.snapshot()
        let record = try XCTUnwrap(snap.categoryAssignments["com.apple.mail"])
        XCTAssertEqual(record.category, .email)
        XCTAssertEqual(record.confidence, .high)
        XCTAssertEqual(record.source, .auto)

        let notified = await env.notifier.records
        XCTAssertEqual(notified.count, 1)
        XCTAssertEqual(notified.first?.bundleID, "com.apple.mail")
    }

    func test_classifyIfNeeded_skipsLowConfidence() async {
        let env = makeEnv()
        await env.client.set(.init(category: .email, confidence: .low))

        await env.categorizer.classifyIfNeeded(
            bundleID: "com.unknown.app",
            displayName: "Some App",
            apiKey: "fake"
        )

        let snap = await env.store.snapshot()
        XCTAssertNil(snap.categoryAssignments["com.unknown.app"],
                     "low-confidence result must not be cached")
        let notified = await env.notifier.records
        XCTAssertEqual(notified.count, 0)
    }

    func test_classifyIfNeeded_skipsUncategorizedResult() async {
        let env = makeEnv()
        await env.client.set(.init(category: .uncategorized, confidence: .high))

        await env.categorizer.classifyIfNeeded(
            bundleID: "com.weird.tool",
            displayName: "Weird Tool",
            apiKey: "fake"
        )

        let snap = await env.store.snapshot()
        XCTAssertNil(snap.categoryAssignments["com.weird.tool"],
                     "explicit uncategorized must not be cached either")
    }

    func test_classifyIfNeeded_skipsWhenAlreadyAssigned() async {
        let env = makeEnv()
        await env.store.setManualAssignment(bundleID: "com.apple.mail", category: .messaging)
        await env.client.set(.init(category: .email, confidence: .high))

        await env.categorizer.classifyIfNeeded(
            bundleID: "com.apple.mail",
            displayName: "Mail",
            apiKey: "fake"
        )

        let callCount = await env.client.callCount
        XCTAssertEqual(callCount, 0, "must not call the classifier when an assignment exists")

        let snap = await env.store.snapshot()
        XCTAssertEqual(snap.categoryAssignments["com.apple.mail"]?.category, .messaging)
        XCTAssertEqual(snap.categoryAssignments["com.apple.mail"]?.source, .manual)
    }

    func test_classifyIfNeeded_skipsWhenApiKeyEmpty() async {
        let env = makeEnv()
        await env.client.set(.init(category: .email, confidence: .high))

        await env.categorizer.classifyIfNeeded(
            bundleID: "com.apple.mail",
            displayName: "Mail",
            apiKey: "  "
        )

        let callCount = await env.client.callCount
        XCTAssertEqual(callCount, 0)
        let snap = await env.store.snapshot()
        XCTAssertNil(snap.categoryAssignments["com.apple.mail"])
    }

    func test_classifyIfNeeded_dedupesConcurrentCalls() async {
        let env = makeEnv()
        // The mock blocks on a continuation so we can observe the dedup
        // window — both calls enter the actor, the first sets inFlight,
        // the second sees it and bails before issuing a network round-trip.
        await env.client.set(
            .init(category: .email, confidence: .high),
            blockUntilResume: true
        )

        async let a: Void = env.categorizer.classifyIfNeeded(
            bundleID: "com.apple.mail",
            displayName: "Mail",
            apiKey: "fake"
        )
        async let b: Void = env.categorizer.classifyIfNeeded(
            bundleID: "com.apple.mail",
            displayName: "Mail",
            apiKey: "fake"
        )
        await env.client.waitForFirstCall()
        await env.client.resume()
        _ = await (a, b)

        let callCount = await env.client.callCount
        XCTAssertEqual(callCount, 1, "two concurrent calls for the same bundle must dedupe into one classifier hit")
    }

    // MARK: - Test environment

    private struct Env {
        let store: InstructionsStore
        let client: MockAppClassifying
        let notifier: NotifierBox
        let categorizer: AppCategorizer
    }

    private func makeEnv() -> Env {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCategorizerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("instructions.json")
        let store = InstructionsStore(url: url)
        let client = MockAppClassifying()
        let notifier = NotifierBox()
        let categorizer = AppCategorizer(
            client: client,
            store: store,
            onAssignmentChanged: { record in
                await notifier.append(record)
            }
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return Env(store: store, client: client, notifier: notifier, categorizer: categorizer)
    }
}

// MARK: - Helpers

/// Records assignments handed to `AppCategorizer`'s `onAssignmentChanged`
/// closure so tests can assert the notification fired exactly once.
private actor NotifierBox {
    private(set) var records: [AppCategoryAssignment] = []

    func append(_ r: AppCategoryAssignment) { records.append(r) }
}

/// Stub classifier used by `AppCategorizerTests`. Records the call count,
/// returns a configured `AppCategoryClassification`, and optionally
/// blocks on a continuation so concurrency tests can observe the in-flight
/// dedup window deterministically.
private actor MockAppClassifying: AppClassifying {
    private var queued: GeminiClient.AppCategoryClassification?
    private(set) var callCount = 0
    private var blockUntilResume = false
    private var firstCallSignal: CheckedContinuation<Void, Never>?
    private var resumeSignal: CheckedContinuation<Void, Never>?

    func set(
        _ result: GeminiClient.AppCategoryClassification,
        blockUntilResume: Bool = false
    ) {
        self.queued = result
        self.blockUntilResume = blockUntilResume
    }

    func waitForFirstCall() async {
        if callCount > 0 { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.firstCallSignal = cont
        }
    }

    func resume() {
        resumeSignal?.resume()
        resumeSignal = nil
    }

    func classifyApp(
        displayName: String,
        bundleID: String,
        apiKey: String
    ) async throws -> GeminiClient.AppCategoryClassification {
        callCount += 1
        firstCallSignal?.resume()
        firstCallSignal = nil

        if blockUntilResume {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                self.resumeSignal = cont
            }
        }

        guard let queued else {
            throw GeminiClient.GeminiError.empty
        }
        return queued
    }
}
