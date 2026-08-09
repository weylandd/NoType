import XCTest
@testable import NoType

/// Pins the "no `MainActor` work and no `NSApp` before the app has
/// launched" rule as a mechanical check.
///
/// Background: `NoTypeApp.init()` runs *before* `NSApplicationMain` has
/// started the application. Scheduling `MainActor` work or touching
/// `NSApp` in that window is a latent ordering bug, and that is the whole
/// justification for this rule — it stands on its own merits. The move
/// also fixed two real shipped defects: Sparkle's update check never ran
/// for menu-bar-only users, and the un-mute-on-quit handler was never
/// wired. See
/// `docs/solutions/architecture-patterns/scene-task-is-not-a-launch-hook-2026-07-25.md`.
/// The remediation moved that work into `AppState.prime()` /
/// `PermissionsViewModel.prime()` / `AppearanceController.apply()`, all
/// called from `applicationDidFinishLaunching(_:)`.
///
/// This rule is **not** coverage of the macOS 26 executor-identity crash
/// family. It was once the leading theory there; the reordering shipped as
/// v0.1.13-rc1 (`bfcec4a`) and did not fix the crash. The proven cause is
/// a swallowed ObjC exception — see
/// `docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`.
/// Don't read a green run here as a crash mitigation.
///
/// A runtime assertion is deliberately NOT the mechanism: the maintainer's
/// machine does not reproduce the crash, so an assertion would never fire
/// there. This is a source-text scan, mirroring
/// `NoTypeTests/DSComponentsHoverTests.swift`.
///
/// Scope: the launch path only — every type reachable by construction from
/// `NoTypeApp.init()`. The rule is NOT about `Task` usage in general.
/// Depth: each type's initializer, its stored-property default expressions,
/// **plus every same-file method reachable from the initializer,
/// transitively**. One call level is NOT enough: the known offender's
/// `Task` literal (`init` -> `refresh()` -> `startPollingIfNeeded()`) sits
/// **two** hops down, so a single-level scan would walk straight past it.
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
        // `AppState.init` declares this one as a DEFAULTED parameter
        // (`retainedAudio: RetainedAudioStore = RetainedAudioStore()`).
        // A default argument is evaluated at the call site, so the type is
        // genuinely on the launch path — but its `RetainedAudioStore(`
        // text sits in a parameter list, and `constructedTypeNames` only
        // reads initializer *bodies*. `NoTypeApp.init()` therefore names
        // it explicitly. This assertion is what stops that being
        // "simplified" back to the elided form, which would drop the type
        // off the scan while leaving it on the launch path.
        XCTAssertTrue(
            types.keys.contains("RetainedAudioStore"),
            "Launch-path discovery lost RetainedAudioStore — NoTypeApp.init() must construct it explicitly rather than relying on AppState.init's default argument, which this scan cannot see. Found: \(types.keys.sorted())"
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
            `docs/solutions/architecture-patterns/scene-task-is-not-a-launch-hook-2026-07-25.md`.

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

    // MARK: - The launch wire must exist

    /// The complement to every other test in this file. The scan proves the
    /// launch work is ABSENT from initializers; nothing proved it is PRESENT
    /// at the launch hook. Delete `appDelegate.launchHandler = { … }` from
    /// `NoTypeApp.init()` and the app ships with no hotkey tap, no permission
    /// reads, no history/stats/dictionary mirrors and no VAD — while every
    /// assertion in this file and in `LaunchPrimingTests` stays green,
    /// because "nothing is primed" is exactly the state they assert.
    func test_launchWork_isActuallyWiredUp_fromNoTypeAppInit() throws {
        let url = Self.repoRoot()
            .appendingPathComponent("NoType")
            .appendingPathComponent("NoTypeApp.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let initBodies = LaunchPathScanner.initBodies(inSource: source)

        let combined = initBodies.joined(separator: "\n")
        XCTAssertFalse(initBodies.isEmpty, "Could not parse NoTypeApp.init() — the scan lost its anchor.")
        XCTAssertTrue(
            combined.contains("launchHandler ="),
            "NoTypeApp.init() must assign appDelegate.launchHandler — without it nothing ever primes."
        )
        XCTAssertTrue(
            combined.contains("prime()"),
            "The launch handler must reach prime(); otherwise AppState is never initialized."
        )
        XCTAssertTrue(
            combined.contains("apply()"),
            "The launch handler must reach AppearanceController.apply(); otherwise the theme is never applied."
        )
    }

    /// The same class of bug as the test above, one level out: work that IS
    /// wired, to a hook that never fires. `updates.start()` and the
    /// termination handler both sat on `.task` modifiers on `MainWindowView`.
    /// For a returning `LSUIElement` user the main window is not presented at
    /// launch (`defaultLaunchBehavior(.automatic)`), so that `.task` never
    /// ran: Sparkle never checked for updates, and quitting from the popover
    /// left the system muted because the mute-restore handler was unassigned.
    ///
    /// Both now hang off `NoTypeApp.init()` — `start()` inside `launchHandler`
    /// (it needs a live `NSApplication`), `terminationHandler` as a direct
    /// closure assignment (it schedules nothing, so it needs no hook).
    func test_sparkleAndTerminationHandler_areWiredFromInit_notAWindowTask() throws {
        let url = Self.repoRoot()
            .appendingPathComponent("NoType")
            .appendingPathComponent("NoTypeApp.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let combined = LaunchPathScanner.initBodies(inSource: source).joined(separator: "\n")

        XCTAssertTrue(
            combined.contains("updates.start()"),
            "NoTypeApp.init() must start Sparkle from the launch handler — on a .task it never runs for menu-bar-only users."
        )
        XCTAssertTrue(
            combined.contains("terminationHandler ="),
            "NoTypeApp.init() must assign appDelegate.terminationHandler — without it, quitting can leave the system muted."
        )

        // Neither may drift back onto the scene. `.task` on a scene view is
        // fine for genuinely window-scoped work; if you are adding such a
        // case, narrow this assertion rather than deleting it — the thing it
        // guards is that *launch* work never rides a modifier that a
        // menu-bar-only launch does not evaluate.
        XCTAssertFalse(
            LaunchPathScanner.strippingCommentsAndStrings(source).contains(".task"),
            "NoTypeApp.swift must not hang work off a scene `.task` — the main window is not presented at launch once onboarding is complete."
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

    /// Stored-property defaults run during construction but live in no
    /// function body — the shape the scanner was originally blind to.
    func test_scanner_flagsTaskLiteralInStoredPropertyDefault() {
        let source = """
        @MainActor final class Fixture {
            private let boot = Task { @MainActor in await load() }
            init() {}
        }
        """
        let hits = LaunchPathScanner.violations(inSource: source)
        XCTAssertEqual(hits.count, 1, "A Task in a property default must be flagged. Got: \\(hits)")
        XCTAssertEqual(hits.first?.scope, "property")
    }

    /// A property *observer* is not construction-time code — it cannot fire
    /// during `init` — so it must not be flagged.
    func test_scanner_ignoresTaskInsidePropertyObserver() {
        let source = """
        @MainActor final class Fixture {
            var mode: String = "a" {
                didSet { Task { @MainActor in await save() } }
            }
            init() {}
        }
        """
        XCTAssertEqual(LaunchPathScanner.violations(inSource: source), [])
    }

    /// The rule is "schedule no MainActor work", not "write no `Task {`".
    /// Each of these is an equally-violating spelling that the original
    /// four-needle list walked straight past.
    func test_scanner_flagsEveryMainActorSchedulingSpelling() {
        let spellings = [
            "Task{ @MainActor in await load() }",
            "Task(priority: .high) { @MainActor in await load() }",
            "DispatchQueue.main.async { load() }",
            "MainActor.assumeIsolated { load() }",
            "RunLoop.main.perform { load() }",
        ]
        for spelling in spellings {
            let source = """
            @MainActor final class Fixture {
                init() {
                    \(spelling)
                }
            }
            """
            XCTAssertFalse(
                LaunchPathScanner.violations(inSource: source).isEmpty,
                "Expected `\(spelling)` to be flagged as launch-path MainActor scheduling."
            )
        }
    }

    /// `NSApp` must match the application global, not every identifier that
    /// merely starts with it — otherwise a legitimate `NSAppearance` read
    /// fails the scan for the wrong reason and the rule gets relaxed.
    func test_scanner_nsAppNeedleRespectsIdentifierBoundaries() {
        let source = """
        @MainActor final class Fixture {
            init() {
                let a = NSAppearance(named: .darkAqua)
                _ = a
            }
        }
        """
        XCTAssertEqual(
            LaunchPathScanner.violations(inSource: source), [],
            "NSAppearance is not NSApp."
        )
    }

    /// Overloads share a name; keying the visited set on the name alone
    /// scanned only the first one and walked past a `Task` in the second.
    func test_scanner_doesNotCollapseOverloads() {
        let source = """
        @MainActor final class Fixture {
            init() {
                start(deferred: true)
            }

            func start() {}

            func start(deferred: Bool) {
                Task { @MainActor in await load() }
            }
        }
        """
        let hits = LaunchPathScanner.violations(inSource: source)
        XCTAssertEqual(hits.count, 1, "The dirty overload must still be scanned. Got: \\(hits)")
        XCTAssertEqual(hits.first?.scope, "start")
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

    /// Needles that mean "this schedules `MainActor` work or touches the
    /// application object".
    ///
    /// The rule is "schedule no `MainActor` work", not "write no `Task {`",
    /// so the list has to cover every idiom that reaches the main actor —
    /// otherwise a maintainer told "don't do this synchronously in `init`"
    /// reaches for `DispatchQueue.main.async` and the guard stays green
    /// while the ordering bug is back. `MainActor.assumeIsolated` is here
    /// because it calls the same `swift_task_isCurrentExecutor` family that
    /// faults in this crash family (see `NoType/UI/CLAUDE.md` hard rules,
    /// where it is rejected outright as a bridge).
    ///
    /// Matching is whitespace-normalised (`Task{`, `Task  {` and
    /// `Task(priority:)` all match `Task {`) and identifier-boundary-aware,
    /// so `NSApp` does not match `NSAppearance` / `NSApplicationDelegate`.
    ///
    /// Non-private so a launch-path file this scan's *discovery* cannot reach
    /// can still be scanned against the same list rather than a second copy
    /// of it — see
    /// `ExceptionBreadcrumbTests.test_breadcrumbSource_schedulesNoMainActorWork_andDoesNotTouchNSApp`,
    /// which exists because `ExceptionBreadcrumb.install()` enters
    /// `NoTypeApp.init()` as a static call and `constructedTypeNames` only
    /// recognises constructions.
    static let needles = [
        "Task {", "Task (", "Task.detached", "Task.init",
        "DispatchQueue.main", "OperationQueue.main", "RunLoop.main",
        "MainActor.run", "MainActor.assumeIsolated",
        "NSApp", "NSApplication.shared",
    ]

    /// Substring match with two adjustments the raw `contains` lacks:
    /// runs of whitespace in the needle match any run of whitespace (so
    /// `Task {` catches `Task{`), and a needle ending in an identifier
    /// character must not be followed by one (so `NSApp` does not match
    /// `NSAppearance`).
    static func line(_ line: String, contains needle: String) -> Bool {
        matchIndex(line, of: needle) != nil
    }

    /// The character offset of the first match of `needle` in `line`, under
    /// exactly the semantics ``line(_:contains:)`` documents, or `nil`.
    ///
    /// Non-private, and separate from the `Bool` form, because
    /// `RaiseSiteScanner` (`HUDPanelGeometryTests.swift`) needs the *position*
    /// of a match to resolve which function encloses it — and re-implementing
    /// the whitespace-normalisation and identifier-boundary rules there would
    /// be a second needle matcher to keep in sync, which is the failure mode
    /// `docs/solutions/conventions/source-scan-guard-fidelity-2026-07-25.md`
    /// warns about at the needle layer.
    static func matchIndex(_ line: String, of needle: String) -> Int? {
        let hay = Array(line)
        let pat = Array(needle)
        guard !pat.isEmpty else { return nil }
        let lastIsIdent = pat[pat.count - 1].isLetter || pat[pat.count - 1].isNumber || pat[pat.count - 1] == "_"

        var start = 0
        while start <= hay.count - 1 {
            var h = start
            var p = 0
            while p < pat.count, h <= hay.count {
                if pat[p] == " " {
                    // One space in the needle matches zero-or-more whitespace.
                    while h < hay.count, hay[h].isWhitespace { h += 1 }
                    p += 1
                } else if h < hay.count, hay[h] == pat[p] {
                    h += 1
                    p += 1
                } else {
                    break
                }
            }
            if p == pat.count {
                // Reject a match that is only a prefix of a longer identifier.
                if lastIsIdent, h < hay.count,
                   hay[h].isLetter || hay[h].isNumber || hay[h] == "_" {
                    start += 1
                    continue
                }
                return start
            }
            start += 1
        }
        return nil
    }

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

        // App sources only — never index the test target, otherwise this
        // file's own fixtures become scan targets. This MUST be anchored to
        // the app-source directory, not a `path.contains("/NoType/")`
        // substring: the repo root is itself named `NoType`, so the
        // substring form matches every path in the checkout (including
        // `NoTypeTests/`) and silently indexes the very files it claims to
        // exclude — and whether it does depends on what the clone
        // directory was named, which makes CI and local disagree.
        let appRoot = repoRoot.appendingPathComponent("NoType").standardizedFileURL.path + "/"

        var index: [String: URL] = [:]
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift" else { continue }
            guard url.standardizedFileURL.path.hasPrefix(appRoot) else { continue }
            let typeName = url.deletingPathExtension().lastPathComponent
            // Last-write-wins over an unordered enumeration would let a
            // future duplicate basename silently redirect the scan at the
            // wrong file. Fail loudly instead.
            if let existing = index[typeName] {
                throw ScanError.duplicateBasename(typeName, existing.path, url.path)
            }
            index[typeName] = url
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
    /// body, every same-file method reachable from it, and every
    /// stored-property default expression.
    ///
    /// The traversal is transitive, not one-deep. The historical offender was
    /// `init()` -> `refresh()` -> `startPollingIfNeeded()`, where the `Task`
    /// literal sits **two** hops from the initializer — a single-level scan
    /// would have walked straight past it. Same-file scoping keeps the
    /// traversal bounded without needing a real call graph.
    ///
    /// Stored-property defaults are scanned because they execute as part of
    /// construction even though they appear in no function body — `private
    /// let boot = Task { … }` is squarely on the launch path, and this
    /// codebase already uses property-default initialisers heavily
    /// (`AppState.hotkeyBinding = .load()`).
    static func violations(inSource source: String) -> [Hit] {
        let code = strippingCommentsAndStrings(source)
        let functions = functionBodies(in: code)

        var scopes: [(name: String, body: String)] = []
        var visited: Set<Int> = []
        var queue: [Int] = []

        for (i, fn) in functions.enumerated() where fn.name == "init" {
            visited.insert(i)
            queue.append(i)
        }

        while let current = queue.popLast() {
            let scope = functions[current]
            scopes.append((name: scope.name, body: scope.body))
            // Index rather than name: overloads share a name, and keying the
            // visited set on the name alone would scan only the first one —
            // a `Task {` hidden in a second overload reachable from `init`
            // would be walked past.
            for (i, candidate) in functions.enumerated()
            where candidate.name != "init"
                && !visited.contains(i)
                && scope.body.contains(candidate.name + "(") {
                visited.insert(i)
                queue.append(i)
            }
        }

        scopes.append((name: "property", body: storedPropertyDeclarations(in: code, functions: functions)))

        var hits: [Hit] = []
        for scope in scopes {
            for line in scope.body.split(separator: "\n", omittingEmptySubsequences: false) {
                for needle in needles where Self.line(String(line), contains: needle) {
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

    /// The stored-property declarations of a file: every line outside any
    /// function body that declares a `let`/`var` with an `=` initialiser.
    ///
    /// Function bodies are blanked first so a `let t = Task { … }` inside an
    /// unreachable method is not mistaken for a property default. Property
    /// *observers* (`didSet` / `willSet`) survive the blanking but are
    /// excluded by the `=` requirement — they do not fire during `init`, so
    /// flagging them would be a false positive.
    private static func storedPropertyDeclarations(
        in code: String,
        functions: [Function]
    ) -> String {
        var chars = Array(code)
        for fn in functions {
            for i in fn.range where i < chars.count && !chars[i].isNewline {
                chars[i] = " "
            }
        }
        return String(chars)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { isStoredPropertyDeclaration(String($0)) }
            .joined(separator: "\n")
    }

    /// True for a line that *declares* a property with an initialiser.
    ///
    /// The first meaningful token — after attributes (`@ObservationIgnored`)
    /// and modifiers (`private`, `private(set)`, `static`, `lazy`, …) — must
    /// be `let` or `var`. A looser "contains `let ` and `=`" test also
    /// matches `if let window = NSApp.windows.first(…)` inside a computed
    /// property, which `functionBodies` does not blank because a getter is
    /// not a `func` body. That is a false positive: it is not
    /// construction-time code.
    private static func isStoredPropertyDeclaration(_ line: String) -> Bool {
        guard line.contains("=") else { return false }

        let modifiers: Set<String> = [
            "private", "fileprivate", "internal", "public", "open", "package",
            "static", "class", "final", "lazy", "weak", "unowned",
            "nonisolated", "override", "dynamic",
        ]

        for token in line.split(whereSeparator: \.isWhitespace) {
            if token.hasPrefix("@") { continue }
            // `private(set)`, `nonisolated(unsafe)`, `unowned(unsafe)`.
            let head = token.prefix(while: { $0 != "(" })
            if modifiers.contains(String(head)) { continue }
            return token == "let" || token == "var"
        }
        return false
    }

    /// Every `init` body in a file, comment- and string-stripped. Exposed so
    /// `test_launchWork_isActuallyWiredUp_fromNoTypeAppInit` can assert on
    /// what `NoTypeApp.init()` *does*, not only on what it must not do.
    static func initBodies(inSource source: String) -> [String] {
        let code = strippingCommentsAndStrings(source)
        return functionBodies(in: code).filter { $0.name == "init" }.map(\.body)
    }

    // MARK: Parsing primitives

    /// Non-private for the same reason ``needles`` and ``matchIndex(_:of:)``
    /// are: `RaiseSiteScanner` (`HUDPanelGeometryTests.swift`) resolves which
    /// function encloses a raise-prone call, and a second brace matcher is a
    /// second thing to keep correct.
    struct Function {
        let name: String
        let body: String
        /// Character range of the body (excluding braces) in the stripped
        /// source. Used to subtract function bodies when isolating the
        /// stored-property declarations that run during construction, and to
        /// resolve the innermost function enclosing a given offset.
        let range: Range<Int>
    }

    /// All `func <name>(…) { … }` and `init(…) { … }` bodies, via brace
    /// matching. Input must already have comments and string literals
    /// stripped so the brace count is trustworthy.
    ///
    /// `deinit` is deliberately **not** matched: the `init` branch rejects a
    /// match preceded by an identifier character, so `deinit`'s body resolves
    /// to no enclosing function. That is the conservative direction for
    /// `RaiseSiteScanner` — a raise-prone call written directly in a `deinit`
    /// is reported as sitting outside every chokepoint, which is true.
    static func functionBodies(in code: String) -> [Function] {
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
                result.append(
                    Function(
                        name: name,
                        body: String(chars[(open + 1)..<close]),
                        range: (open + 1)..<close
                    )
                )
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
        case duplicateBasename(String, String, String)

        var description: String {
            switch self {
            case .missingRoot:
                "Could not find NoTypeApp.swift — launch-path discovery has no root."
            case .enumerationFailed(let path):
                "Could not enumerate repo root at \(path)"
            case .duplicateBasename(let name, let a, let b):
                """
                Two app sources are named \(name).swift, so launch-path discovery \
                cannot tell which one declares the type: \(a) and \(b). Rename one \
                — the scan resolves a constructed type to its source purely by filename.
                """
            }
        }
    }
}
