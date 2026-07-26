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

    /// The interceptor must already be armed in this process: the test bundle
    /// is hosted by `NoType.app`, so `NoTypeApp.init()` has run. A non-`nil`
    /// return is proof the `dlsym` lookup resolved and the swap happened —
    /// i.e. that the R4a *armed* branch was taken rather than the
    /// `unavailable` one.
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

        let returned = hook(exception)

        XCTAssertTrue(
            returned === exception,
            "The preprocessor must return its argument unchanged — it is an observer, not a filter."
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

    /// R4b. `objc_setExceptionPreprocessor` is process-wide, so it sees
    /// exceptions raised at the boundaries where NoType hands Objective-C its
    /// most sensitive values — the transcript into `NSPasteboard`, the Gemini
    /// key into a URL request header. `reason` is authored by the raising
    /// framework with arguments this app does not control, so it goes through
    /// the same masker every other content-carrying path uses.
    func test_scrubbedReason_runsThroughSecureFieldMasker() {
        let reason = "Bad header value AIzaSyA1234567890abcdefghijklmnopqrstuvw for request"
        let scrubbed = ExceptionBreadcrumb.scrubbedReason(reason)

        XCTAssertFalse(
            scrubbed.contains("AIzaSyA1234567890abcdefghijklmnopqrstuvw"),
            "A key-shaped substring reached the log unscrubbed: \(scrubbed)"
        )
        XCTAssertTrue(scrubbed.contains("[REDACTED"), scrubbed)
    }

    func test_scrubbedReason_isLengthCapped() {
        let reason = String(repeating: "x", count: ExceptionBreadcrumb.maxReasonLength * 3)
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

    // MARK: - Helpers

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
