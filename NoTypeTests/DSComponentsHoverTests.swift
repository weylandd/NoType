import XCTest
@testable import NoType

/// Pins the macOS-26 hover-crash convention as a mechanical check.
///
/// Background: SwiftUI `.onHover` closures written inside a `@MainActor`
/// View body inherit `@MainActor` per SE-0420, and on macOS 26.2 the
/// closure-prologue executor check faults at `swift_getObjectType(0x1)`
/// — see `docs/solutions/runtime-errors/onhover-mainactor-inheritance-
/// crash-2026-05-19.md`. The fix routes every callsite through
/// `dsOnHover` in `NoType/UI/DSComponents.swift`. The convention is
/// "no raw `.onHover` outside `DSComponents.swift`'s wrapper definition."
///
/// This test walks the repo's Swift sources and asserts the convention
/// mechanically. Three of three prior fixes in this macOS-26 executor-
/// check family were discovered in production because the rule was
/// convention-only; six of nine review personas flagged that gap when
/// the `.onHover` fix landed. This is the guardrail that closes it.
///
/// Cost: ~5 ms on a warm filesystem (~80 Swift files in the repo). The
/// needle is built via string concatenation so this test file itself
/// doesn't trip the assertion.
final class DSComponentsHoverTests: XCTestCase {

    func test_noRawOnHover_outsideDSComponents() throws {
        // String-concat to avoid the test file matching itself when scanned.
        let needle = "." + "onHover {"

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // NoTypeTests/
            .deletingLastPathComponent()    // repo root

        guard let enumerator = FileManager.default.enumerator(
            at: repoRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            XCTFail("Could not enumerate repo root at \(repoRoot.path)")
            return
        }

        var violations: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            // The wrapper definition is the only legal raw `.onHover`.
            guard url.lastPathComponent != "DSComponents.swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains(needle) {
                let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                violations.append(relative)
            }
        }

        XCTAssertEqual(
            violations, [],
            """
            Raw `.onHover` found outside `DSComponents.swift`. \
            Use `.dsOnHover { … }` instead — see \
            `docs/solutions/runtime-errors/onhover-mainactor-inheritance-crash-2026-05-19.md`. \
            Violating files: \(violations)
            """
        )
    }
}
