import XCTest
@testable import NoType

/// Pins the "no `MainActor` work and no `NSApp` before the app has
/// launched" rule as a mechanical check.
///
/// Background: `NoTypeApp.init()` runs *before* `NSApplicationMain` has
/// started the application. Scheduling `MainActor` work or touching
/// `NSApp` in that window is a latent ordering bug, and it is the leading
/// hypothesis for the macOS 26.2 executor-identity crash family — see
/// `docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`.
/// The remediation moved that work into `AppState.prime()` /
/// `PermissionsViewModel.prime()` / `AppearanceController.apply()`, all
/// called from `applicationDidFinishLaunching(_:)`.
///
/// A runtime assertion is deliberately NOT the mechanism: the maintainer's
/// machine does not reproduce the crash, so an assertion would never fire
/// there. This is a source-text scan, mirroring
/// `NoTypeTests/DSComponentsHoverTests.swift`.
///
/// Scope: the launch path only — every type reachable by construction from
/// `NoTypeApp.init()`. The rule is NOT about `Task` usage in general.
/// Depth: each type's initializer **plus every same-file method that
/// initializer calls**. One call level is enough to cover the
/// `init` -> `refresh()` -> `startPollingIfNeeded()` shape that was the
/// known offender.
final class LaunchOrderingTests: XCTestCase {

    // MARK: - The repo-wide assertion

    func test_launchPathInitializers_scheduleNoMainActorWork_andDoNotTouchNSApp() throws {
        let repoRoot = Self.repoRoot()
        let types = try LaunchPathScanner.launchPathTypes(repoRoot: repoRoot)

        // Guard against the scan silently degrading to "found nothing".
        XCTAssertTrue(
            types.keys.contains("AppState"),
            "Launch-path discovery lost AppState — the scan is not doing its job. Found: \(types.keys.sorted())"
        )
        XCTAssertTrue(
            types.keys.contains("PermissionsViewModel"),
            "Launch-path discovery lost PermissionsViewModel. Found: \(types.keys.sorted())"
        )
        XCTAssertTrue(
            types.keys.contains("AppearanceController"),
            "Launch-path discovery lost AppearanceController. Found: \(types.keys.sorted())"
        )
        // Transitively constructed: AppState.init() builds it.
        XCTAssertTrue(
            types.keys.contains("LoginItemController"),
            "Launch-path discovery is not transitive — LoginItemController is built by AppState.init(). Found: \(types.keys.sorted())"
        )

        var violations: [String] = []
        for (typeName, url) in types.sorted(by: { $0.key < $1.key }) {
            let source = try String(contentsOf: url, encoding: .utf8)
            let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            for hit in LaunchPathScanner.violations(inSource: source) {
                violations.append("\(relative) — \(typeName).\(hit.scope): \(hit.needle) in `\(hit.line)`")
            }
        }

        XCTAssertEqual(
            violations, [],
            """
            Launch-path initializer schedules MainActor work or touches NSApp.

            No type constructed by `NoTypeApp.init()` may contain a `Task { … }` \
            literal or an `NSApp` reference in its initializer, or in a same-file \
            method that initializer calls. Move the work into a `prime()`-style \
            method called from `applicationDidFinishLaunching(_:)` — see \
            `docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`.

            Violations:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    /// The rule is scoped to the launch path. A `Task` in a type that is
    /// never constructed during `NoTypeApp.init()` must not trip the scan.
    func test_discovery_excludesTypesOffTheLaunchPath() throws {
        let types = try LaunchPathScanner.launchPathTypes(repoRoot: Self.repoRoot())

        // `RecordingSession` is Task-heavy and is created per hotkey press,
        // long after launch. If discovery ever pulls it in, the scan has
        // stopped being about the launch path.
        XCTAssertFalse(
            types.keys.contains("RecordingSession"),
            "RecordingSession is not on the launch path; discovery over-reached."
        )
        XCTAssertFalse(
            types.keys.contains("SileroVAD"),
            "SileroVAD is constructed by prime(), not by an initializer; discovery over-reached."
        )
    }

    // MARK: - Fixtures pinning the scanner itself

    func test_scanner_flagsTaskLiteralInInitializerBody() {
        let source = """
        @MainActor final class Fixture {
            init() {
                Task { @MainActor in
                    await self.load()
                }
            }
        }
        """
        let hits = LaunchPathScanner.violations(inSource: source)
        XCTAssertEqual(hits.count, 1, "Expected the Task literal to be flagged. Got: \(hits)")
        XCTAssertEqual(hits.first?.scope, "init")
        XCTAssertEqual(hits.first?.needle, "Task {")
    }

    /// The known offender's shape verbatim: a clean-looking initializer whose
    /// same-file helper's helper is what actually schedules the work. The
    /// `Task` literal is TWO hops from `init`, which is why the traversal is
    /// transitive rather than one-deep.
    func test_scanner_flagsTaskLiteralTransitivelyThroughSameFileHelpers() {
        let source = """
        @MainActor final class Fixture {
            init() {
                refresh()
            }

            func refresh() {
                startPollingIfNeeded()
            }

            private func startPollingIfNeeded() {
                Task { @MainActor in
                    await self.tick()
                }
            }
        }
        """
        let hits = LaunchPathScanner.violations(inSource: source)
        XCTAssertEqual(
            hits.count, 1,
            "Expected the Task literal to be flagged two call levels down. Got: \(hits)"
        )
        XCTAssertEqual(hits.first?.scope, "startPollingIfNeeded")
    }

    /// The complement: a same-file helper that the initializer does NOT call
    /// stays out of scope, even when it is Task-heavy.
    func test_scanner_ignoresHelpersNotReachableFromInit() {
        let source = """
        @MainActor final class Fixture {
            init() {
                configure()
            }

            func configure() {}

            func unrelated() {
                Task { @MainActor in await self.work() }
            }
        }
        """
        XCTAssertEqual(
            LaunchPathScanner.violations(inSource: source), [],
            "A helper unreachable from init must not be scanned."
        )
    }

    func test_scanner_flagsNSAppAccessInInitializerBody() {
        let source = """
        @MainActor final class Fixture {
            init() {
                NSApp.appearance = nil
            }
        }
        """
        let hits = LaunchPathScanner.violations(inSource: source)
        XCTAssertEqual(hits.count, 1, "Expected the NSApp write to be flagged. Got: \(hits)")
        XCTAssertEqual(hits.first?.needle, "NSApp")
    }

    /// `AppearanceController`'s exact pre-fix shape: a tidy initializer whose
    /// private helper performed the `NSApp.appearance` write. Reverting U2
    /// reintroduces this and must fail the scan.
    func test_scanner_flagsPreFixAppearanceControllerShape() {
        let source = """
        @MainActor final class Fixture {
            var mode: String
            init() {
                self.mode = UserDefaults.standard.string(forKey: "k") ?? ""
                apply()
            }
            private func apply() {
                guard let app: NSApplication = NSApp else { return }
                app.appearance = nil
            }
        }
        """
        let hits = LaunchPathScanner.violations(inSource: source)
        XCTAssertEqual(hits.first?.scope, "apply", "Got: \(hits)")
        XCTAssertEqual(hits.first?.needle, "NSApp")
    }

    func test_scanner_passesCleanInitializer() {
        let source = """
        @MainActor final class Fixture {
            var mode: String

            init() {
                self.mode = UserDefaults.standard.string(forKey: "k") ?? ""
            }

            /// Doc-comments mentioning Task { and NSApp must not trip the scan.
            func prime() {
                // Task { NSApp } in a comment is not code.
                Task { @MainActor in await self.load() }
            }

            func load() async {}
        }
        """
        XCTAssertEqual(
            LaunchPathScanner.violations(inSource: source), [],
            "A method that is NOT called from init must not be scanned, and comments must be stripped."
        )
    }

    func test_scanner_ignoresNeedlesInsideStringLiterals() {
        let source = """
        @MainActor final class Fixture {
            init() {
                log("NSApp is not touched here")
            }
            func log(_ s: String) {}
        }
        """
        XCTAssertEqual(
            LaunchPathScanner.violations(inSource: source), [],
            "A needle inside a string literal is not a real reference."
        )
    }

    // MARK: - Helpers

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // NoTypeTests/
            .deletingLastPathComponent()    // repo root
    }
}

// MARK: - Scanner

/// Pure source-text scanner backing `LaunchOrderingTests`. Kept in the test
/// target: it encodes a convention, not app behaviour.
enum LaunchPathScanner {

    struct Hit: Equatable, CustomStringConvertible {
        /// `init`, or the name of the same-file method the initializer calls.
        let scope: String
        /// The needle that matched (`Task {` / `NSApp`).
        let needle: String
        /// The offending source line, trimmed.
        let line: String

        var description: String { "\(scope): \(needle) in `\(line)`" }
    }

    /// Needles that mean "this schedules MainActor work or touches the
    /// application object". `Task.detached` is included because it schedules
    /// concurrent work just as `Task {` does; `NSApplication.shared` is the
    /// non-`NSApp` spelling of the same global.
    private static let needles = ["Task {", "Task.detached", "NSApp", "NSApplication.shared"]

    // MARK: Discovery

    /// Every type reachable by construction from `NoTypeApp.init()`,
    /// transitively (so `LoginItemController`, built inside `AppState.init`,
    /// is included). Maps type name -> source file.
    ///
    /// A constructed identifier is treated as "ours" only when a matching
    /// `<TypeName>.swift` exists under `NoType/`, which naturally filters
    /// stdlib and SwiftUI types such as `State` or `Set`.
    static func launchPathTypes(repoRoot: URL) throws -> [String: URL] {
        let index = try swiftFileIndex(repoRoot: repoRoot)

        guard let rootURL = index["NoTypeApp"] else {
            throw ScanError.missingRoot
        }

        var resolved: [String: URL] = ["NoTypeApp": rootURL]
        var queue: [String] = ["NoTypeApp"]

        while let typeName = queue.popLast() {
            guard let url = resolved[typeName] else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            let code = strippingCommentsAndStrings(source)

            for fn in functionBodies(in: code) where fn.name == "init" {
                for constructed in constructedTypeNames(in: fn.body) {
                    guard resolved[constructed] == nil,
                          let file = index[constructed] else { continue }
                    resolved[constructed] = file
                    queue.append(constructed)
                }
            }
        }

        return resolved
    }

    private static func swiftFileIndex(repoRoot: URL) throws -> [String: URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: repoRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ScanError.enumerationFailed(repoRoot.path)
        }

        var index: [String: URL] = [:]
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            // App sources only — never index the test target, otherwise this
            // file's own fixtures become scan targets.
            guard url.path.contains("/NoType/") else { continue }
            index[url.deletingPathExtension().lastPathComponent] = url
        }
        return index
    }

    /// Capitalized identifiers immediately followed by `(` — i.e. constructor
    /// calls. Excludes `.foo(` member calls, which are not constructions.
    private static func constructedTypeNames(in body: String) -> Set<String> {
        var names: Set<String> = []
        let chars = Array(body)
        var i = 0
        while i < chars.count {
            guard chars[i].isUppercase, chars[i].isLetter else { i += 1; continue }
            // Not a member access (`.Foo(`) and not mid-identifier.
            if i > 0 {
                let prev = chars[i - 1]
                if prev == "." || prev.isLetter || prev.isNumber || prev == "_" { i += 1; continue }
            }
            var j = i
            while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
            if j < chars.count, chars[j] == "(" {
                names.insert(String(chars[i..<j]))
            }
            i = j
        }
        return names
    }

    // MARK: Violation scan

    /// Scans one type's source for launch-path violations: every initializer
    /// body, plus the body of every same-file method reachable from it.
    ///
    /// The traversal is transitive, not one-deep. The historical offender was
    /// `init()` -> `refresh()` -> `startPollingIfNeeded()`, where the `Task`
    /// literal sits **two** hops from the initializer — a single-level scan
    /// would have walked straight past it. Same-file scoping keeps the
    /// traversal bounded without needing a real call graph.
    static func violations(inSource source: String) -> [Hit] {
        let code = strippingCommentsAndStrings(source)
        let functions = functionBodies(in: code)

        var scopes: [(name: String, body: String)] = []
        var visited: Set<String> = []
        var queue: [(name: String, body: String)] = []

        for fn in functions where fn.name == "init" {
            queue.append((name: "init", body: fn.body))
        }

        while let current = queue.popLast() {
            scopes.append(current)
            for candidate in functions
            where candidate.name != "init"
                && !visited.contains(candidate.name)
                && current.body.contains(candidate.name + "(") {
                visited.insert(candidate.name)
                queue.append((name: candidate.name, body: candidate.body))
            }
        }

        var hits: [Hit] = []
        for scope in scopes {
            for line in scope.body.split(separator: "\n", omittingEmptySubsequences: false) {
                for needle in needles where line.contains(needle) {
                    hits.append(
                        Hit(
                            scope: scope.name,
                            needle: needle,
                            line: line.trimmingCharacters(in: .whitespaces)
                        )
                    )
                }
            }
        }
        return hits
    }

    // MARK: Parsing primitives

    private struct Function {
        let name: String
        let body: String
    }

    /// All `func <name>(…) { … }` and `init(…) { … }` bodies, via brace
    /// matching. Input must already have comments and string literals
    /// stripped so the brace count is trustworthy.
    private static func functionBodies(in code: String) -> [Function] {
        var result: [Function] = []
        let chars = Array(code)

        for (keyword, isInit) in [("func ", false), ("init", true)] {
            var searchStart = code.startIndex
            while let range = code.range(of: keyword, range: searchStart..<code.endIndex) {
                searchStart = range.upperBound

                let name: String
                var cursor = code.distance(from: code.startIndex, to: range.upperBound)

                if isInit {
                    // Must be `init(` or `init?(` — not `initialize`, and not
                    // a substring of a longer identifier.
                    let startOffset = code.distance(from: code.startIndex, to: range.lowerBound)
                    if startOffset > 0 {
                        let prev = chars[startOffset - 1]
                        if prev.isLetter || prev.isNumber || prev == "_" || prev == "." { continue }
                    }
                    if cursor < chars.count, chars[cursor] == "?" { cursor += 1 }
                    guard cursor < chars.count, chars[cursor] == "(" else { continue }
                    name = "init"
                } else {
                    var j = cursor
                    while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                    guard j > cursor else { continue }
                    name = String(chars[cursor..<j])
                    cursor = j
                }

                // Walk to the opening brace of the body, skipping the
                // signature (parameters, effects, return type).
                var depth = 0
                var k = cursor
                var bodyStart: Int?
                while k < chars.count {
                    let c = chars[k]
                    if c == "(" { depth += 1 }
                    else if c == ")" { depth -= 1 }
                    else if c == "{", depth == 0 { bodyStart = k; break }
                    else if c == "\n", depth == 0, k + 1 < chars.count {
                        // A protocol requirement or a declaration with no body.
                        let rest = String(chars[k...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if rest.hasPrefix("func ") || rest.hasPrefix("}") { break }
                    }
                    k += 1
                }
                guard let open = bodyStart else { continue }

                var braces = 0
                var m = open
                var end: Int?
                while m < chars.count {
                    if chars[m] == "{" { braces += 1 }
                    else if chars[m] == "}" {
                        braces -= 1
                        if braces == 0 { end = m; break }
                    }
                    m += 1
                }
                guard let close = end, close > open else { continue }
                result.append(Function(name: name, body: String(chars[(open + 1)..<close])))
            }
        }
        return result
    }

    /// Replaces comment and string-literal content with spaces, preserving
    /// newlines and overall length. Required: these sources document the very
    /// rule being scanned for, so `NSApp` and `Task {` appear in prose
    /// throughout, and comments contain braces that would break brace
    /// matching.
    static func strippingCommentsAndStrings(_ source: String) -> String {
        enum Mode { case code, lineComment, blockComment, string, multilineString }

        var mode: Mode = .code
        var out = ""
        out.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0

        func peek(_ offset: Int) -> Character? {
            let idx = i + offset
            return idx < chars.count ? chars[idx] : nil
        }

        while i < chars.count {
            let c = chars[i]
            switch mode {
            case .code:
                if c == "/", peek(1) == "/" { mode = .lineComment; out += "  "; i += 2 }
                else if c == "/", peek(1) == "*" { mode = .blockComment; out += "  "; i += 2 }
                else if c == "\"", peek(1) == "\"", peek(2) == "\"" {
                    mode = .multilineString; out += "   "; i += 3
                }
                else if c == "\"" { mode = .string; out += " "; i += 1 }
                else { out.append(c); i += 1 }

            case .lineComment:
                if c == "\n" { mode = .code; out.append(c) } else { out.append(" ") }
                i += 1

            case .blockComment:
                if c == "*", peek(1) == "/" { mode = .code; out += "  "; i += 2 }
                else { out.append(c == "\n" ? "\n" : " "); i += 1 }

            case .string:
                if c == "\\" { out += "  "; i += 2 }
                else if c == "\"" { mode = .code; out += " "; i += 1 }
                else if c == "\n" { mode = .code; out.append(c); i += 1 }
                else { out += " "; i += 1 }

            case .multilineString:
                if c == "\"", peek(1) == "\"", peek(2) == "\"" { mode = .code; out += "   "; i += 3 }
                else { out.append(c == "\n" ? "\n" : " "); i += 1 }
            }
        }
        return out
    }

    enum ScanError: Error, CustomStringConvertible {
        case missingRoot
        case enumerationFailed(String)

        var description: String {
            switch self {
            case .missingRoot:
                "Could not find NoTypeApp.swift — launch-path discovery has no root."
            case .enumerationFailed(let path):
                "Could not enumerate repo root at \(path)"
            }
        }
    }
}
