import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog

/// RAII wrapper around `IOPMAssertionCreateWithName` /
/// `IOPMAssertionRelease`. While the instance lives (and `release()`
/// hasn't been called), macOS won't put the system to sleep — useful
/// for long dictation sessions where the user may not be touching the
/// keyboard or trackpad for minutes at a time.
///
/// **Reference semantics on purpose.** A `struct` would have no
/// `deinit`, so a missed explicit `release()` would silently leak the
/// IOKit handle for the lifetime of the process. `final class` gives us
/// a deinit-driven safety net while keeping the public API ergonomic.
///
/// **Ownership lives on `AppState`, not `RecordingSession`.** The
/// session itself is a value type that may be copied during partial-
/// recovery flows; double-releasing the same IOPMAssertion id from two
/// copies would log a `Already released this id` warning into Console
/// at best and could destabilise the IOKit assertion table at worst.
/// `AppState.activeSleepAssertion` is the single source of truth — see
/// `acquireSleepAssertionIfNeeded()` / `releaseSleepAssertion()`.
///
/// Plan §304 / §314 (`docs/plans/2026-05-18-001-feat-settings-screen-plan.md`).
///
/// **Isolation.** The public API (`init` / `release()`) is `@MainActor` —
/// all production callers (`AppState.acquireSleepAssertionIfNeeded` /
/// `releaseSleepAssertion`) run on the main actor, and the explicit
/// annotation lets the compiler verify nobody touches the IOPMAssertion
/// handle from a non-main context.
///
/// The two stored properties are `nonisolated(unsafe)` because `deinit`
/// in Swift 6 runs as nonisolated by default, and must still be able to
/// read them as a safety-net release. The pattern is sound:
///
///   - `init` writes both fields (main actor).
///   - `release()` writes both fields (main actor).
///   - `deinit` reads both fields exactly once when refcount drops to
///     zero — by definition no other reference exists at that moment,
///     so there is no concurrent mutation to race against.
///
/// `(unsafe)` is the honest acknowledgement that the compiler can't
/// prove this, just like `@unchecked Sendable` on `PCMRingBuffer`.
@MainActor
final class SleepAssertion {
    /// Test-visible identifier of the underlying IOPMAssertion. Equal
    /// to `kIOPMNullAssertionID` after `release()`. See class doc-comment
    /// for the `nonisolated(unsafe)` rationale.
    nonisolated(unsafe) private(set) var assertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    /// Flips true once `release()` has run — used both to short-circuit
    /// repeat calls and to keep `deinit` from re-releasing a handle the
    /// caller already cleaned up. See class doc-comment for the
    /// `nonisolated(unsafe)` rationale.
    nonisolated(unsafe) private(set) var isReleased: Bool = false

    private static let log = Logger(subsystem: "app.notype", category: "sleep")

    /// Acquire an assertion preventing user-idle system sleep.
    ///
    /// `reason` shows up in `pmset -g assertions` and Activity Monitor's
    /// energy tab — keep it short and informative ("NoType active
    /// recording" is the production string).
    init(reason: String) throws {
        var id: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            throw Error.createFailed(returnCode: result)
        }
        self.assertionID = id
    }

    /// Release the assertion. Idempotent — repeated calls are no-ops.
    /// Safe to call from `deinit`.
    func release() {
        guard !isReleased else { return }
        if assertionID != IOPMAssertionID(kIOPMNullAssertionID) {
            let result = IOPMAssertionRelease(assertionID)
            if result != kIOReturnSuccess {
                Self.log.warning("IOPMAssertionRelease returned \(result, privacy: .public) for id=\(self.assertionID, privacy: .public)")
            }
        }
        assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        isReleased = true
    }

    deinit {
        // Safety net only — production code paths always call release()
        // explicitly. This catches programmer mistakes (early return,
        // thrown error between acquire and release) so the IOKit handle
        // doesn't leak for the rest of the process lifetime.
        if !isReleased && assertionID != IOPMAssertionID(kIOPMNullAssertionID) {
            _ = IOPMAssertionRelease(assertionID)
        }
    }

    enum Error: Swift.Error, LocalizedError {
        case createFailed(returnCode: IOReturn)

        var errorDescription: String? {
            switch self {
            case .createFailed(let code):
                return "IOPMAssertionCreateWithName failed (code=\(code))"
            }
        }
    }
}
