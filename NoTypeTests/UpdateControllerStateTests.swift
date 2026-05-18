import XCTest
@preconcurrency import Sparkle
@testable import NoType

/// Pins the phase state machine + pending-reply dispatch surface that
/// `UpdateBanner` and `SettingsTabView` rely on. The Sparkle SDK
/// (`SPUUpdater` networking, `SUAppcastItem` decoding, signature
/// verification) is not unit-testable per `NoType/Updates/CLAUDE.md`
/// "Testing"; this file covers only what we own:
///
///   1. `setPhase(_:)` mutates `phase` and is a no-op for the same value.
///   2. `skipThisVersion()` dispatches `SPUUserUpdateChoice.skip` exactly
///      once, clears all three `pending*` slots, and returns to `.idle`
///      (without crashing when the reply slot is empty).
///   3. `dismiss()` dispatches `.dismiss` — distinct from `skip` —
///      regression guard against the AE6 closure path mixing the two.
///   4. `installNow()` dispatches `.install` from the appropriate slot
///      and never produces a `.skip`.
///
/// Construction note: `UpdateController.init` creates an `SPUUpdater`
/// against `Bundle.main` but does NOT call `start()`, so no Sparkle
/// network / appcast / EdDSA work happens. The pending reply closures
/// are synthetic — we hand the controller a closure that flips a local
/// flag, never the real Sparkle one.
@MainActor
final class UpdateControllerStateTests: XCTestCase {

    // MARK: - setPhase

    func test_setPhase_changesPhase_fromIdleToChecking() {
        let controller = UpdateController()
        XCTAssertEqual(controller.phase, .idle)

        controller.setPhase(.checking)

        XCTAssertEqual(controller.phase, .checking)
    }

    func test_setPhase_isNoOp_whenSameValue() {
        let controller = UpdateController()
        controller.setPhase(.available(.init(versionString: "0.2.0")))

        // Reassigning the same case must not "re-fire" SwiftUI animation
        // by mutating `phase` — the `guard phase != newPhase` line in
        // `setPhase(_:)` is the only place this is enforced.
        controller.setPhase(.available(.init(versionString: "0.2.0")))

        XCTAssertEqual(controller.phase, .available(.init(versionString: "0.2.0")))
    }

    // MARK: - skipThisVersion (AE6 closure)

    func test_skipThisVersion_dispatchesSkip_andReturnsToIdle() {
        let controller = UpdateController()
        controller.setPhase(.available(.init(versionString: "0.2.0")))

        var capturedChoice: SPUUserUpdateChoice?
        controller.pendingUpdateReply = { choice in capturedChoice = choice }

        controller.skipThisVersion()

        XCTAssertEqual(
            capturedChoice,
            .skip,
            "skipThisVersion must dispatch .skip — Sparkle persists this as a SUSkippedVersion."
        )
        XCTAssertEqual(controller.phase, .idle, "Banner must clear after skipping.")
    }

    func test_skipThisVersion_clearsAllPendingSlots() {
        let controller = UpdateController()
        controller.pendingUpdateReply  = { _ in }
        controller.pendingInstallReply = { _ in }
        controller.pendingCancellation = { /* no-op */ }

        controller.skipThisVersion()

        XCTAssertNil(controller.pendingUpdateReply,  "pendingUpdateReply must be cleared after skip.")
        XCTAssertNil(controller.pendingInstallReply, "pendingInstallReply must be cleared after skip.")
        XCTAssertNil(controller.pendingCancellation, "pendingCancellation must be cleared after skip.")
    }

    func test_skipThisVersion_doubleClick_isSafe() {
        let controller = UpdateController()
        var dispatchCount = 0
        controller.pendingUpdateReply = { _ in dispatchCount += 1 }

        controller.skipThisVersion()
        controller.skipThisVersion()  // second call: slot already cleared
        controller.skipThisVersion()

        XCTAssertEqual(
            dispatchCount,
            1,
            "Sparkle reply slot must not be re-fired — second call is a no-op."
        )
        XCTAssertEqual(controller.phase, .idle)
    }

    func test_skipThisVersion_withoutPendingReply_isNoOp() {
        let controller = UpdateController()
        // No pendingUpdateReply installed — banner not in .available state.
        controller.setPhase(.checking)

        controller.skipThisVersion()

        // No crash; phase untouched because the early return short-circuits.
        XCTAssertEqual(controller.phase, .checking)
    }

    // MARK: - dismiss vs skip (regression: keep the two choices distinct)

    func test_dismiss_dispatchesDismiss_notSkip() {
        let controller = UpdateController()
        var capturedChoice: SPUUserUpdateChoice?
        controller.pendingUpdateReply = { choice in capturedChoice = choice }

        controller.dismiss()

        XCTAssertEqual(
            capturedChoice,
            .dismiss,
            "dismiss() must dispatch .dismiss — Sparkle re-offers next 24 h check. Crossing wires with .skip would silence forever."
        )
    }

    // MARK: - installNow (regression: never produces .skip)

    func test_installNow_dispatchesInstall_fromUpdateReplySlot() {
        let controller = UpdateController()
        var capturedChoice: SPUUserUpdateChoice?
        controller.pendingUpdateReply = { choice in capturedChoice = choice }

        controller.installNow()

        XCTAssertEqual(capturedChoice, .install)
    }

    func test_installNow_dispatchesInstall_fromInstallReplySlot_andTransitionsInstalling() {
        let controller = UpdateController()
        var capturedChoice: SPUUserUpdateChoice?
        controller.pendingInstallReply = { choice in capturedChoice = choice }

        controller.installNow()

        XCTAssertEqual(capturedChoice, .install)
        XCTAssertEqual(controller.phase, .installing)
    }

    // MARK: - Phase equality (covers the `.available(AvailableUpdate)` case)

    func test_availableUpdate_equality_matchesByVersionString() {
        let a = UpdateController.AvailableUpdate(versionString: "0.2.0")
        let b = UpdateController.AvailableUpdate(versionString: "0.2.0")
        let c = UpdateController.AvailableUpdate(versionString: "0.2.1")

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
