import Darwin
import Foundation
import os

/// Process-wide observer for **every Objective-C exception raised inside this
/// process**, including the ones nothing else can see.
///
/// ## Why this exists
///
/// An `NSException` raised on the main thread inside a `Task { @MainActor }`
/// body unwinds through `libswift_Concurrency`, whose `ExecutorTrackingInfo`
/// is a stack-allocated thread-local with a non-exception-safe pop. The
/// unwind orphans the main thread's executor identity; AppKit then *swallows*
/// the exception at the run-loop boundary and resumes, so the next
/// "am I on the main executor?" check reads a dead stack slot and SIGSEGVs —
/// typically hundreds of milliseconds and one unrelated user action later.
/// The crash site is therefore arbitrary and tells you nothing about the
/// cause. Three separate incidents were misdiagnosed as SwiftUI
/// dispatch-path bugs before the mechanism was found.
///
/// Nothing else observes that throw. `NSSetUncaughtExceptionHandler` does
/// **not** fire — AppKit catches first. A crash report does not name it —
/// it faults in an unrelated frame later. This preprocessor is the only hook
/// that runs at throw time, before any unwinding, which is what turns a
/// two-month investigation into a log line.
///
/// Full write-up:
/// `docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`.
///
/// ## Contract
///
/// - **Observer only.** The preprocessor logs and returns what it was handed.
///   It alters no control flow, and it performs **no network I/O** — records
///   go to `os.Logger` and leave the device only when the *user* chooses to
///   attach them to an issue (see the README's `## Known issues` recipe,
///   which is this breadcrumb's entire user-facing surface).
/// - **Chains outward, always.** `objc_setExceptionPreprocessor` returns
///   whatever it replaced, and dropping that pointer is *not* a no-op:
///   Foundation's preprocessor is what populates
///   `NSException.callStackReturnAddresses`, and without it HIToolbox aborts
///   the process on the spot — `Assertion failed:
///   (callStackReturnAddresses), -[NSException(HIServices) hashString],
///   HIExceptions.mm:45` → `SIGABRT`. Measured, not argued. Discarding the
///   chain would convert every swallowed exception in NoType into an instant
///   crash on every machine, which is strictly worse than the bug this is
///   here to diagnose.
/// - **Idempotent.** A second `install()` is a no-op, so our own hook can
///   never end up chained to itself.
/// - **Always on, in release, with no flag.** It is a single function-pointer
///   swap costing nothing when nothing throws, the API is public since 10.5,
///   it is process-local (no code injection, no `DYLD_INSERT_LIBRARIES`) and
///   needs no entitlement. Gating it behind a debug flag would guarantee it
///   is off on exactly the machines that need it.
///
/// The symbol is reached through `dlsym` rather than a bridging header: the
/// repo is pure Swift, and adding an Objective-C compilation unit for one
/// function pointer is disproportionate.
enum ExceptionBreadcrumb {

    // MARK: - Wire format

    /// C signature of `objc_exception_preprocessor`:
    /// `id _Nullable (*)(id _Nonnull)`.
    typealias Preprocessor = @convention(c) (AnyObject) -> AnyObject?

    /// Prefix of every throw record. **Load-bearing literal** — the README
    /// retrieval recipe, the plan's acceptance examples and the tester
    /// round-trip all key on this exact string. Don't reword it.
    static let throwMarker = "OBJC THROW"

    /// Emitted once from `install()` when the swap succeeded.
    ///
    /// This is what makes an empty log a *result* rather than an ambiguity:
    /// without it, "no `OBJC THROW` line" cannot be told from "the
    /// interceptor never installed", and those two readings point at opposite
    /// conclusions. Same reasoning as `AppState.prime()`'s entry breadcrumb,
    /// one level up.
    static let armedMarker = "EXC BREADCRUMB armed"

    /// Emitted instead of `armedMarker` when the `dlsym` lookup returns nil.
    /// Deliberately a *distinct* line — see `armedMarker`.
    static let unavailableMarker = "EXC BREADCRUMB unavailable"

    /// Emitted once, after `maxRecordsPerLaunch`, in place of further records.
    static let capReachedMarker = "EXC BREADCRUMB further exceptions not logged"

    // MARK: - Bounds

    /// Exception records logged per launch, then silence plus one
    /// `capReachedMarker` line.
    ///
    /// The unified log's persistent store is a **system-wide**, size-bounded
    /// ring. An always-on preprocessor that may fire in a loop must not evict
    /// other processes' records to report the same fault twenty thousand
    /// times; twenty is plenty to characterise a thrower.
    static let maxRecordsPerLaunch = 20

    /// Stack frames kept per record. An unbounded symbol join inside a
    /// preprocessor that may fire repeatedly is its own hazard.
    static let maxStackFrames = 16

    /// Scrubbed `reason` characters kept per record.
    static let maxReasonLength = 512

    // MARK: - Install

    /// Installs the interceptor. Idempotent; safe to call from anywhere.
    ///
    /// Called as the **first statement of `NoTypeApp.init()`** — before every
    /// type that initializer constructs, and well before the earliest throw
    /// observed in the field. Pinned by
    /// `ExceptionBreadcrumbTests.test_noTypeAppInit_installsBreadcrumbFirst`.
    ///
    /// - Returns: the preprocessor now installed, or `nil` when the `dlsym`
    ///   lookup failed (in which case nothing was swapped and the
    ///   `unavailableMarker` line was logged instead of `armedMarker`). A
    ///   non-`nil` return is therefore proof the process is armed.
    @discardableResult
    static func install() -> Preprocessor? {
        guard state.claimInstallAttempt() else { return state.installedPreprocessor }

        guard let symbol = dlsym(rtldDefault, "objc_setExceptionPreprocessor") else {
            log.fault("\(unavailableLine(), privacy: .public)")
            return nil
        }

        let setter = unsafeBitCast(symbol, to: SetPreprocessor.self)
        let replaced = setter(preprocessor)
        state.recordInstall(ours: preprocessor, chained: replaced)

        log.fault("\(armedLine(chained: replaced != nil), privacy: .public)")
        return preprocessor
    }

    /// The preprocessor `install()` replaced, retained so every record chains
    /// outward to it. `nil` only if nothing was installed before us.
    ///
    /// Exposed for `ExceptionBreadcrumbTests` — the "install twice" case
    /// asserts this pointer is retained across the second call and is never
    /// our own hook.
    static var chainedPreprocessor: Preprocessor? { state.chainedPreprocessor }

    // MARK: - Record formatting (pure)

    /// Text of the `armedMarker` line. Pure so the format is pinned by a test
    /// rather than by reading `install()`.
    static func armedLine(chained: Bool) -> String {
        "\(armedMarker) cap=\(maxRecordsPerLaunch) frames=\(maxStackFrames) chained=\(chained)"
    }

    /// Text of the `unavailableMarker` line — the one that says a `log show`
    /// returning nothing means *nobody was watching*, not *nothing threw*.
    static func unavailableLine() -> String {
        "\(unavailableMarker) dlsym(RTLD_DEFAULT, objc_setExceptionPreprocessor) returned nil — no exception records will be written this launch"
    }

    /// The exact text a throw record carries. Pure, so the tests pin what is
    /// logged instead of a paraphrase of it.
    ///
    /// `reason` is the only attacker- or content-controlled field here, so it
    /// is the only one scrubbed — see `scrubbedReason(_:)`. `name`,
    /// `mainThread` and the bounded symbol list are framework-authored and
    /// safe verbatim, which is what lets the whole line be logged
    /// `privacy: .public` (and it must be public, or `log show` returns
    /// `<private>` and the record is worthless to a reporter).
    static func formatRecord(
        name: String,
        reason: String?,
        isMainThread: Bool,
        stack: [String]
    ) -> String {
        let frames = stack.prefix(maxStackFrames)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " | ")
        return """
        \(throwMarker) name=\(name) mainThread=\(isMainThread) \
        reason=\(scrubbedReason(reason)) stack=\(frames)
        """
    }

    /// Scrubs and length-caps an exception's `reason` before it is logged.
    ///
    /// `objc_setExceptionPreprocessor` is process-wide, so this observes
    /// exceptions raised by Foundation, AppKit, URLSession and Sparkle —
    /// including at the boundaries where NoType hands Objective-C its most
    /// sensitive values (the full transcript into `NSPasteboard.setString`,
    /// the Gemini key into the `x-goog-api-key` header). `reason` is authored
    /// by the *raising framework*, with interpolated arguments this app does
    /// not control, so logging it verbatim would be an unbacked assertion of
    /// safety. `NoType/Keychain/CLAUDE.md` forbids the API key reaching a log
    /// at any level, and `NoType/Context/CLAUDE.md` already mandates this
    /// masker for every other path that carries user-visible content.
    static func scrubbedReason(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "(none)" }
        let scrubbed = SecureFieldMasker.scrubContent(raw)
        guard scrubbed.count > maxReasonLength else { return scrubbed }
        return scrubbed.prefix(maxReasonLength) + "…(truncated)"
    }

    /// What the per-launch budget allows for one observed exception.
    enum RecordSlot: Equatable {
        /// Log a full record.
        case record
        /// Log `capReachedMarker` once, then nothing further.
        case capReached
        /// Log nothing.
        case silent
    }

    /// What the per-launch budget says about the `count`-th exception seen
    /// (zero-based). Pure so `maxRecordsPerLaunch` is pinned without driving
    /// the process-wide counter from a test.
    static func recordSlot(forCount count: Int) -> RecordSlot {
        if count < maxRecordsPerLaunch { return .record }
        if count == maxRecordsPerLaunch { return .capReached }
        return .silent
    }

    // MARK: - The hook

    private static let log = Logger(subsystem: "app.notype", category: "exception")

    /// `RTLD_DEFAULT` — `((void *)-2)` in `dlfcn.h`, which Swift does not
    /// import as a constant. A computed property rather than a `static let`
    /// because a raw pointer is not `Sendable`, and it is a compile-time
    /// constant anyway.
    private static var rtldDefault: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: -2)
    }

    /// C signature of `objc_setExceptionPreprocessor` itself: it takes the new
    /// preprocessor and returns the one it replaced.
    private typealias SetPreprocessor = @convention(c) (Preprocessor?) -> Preprocessor?

    /// Captures nothing, so it converts to a C function pointer. It may run on
    /// any thread — every piece of shared state it touches is behind
    /// `State`'s lock.
    private static let preprocessor: Preprocessor = { exception in
        ExceptionBreadcrumb.observe(exception)
        // R6 / the chaining contract: hand the exception onward untouched and
        // return whatever the previous installer decides. Never swallow, never
        // substitute.
        if let chained = ExceptionBreadcrumb.state.chainedPreprocessor {
            return chained(exception)
        }
        return exception
    }

    private static func observe(_ exception: AnyObject) {
        switch state.claimRecordSlot() {
        case .silent:
            return
        case .capReached:
            log.fault("\(capReachedMarker, privacy: .public)")
        case .record:
            let ns = exception as? NSException
            let record = formatRecord(
                name: ns?.name.rawValue ?? String(describing: type(of: exception)),
                reason: ns?.reason,
                isMainThread: Thread.isMainThread,
                stack: Thread.callStackSymbols
            )
            log.fault("\(record, privacy: .public)")
        }
    }

    // MARK: - Shared state

    /// Lock-guarded because the preprocessor fires on whichever thread raised.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var didAttemptInstall = false
        private var ours: Preprocessor?
        private var chained: Preprocessor?
        private var recordCount = 0

        /// `true` for the first caller only — the one that performs the swap.
        /// Every later caller gets `false`, which is what keeps our hook from
        /// being chained to itself.
        func claimInstallAttempt() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if didAttemptInstall { return false }
            didAttemptInstall = true
            return true
        }

        func recordInstall(ours: Preprocessor, chained: Preprocessor?) {
            lock.lock()
            self.ours = ours
            self.chained = chained
            lock.unlock()
        }

        /// `nil` when the `dlsym` lookup failed — deliberately not "whatever
        /// `install()` would have set", so a repeat caller is told the truth.
        var installedPreprocessor: Preprocessor? {
            lock.lock()
            defer { lock.unlock() }
            return ours
        }

        var chainedPreprocessor: Preprocessor? {
            lock.lock()
            defer { lock.unlock() }
            return chained
        }

        func claimRecordSlot() -> RecordSlot {
            lock.lock()
            defer { lock.unlock() }
            let slot = ExceptionBreadcrumb.recordSlot(forCount: recordCount)
            if slot != .silent { recordCount += 1 }
            return slot
        }
    }

    private static let state = State()
}
