import XCTest
@testable import NoType

/// Pins the permanent Objective-C exception interceptor.
///
/// The interceptor exists because nothing else in the process observes an
/// `NSException` that AppKit swallows: `NSSetUncaughtExceptionHandler` does not
/// fire (AppKit catches first) and the eventual crash report faults in an
/// unrelated frame hundreds of milliseconds later. See
/// `docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`.
///
/// Scope note — why nothing here *raises* an exception. Swift has no
/// `@try`/`@catch`, so a real `NSException` raised in a Swift test aborts the
/// whole test process rather than propagating to a `catch`; the Objective-C
/// shim that would fix that is exactly what the `dlsym` approach exists to
/// avoid. So the hook is exercised by invoking the installed function pointer
/// **directly** with a synthetic exception, and the formatting/budget rules are
/// pinned as pure functions.
final class ExceptionBreadcrumbTests: XCTestCase {

    // MARK: - Install + chaining

    /// The `dlsym` lookup resolves on this OS and the swap happens, i.e. the
    /// R4a *armed* branch is taken rather than the `unavailable` one.
    ///
    /// Deliberately **not** claiming more than that. `install()` is idempotent
    /// against process-wide state, so this call arms the process itself if
    /// nothing else has — the assertion passes whether or not
    /// `NoTypeApp.init()` ever called `install()`. The wiring is pinned by
    /// `test_noTypeAppInit_installsBreadcrumbFirst`, and only there.
    func test_install_isArmedInThisProcess() {
        XCTAssertNotNil(
            ExceptionBreadcrumb.install(),
            "The breadcrumb is not armed. Either NoTypeApp.init() no longer calls install(), or dlsym failed to resolve objc_setExceptionPreprocessor."
        )
    }

    /// Installing twice must leave **one** preprocessor installed, and must
    /// retain the pointer captured the first time.
    ///
    /// Both halves matter. Re-swapping would chain our own hook to itself
    /// (infinite recursion on the next throw). Losing the captured pointer is
    /// worse than losing a breadcrumb: Foundation's preprocessor is what
    /// populates `NSException.callStackReturnAddresses`, and without it
    /// HIToolbox aborts the process at `HIExceptions.mm:45` — measured, so
    /// every swallowed exception would become an instant `SIGABRT`.
    func test_install_isIdempotent_andRetainsTheReplacedPreprocessor() throws {
        let first = try XCTUnwrap(ExceptionBreadcrumb.install())
        let chainedBefore = ExceptionBreadcrumb.chainedPreprocessor

        let second = try XCTUnwrap(ExceptionBreadcrumb.install())
        let chainedAfter = ExceptionBreadcrumb.chainedPreprocessor

        // THE load-bearing assertion, and the reason this test was hardened:
        // every other check below is silently green when `chained` is nil.
        // `chainedBefore.map(Self.address)` is then `nil`, so the
        // "is it our own hook?" check reduces to `nil != Optional(ptr)` (true)
        // and the retention check to `nil == nil` (true) — i.e. the ONE
        // outcome that turns every swallowed exception into an immediate
        // process abort passed all three assertions.
        XCTAssertNotNil(
            chainedBefore,
            """
            install() captured no previous preprocessor. Foundation's is what \
            populates NSException.callStackReturnAddresses, and with it dropped \
            HIToolbox aborts the process at HIExceptions.mm:45 on the next \
            swallowed exception — measured, see ExceptionBreadcrumb's doc-comment.
            """
        )

        XCTAssertEqual(
            Self.address(first), Self.address(second),
            "A second install() must return the same hook, not a freshly swapped one."
        )
        XCTAssertEqual(
            chainedBefore.map(Self.address), chainedAfter.map(Self.address),
            "A second install() must not overwrite the preprocessor captured by the first."
        )
        XCTAssertNotEqual(
            chainedBefore.map(Self.address), Self.address(first),
            "The chained preprocessor is our own hook — install() chained the breadcrumb to itself."
        )
    }

    /// R6: the hook is an observer. It returns the object it was handed and
    /// alters no control flow.
    func test_installedPreprocessor_returnsTheSameExceptionObject() throws {
        let hook = try XCTUnwrap(ExceptionBreadcrumb.install())
        let exception = NSException(
            name: .invalidArgumentException,
            reason: "Invalid parameter not satisfying: !((__x) != (__x))",
            userInfo: nil
        )

        XCTAssertTrue(
            exception.callStackReturnAddresses.isEmpty,
            "Fixture precondition: a freshly constructed NSException carries no return addresses yet."
        )

        let returned = hook(exception)

        XCTAssertTrue(
            returned === exception,
            "The preprocessor must return its argument unchanged — it is an observer, not a filter."
        )

        // End-to-end proof that the chain actually RAN, not merely that a
        // pointer was retained. Populating `callStackReturnAddresses` is
        // precisely what the preprocessor we replaced does, and it is the field
        // HIToolbox asserts on at HIExceptions.mm:45. Verified empirically:
        // 0 addresses before this call, non-empty after.
        XCTAssertFalse(
            exception.callStackReturnAddresses.isEmpty,
            """
            The chained preprocessor did not run — NSException.callStackReturnAddresses \
            is still empty after passing through our hook. Ship this and every \
            exception AppKit currently swallows becomes an immediate SIGABRT.
            """
        )
    }

    // MARK: - Record format

    func test_formatRecord_carriesMarkerNameThreadFlagAndBoundedStack() {
        let stack = (0..<40).map { "  \($0)   NoType  0x0000  frame\($0)" }
        let record = ExceptionBreadcrumb.formatRecord(
            name: "NSInvalidArgumentException",
            reason: "Invalid parameter not satisfying: !((__x) != (__x))",
            isMainThread: true,
            stack: stack
        )

        XCTAssertTrue(record.hasPrefix(ExceptionBreadcrumb.throwMarker), record)
        XCTAssertTrue(record.contains("name=NSInvalidArgumentException"), record)
        XCTAssertTrue(record.contains("mainThread=true"), record)
        XCTAssertTrue(record.contains("Invalid parameter not satisfying"), record)

        XCTAssertTrue(record.contains("frame0"), "The stack must not be empty.")
        XCTAssertTrue(
            record.contains("frame\(ExceptionBreadcrumb.maxStackFrames - 1)"),
            "The stack must carry the full allowance of frames."
        )
        XCTAssertFalse(
            record.contains("frame\(ExceptionBreadcrumb.maxStackFrames)"),
            "The stack must be bounded at maxStackFrames — an unbounded symbol join in a preprocessor that may fire repeatedly is its own hazard."
        )
    }

    func test_formatRecord_reportsOffMainThread() {
        let record = ExceptionBreadcrumb.formatRecord(
            name: "NSGenericException",
            reason: nil,
            isMainThread: false,
            stack: ["0 frame"]
        )
        XCTAssertTrue(record.contains("mainThread=false"), record)
    }

    func test_scrubbedReason_missingReasonRendersPlaceholder() {
        XCTAssertEqual(ExceptionBreadcrumb.scrubbedReason(nil), "(none)")
        XCTAssertEqual(ExceptionBreadcrumb.scrubbedReason(""), "(none)")
    }

    /// R4b, and the Keychain module's "never log the key" hard rule, against
    /// the **real** Gemini key shape.
    ///
    /// The length is the whole point. A Gemini key is `AIza` + 35 characters =
    /// 39, which is BELOW `SecureFieldMasker`'s generic 40-character
    /// opaque-token catch-all (`\b[A-Za-z0-9_\-]{40,}\b`). `googleAPIKeyRegex`
    /// (`\bAIza[0-9A-Za-z_\-]{35}\b`) is therefore the *only* rule standing
    /// between a real key and a record the README asks the user to paste into a
    /// public, search-indexed issue. An earlier version of this test used a
    /// 40-character stand-in, which the catch-all redacted — so it went green
    /// while proving nothing about the rule that actually protects the key.
    func test_scrubbedReason_redactsARealShapedGeminiKey() {
        let key = "AIza" + "SyA1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q"
        XCTAssertEqual(
            key.count, 39,
            "Fixture drifted off the real Gemini key shape; it must stay below the 40-char catch-all."
        )

        let scrubbed = ExceptionBreadcrumb.scrubbedReason("Bad header value \(key) for request")

        XCTAssertFalse(scrubbed.contains(key), "The Gemini key reached the log unscrubbed: \(scrubbed)")
        XCTAssertFalse(scrubbed.contains("AIza"), "A Gemini key prefix survived: \(scrubbed)")
        XCTAssertTrue(scrubbed.contains("[REDACTED — likely Google API key]"), scrubbed)
    }

    /// The generic catch-all, kept as its own case so the rule above is not the
    /// only redaction path under test.
    func test_scrubbedReason_runsThroughSecureFieldMasker() {
        // Split, like the fixture above: a 40-char key-shaped literal assigned
        // whole trips the repo's gitleaks pre-commit hook (generic-api-key).
        let token = "AIzaSyA" + "1234567890abcdefghijklmnopqrstuvw"   // 40 chars — catch-all territory
        XCTAssertEqual(token.count, 40, "Fixture must stay at/above the masker's 40-char catch-all floor.")

        let scrubbed = ExceptionBreadcrumb.scrubbedReason("Bad header value \(token) for request")

        XCTAssertFalse(
            scrubbed.contains(token),
            "A key-shaped substring reached the log unscrubbed: \(scrubbed)"
        )
        XCTAssertTrue(scrubbed.contains("[REDACTED"), scrubbed)
    }

    /// Pins the ORDER of the two steps inside `scrubbedReason`, which is a
    /// security property and not a formatting one.
    ///
    /// Scrub-then-cap redacts the key and only then truncates. Cap-then-scrub
    /// would slice the raw string at 512 characters first, cutting this key 12
    /// characters in — a fragment far too short for `googleAPIKeyRegex`, which
    /// needs exactly `AIza` + 35 — so an unredacted key prefix would ship in a
    /// record destined for a public issue. Swapping those two lines leaves
    /// every other assertion in this file green, so this is the only thing
    /// holding that order in place.
    func test_scrubbedReason_scrubsBeforeCapping_soAStraddlingKeyCannotSurvive() {
        let key = "AIza" + "SyA1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q"
        // 500 chars of prose-shaped filler: whitespace-separated 4-char tokens,
        // so nothing here trips a masker rule and the key stays its own token.
        let filler = String(repeating: "word ", count: 100)
        XCTAssertEqual(filler.count, 500)
        XCTAssertLessThan(filler.count, ExceptionBreadcrumb.maxReasonLength)
        XCTAssertGreaterThan(filler.count + key.count, ExceptionBreadcrumb.maxReasonLength)

        let scrubbed = ExceptionBreadcrumb.scrubbedReason(filler + key)

        XCTAssertFalse(
            scrubbed.contains("AIza"),
            "A Gemini key fragment survived — scrubbedReason capped before it scrubbed: \(scrubbed)"
        )
        XCTAssertTrue(scrubbed.hasSuffix("…(truncated)"), String(scrubbed.suffix(32)))
    }

    func test_scrubbedReason_isLengthCapped() {
        // Prose-shaped filler, NOT a single long run of one character: a
        // 1536-char `xxx…` run is one token, and it survives the masker only
        // because `replaceLongOpaqueTokens` happens to require a digit
        // alongside its letters. That made this test's green depend on an
        // unrelated masker heuristic instead of on the length cap.
        let reason = String(repeating: "word ", count: ExceptionBreadcrumb.maxReasonLength)
        let scrubbed = ExceptionBreadcrumb.scrubbedReason(reason)

        XCTAssertTrue(scrubbed.hasSuffix("…(truncated)"), String(scrubbed.suffix(32)))
        XCTAssertLessThanOrEqual(
            scrubbed.count,
            ExceptionBreadcrumb.maxReasonLength + "…(truncated)".count
        )
    }

    // MARK: - Per-launch budget (R5)

    /// The unified log's persistent store is a system-wide, size-bounded ring.
    /// An always-on preprocessor that may fire in a loop must stop writing
    /// rather than evict other processes' records.
    func test_recordSlot_logsUpToTheCapThenOneNoticeThenSilence() {
        let cap = ExceptionBreadcrumb.maxRecordsPerLaunch

        XCTAssertEqual(ExceptionBreadcrumb.recordSlot(forCount: 0), .record)
        XCTAssertEqual(ExceptionBreadcrumb.recordSlot(forCount: cap - 1), .record)
        XCTAssertEqual(ExceptionBreadcrumb.recordSlot(forCount: cap), .capReached)
        XCTAssertEqual(ExceptionBreadcrumb.recordSlot(forCount: cap + 1), .silent)
        XCTAssertEqual(ExceptionBreadcrumb.recordSlot(forCount: cap + 5_000), .silent)
    }

    // MARK: - Armed / unavailable lines (R4a)

    /// The two install-time lines must be distinguishable. "No `OBJC THROW`
    /// line" reads as *nothing threw* only if the armed line is there; without
    /// that distinction an empty log cannot be told from an interceptor that
    /// never installed, and those two readings point at opposite conclusions.
    func test_armedAndUnavailableLines_areDistinct() {
        let armed = ExceptionBreadcrumb.armedLine(chained: true)

        XCTAssertTrue(armed.hasPrefix(ExceptionBreadcrumb.armedMarker), armed)
        XCTAssertTrue(armed.contains("cap=\(ExceptionBreadcrumb.maxRecordsPerLaunch)"), armed)
        XCTAssertTrue(armed.contains("chained=true"), armed)
        XCTAssertTrue(
            ExceptionBreadcrumb.armedLine(chained: false).contains("chained=false"),
            "The armed line must report whether a prior preprocessor was captured."
        )

        XCTAssertNotEqual(ExceptionBreadcrumb.armedMarker, ExceptionBreadcrumb.unavailableMarker)
        XCTAssertFalse(
            ExceptionBreadcrumb.unavailableMarker.hasPrefix(ExceptionBreadcrumb.armedMarker),
            "A `log show` grep for the armed marker must not also match the unavailable line."
        )
        XCTAssertTrue(
            ExceptionBreadcrumb.unavailableLine().hasPrefix(ExceptionBreadcrumb.unavailableMarker),
            ExceptionBreadcrumb.unavailableLine()
        )
    }

    /// The retrieval recipe in the README greps for these literals, and so do
    /// the plan's acceptance examples. Renaming one silently breaks a tester
    /// round-trip that costs an affected user a session.
    func test_markers_areTheDocumentedLiterals() {
        XCTAssertEqual(ExceptionBreadcrumb.throwMarker, "OBJC THROW")
        XCTAssertEqual(ExceptionBreadcrumb.armedMarker, "EXC BREADCRUMB armed")
    }

    // MARK: - The install must actually be wired, first

    /// The presence complement to everything above. Every other assertion in
    /// this file stays green if `ExceptionBreadcrumb.install()` is deleted from
    /// `NoTypeApp.init()` — the hook would simply never be installed in the
    /// shipped app, and the interceptor's whole value (an empty log meaning
    /// *nothing threw*) would silently invert into *nothing was watching*.
    ///
    /// Same shape as
    /// `LaunchOrderingTests.test_launchWork_isActuallyWiredUp_fromNoTypeAppInit`,
    /// and for the same reason: a source scan that only asserts absence stays
    /// green when the feature is dead. See
    /// `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`.
    func test_noTypeAppInit_installsBreadcrumbFirst() throws {
        let url = Self.repoRoot()
            .appendingPathComponent("NoType")
            .appendingPathComponent("NoTypeApp.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        // Comment- and string-stripped, so the doc-comment above the call
        // cannot masquerade as the first statement.
        let bodies = LaunchPathScanner.initBodies(inSource: source)
            .filter { $0.contains("launchHandler =") }
        let body = try XCTUnwrap(
            bodies.first,
            "Could not find NoTypeApp.init() — the scan lost its anchor."
        )

        let statements = body
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        XCTAssertEqual(
            statements.first,
            "ExceptionBreadcrumb.install()",
            """
            `ExceptionBreadcrumb.install()` must be the FIRST statement of \
            NoTypeApp.init(). Anything constructed before it raises \
            un-observed, and the launch window is where the field reports \
            land. First statements found: \(statements.prefix(3))
            """
        )
    }

    // MARK: - The launch-ordering rule, for a file the main scan cannot see

    /// `LaunchOrderingTests` enforces "no `MainActor` scheduling and no `NSApp`
    /// on the launch path", but its discovery walks **constructions** —
    /// `LaunchPathScanner.constructedTypeNames` only records a capitalized
    /// identifier immediately followed by `(`. `ExceptionBreadcrumb.install()`
    /// is a static call through a `.`, so this type never enters
    /// `launchPathTypes` and that scan never opens this file — even though it
    /// runs as the *first* statement of `NoTypeApp.init()`, earlier than
    /// anything the scan does cover. Scan it here instead.
    ///
    /// Whole-file on purpose. `LaunchPathScanner.violations(inSource:)` seeds
    /// its traversal from `init` bodies, and `ExceptionBreadcrumb` declares no
    /// initializer, so `violations` would inspect only stored-property
    /// declaration lines and come back empty no matter what `install()`,
    /// `observe(_:)`, `State` or the preprocessor closure body contained. That
    /// is the failure mode in
    /// `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`:
    /// a guard that is green because it looked nowhere.
    func test_breadcrumbSource_schedulesNoMainActorWork_andDoesNotTouchNSApp() throws {
        let url = Self.repoRoot()
            .appendingPathComponent("NoType")
            .appendingPathComponent("Diagnostics")
            .appendingPathComponent("ExceptionBreadcrumb.swift")
        let code = LaunchPathScanner.strippingCommentsAndStrings(
            try String(contentsOf: url, encoding: .utf8)
        )

        var violations: [String] = []
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            for needle in LaunchPathScanner.needles
            where LaunchPathScanner.line(String(line), contains: needle) {
                violations.append("\(needle) in `\(line.trimmingCharacters(in: .whitespaces))`")
            }
        }

        XCTAssertEqual(
            violations, [],
            """
            ExceptionBreadcrumb schedules MainActor work or touches NSApp. It runs \
            as the first statement of NoTypeApp.init(), before NSApplicationMain has \
            started the app, so this is the launch-ordering rule in \
            `NoType/UI/CLAUDE.md` — move the work to a prime()-style method called \
            from applicationDidFinishLaunching(_:).

            Violations:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    // MARK: - The records must still be emitted, and findable

    /// `armedLine(chained:)` and `unavailableLine()` have their formats pinned
    /// above, but nothing pinned that `install()` still *emits* them. Delete
    /// either `log.fault` call and every other assertion in this file stays
    /// green while R4a — the line that makes an empty log mean *nothing threw*
    /// rather than *nobody was watching* — silently stops being written, and the
    /// helper becomes dead code that still has a passing test.
    ///
    /// Occurrence counting rather than exact call-site text, so reformatting the
    /// call does not fail the guard: each helper must appear at least twice —
    /// once declaring itself, at least once being called.
    func test_install_stillEmitsTheArmedAndUnavailableRecords() throws {
        let source = try String(contentsOf: Self.breadcrumbSourceURL(), encoding: .utf8)

        for helper in ["armedLine(chained:", "unavailableLine()"] {
            let uses = source.components(separatedBy: helper).count - 1
            XCTAssertGreaterThanOrEqual(
                uses, 2,
                """
                `\(helper)` appears \(uses)x in ExceptionBreadcrumb.swift — declaration \
                only, no call site. install() must still log it; see R4a.
                """
            )
        }
    }

    /// The README's `log show` recipe is this breadcrumb's entire user-facing
    /// surface (KD6). It hard-codes the subsystem and category as strings, and
    /// so does `ExceptionBreadcrumb` — in a different file, with nothing but
    /// this test connecting them. Rename either side and the recipe silently
    /// returns nothing, which costs an affected user a whole reporting round
    /// and reads exactly like "nothing threw".
    func test_readmeRetrievalRecipe_matchesTheLoggerTheCodeActuallyUses() throws {
        let source = try String(contentsOf: Self.breadcrumbSourceURL(), encoding: .utf8)
        let readme = try String(
            contentsOf: Self.repoRoot().appendingPathComponent("README.md"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains(#"Logger(subsystem: "app.notype", category: "exception")"#),
            "The breadcrumb's Logger changed; the README's log show predicate no longer describes it."
        )
        XCTAssertTrue(
            readme.contains(#"subsystem == "app.notype" AND category == "exception""#),
            "README's log show predicate no longer matches the breadcrumb's Logger subsystem/category."
        )
        XCTAssertTrue(
            readme.contains(ExceptionBreadcrumb.armedMarker),
            "README no longer names the armed line, so a reporter cannot tell an unarmed launch from a quiet one."
        )
        XCTAssertTrue(
            readme.contains(ExceptionBreadcrumb.throwMarker),
            "README no longer names the throw marker a reporter is meant to look for."
        )
    }

    // MARK: - Helpers

    private static func breadcrumbSourceURL() -> URL {
        repoRoot()
            .appendingPathComponent("NoType")
            .appendingPathComponent("Diagnostics")
            .appendingPathComponent("ExceptionBreadcrumb.swift")
    }

    /// C function pointers have no `==`; compare their raw addresses.
    private static func address(_ fn: ExceptionBreadcrumb.Preprocessor) -> UnsafeRawPointer {
        unsafeBitCast(fn, to: UnsafeRawPointer.self)
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // NoTypeTests/
            .deletingLastPathComponent()    // repo root
    }
}
