import AppKit
import AVFoundation
import CoreML
import ScreenCaptureKit
import SwiftUI
import Vision
import XCTest
@preconcurrency import Sparkle
@testable import NoType

// MARK: - Probe plumbing (file-scope)

/// `objc_setExceptionPreprocessor` itself: takes the new preprocessor, returns
/// the one it replaced. Re-declared here rather than reused from
/// `ExceptionBreadcrumb` because that typealias is `private` — and this probe
/// is measurement only, so it must not widen the type under test.
private typealias ProbeSetPreprocessor =
    @convention(c) (ExceptionBreadcrumb.Preprocessor?) -> ExceptionBreadcrumb.Preprocessor?

/// Serialises every set/restore pair below. The read is a *write* followed by
/// a compensating write, so a concurrent raise landing between them would see
/// a half-swapped chain; taking this lock for the whole pair is what keeps the
/// window closed against another probe thread. It cannot close the window
/// against the rest of the process — nothing else takes this lock — which is
/// why the pair is two instructions long and never wraps framework work.
private let probeLock = NSLock()

/// Chain target for `probeSentinelPreprocessor`, written only under
/// `probeLock` while the sentinel is installed.
///
/// `nonisolated(unsafe)`: a `@convention(c)` function pointer captures nothing,
/// so the sentinel's chain target has to be reachable as a global. Writes
/// happen on the test thread inside `probeLock`; the sentinel is installed for
/// a few instructions in one test and nothing else in the process raises
/// during that window.
nonisolated(unsafe) private var probeSentinelChained: ExceptionBreadcrumb.Preprocessor?

/// A known-address preprocessor used to prove the read helper can actually
/// *see* a foreign head. Chains outward exactly like the real one — dropping
/// the chain is what aborts the process at `HIExceptions.mm:45`, and a
/// diagnostic must not be able to do that even for a few instructions.
private let probeSentinelPreprocessor: ExceptionBreadcrumb.Preprocessor = { exception in
    if let chained = probeSentinelChained { return chained(exception) }
    return exception
}

/// C function pointers have no `==`; compare raw addresses.
private func probeAddress(_ fn: ExceptionBreadcrumb.Preprocessor?) -> UnsafeRawPointer? {
    fn.map { unsafeBitCast($0, to: UnsafeRawPointer.self) }
}

private func probeAddressText(_ fn: ExceptionBreadcrumb.Preprocessor?) -> String {
    probeAddress(fn).map { "\($0)" } ?? "nil"
}

/// `RTLD_DEFAULT` — `((void *)-2)`, which Swift does not import as a constant.
private func resolveProbeSetter() -> ProbeSetPreprocessor? {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_setExceptionPreprocessor") else {
        return nil
    }
    return unsafeBitCast(symbol, to: ProbeSetPreprocessor.self)
}

/// Result of one non-destructive read of the preprocessor chain's head.
private struct ProbeHeadRead {
    /// The preprocessor that was installed at read time.
    let head: ExceptionBreadcrumb.Preprocessor?
    /// `true` when the chain was left exactly as found: either the head was
    /// already `ours` (so the probing write changed nothing), or the restoring
    /// write handed back precisely the probe value we had just installed —
    /// which is only possible if nothing moved in between.
    let restoreVerified: Bool
}

/// Reads the currently-installed preprocessor **without changing it**.
///
/// There is no getter for `objc_exception_preprocessor`. The only read is
/// `objc_setExceptionPreprocessor`, which returns the previous value — so a
/// read costs a write, and the write has to be undone. Assumes `probeLock` is
/// already held.
///
/// This helper is the load-bearing part of the whole probe: if it is wrong it
/// fails in the *safe-looking* direction (reports "still ours" forever), so
/// `test_readHelper_...` installs a known sentinel and proves the helper both
/// sees it and puts it back.
private func readHeadLocked(
    ours: ExceptionBreadcrumb.Preprocessor,
    setter: ProbeSetPreprocessor
) -> ProbeHeadRead {
    let head = setter(ours)
    guard probeAddress(head) != probeAddress(ours) else {
        // The head was already ours — the write above was a self-swap and the
        // chain topology is byte-identical. Nothing to restore.
        return ProbeHeadRead(head: head, restoreVerified: true)
    }
    let displacedByRestore = setter(head)
    // `displacedByRestore` is whatever the restoring write replaced. It must be
    // the value we wrote a moment ago; anything else means the head moved
    // underneath the pair and the "restore" wrote over a third party.
    return ProbeHeadRead(
        head: head,
        restoreVerified: probeAddress(displacedByRestore) == probeAddress(ours)
    )
}

private func readInstalledHead(
    ours: ExceptionBreadcrumb.Preprocessor,
    setter: ProbeSetPreprocessor
) -> ProbeHeadRead {
    probeLock.lock()
    defer { probeLock.unlock() }
    return readHeadLocked(ours: ours, setter: setter)
}

// MARK: - The probe

/// **Diagnostic probe, not a gate.** Answers one question and reports it:
/// *does anything NoType loads after `NoTypeApp.init()` displace our
/// Objective-C exception preprocessor?*
///
/// ## Why the question exists
///
/// `ExceptionBreadcrumb.install()` runs as the first statement of
/// `NoTypeApp.init()` and swaps `objc_exception_preprocessor` — a **single
/// global slot**. Anything that calls the setter after us and does not chain
/// outward silently unhooks us, and our own code cannot notice:
/// `State.performInstall` is behind a `didAttemptInstall` latch, so a second
/// `install()` returns `.alreadyAttempted` without re-checking the slot. A
/// field crash showed an exception was demonstrably swallowed while the
/// interceptor may have recorded nothing — displacement is one hypothesis for
/// that gap, and this measures it.
///
/// ## Why it never fails on a finding
///
/// A red CI on a diagnostic teaches reviewers to ignore it. The only hard
/// assertions here are on the **read helper's own correctness** (the sentinel
/// round-trip, and `restoreVerified` at every read). Displacement itself is
/// reported through `XCTContext` activities and stdout.
///
/// ## Reading the output
///
/// Run this class alone for an uncontaminated answer:
///
/// ```
/// xcodebuild -project NoType.xcodeproj -scheme NoType test \
///   -destination 'platform=macOS' \
///   -only-testing:NoTypeTests/ExceptionBreadcrumbDisplacementProbeTests
/// ```
///
/// In a full-suite run every earlier test has already faulted in most of these
/// frameworks, so a limb can only be blamed for a head that **changed during
/// it** — which is exactly what the per-limb verdict reports, rather than the
/// weaker "is the head ours right now".
///
/// Related: `docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`.
final class ExceptionBreadcrumbDisplacementProbeTests: XCTestCase {

    // MARK: - Step 2: prove the read helper works

    /// Installs a known sentinel preprocessor, confirms the helper reports
    /// *the sentinel* (not "still ours"), and confirms the chain comes back
    /// byte-identical.
    ///
    /// Without this, a helper that silently failed to observe a foreign head
    /// would make every limb below report a reassuring "still-ours" — the
    /// probe would lie in the direction that kills the hypothesis.
    func test_readHelper_reportsAnInstalledSentinel_andRestoresTheChainExactly() throws {
        let setter = try XCTUnwrap(
            resolveProbeSetter(),
            "dlsym(RTLD_DEFAULT, objc_setExceptionPreprocessor) returned nil — the probe cannot read the slot at all."
        )
        let ours = try XCTUnwrap(
            ExceptionBreadcrumb.install(),
            "ExceptionBreadcrumb is not armed in this process; there is no 'ours' to compare against."
        )

        let baseline = readInstalledHead(ours: ours, setter: setter)
        XCTAssertTrue(baseline.restoreVerified, "Baseline read did not restore the head it found.")

        // Whole round-trip under one lock: the sentinel is head for a handful
        // of instructions and its chain target has to be published before any
        // raise could reach it.
        probeLock.lock()
        let replacedBySentinel = setter(probeSentinelPreprocessor)
        probeSentinelChained = replacedBySentinel
        let observed = readHeadLocked(ours: ours, setter: setter)
        let displacedByRestoreOfSentinel = setter(replacedBySentinel)
        probeSentinelChained = nil
        probeLock.unlock()

        XCTAssertEqual(
            probeAddress(observed.head),
            probeAddress(probeSentinelPreprocessor),
            "The read helper did not see the sentinel it was pointed at — every 'still-ours' verdict below would be worthless."
        )
        XCTAssertTrue(
            observed.restoreVerified,
            "The read helper's restoring write did not hand back the probe value it had just installed."
        )
        XCTAssertEqual(
            probeAddress(displacedByRestoreOfSentinel),
            probeAddress(probeSentinelPreprocessor),
            "After the helper ran, the head was not the sentinel — the helper failed to put back what it found."
        )

        let after = readInstalledHead(ours: ours, setter: setter)
        XCTAssertTrue(after.restoreVerified, "Post-sentinel read did not restore the head it found.")
        XCTAssertEqual(
            probeAddress(after.head),
            probeAddress(baseline.head),
            "The sentinel round-trip left the process with a different head than it started with."
        )

        print("""
        [EXC-PROBE] read-helper sentinel round-trip OK \
        baseline=\(probeAddressText(baseline.head)) \
        sentinel=\(probeAddressText(probeSentinelPreprocessor)) \
        observed=\(probeAddressText(observed.head)) \
        restored=\(probeAddressText(after.head)) \
        ours=\(probeAddressText(ours))
        """)
    }

    // MARK: - Step 3: exercise each framework, read the head after each

    /// Force-loads and does representative work with each framework NoType
    /// pulls in after launch, reading the head after every limb so a culprit
    /// is *named* rather than merely detected.
    ///
    /// Nothing here starts an engine, opens the mic, hits the network, or
    /// requests a TCC permission — the point is to load and touch the
    /// frameworks, not to run the features.
    @MainActor
    func test_frameworkLimbs_probeWhetherAnythingDisplacesThePreprocessor() throws {
        let setter = try XCTUnwrap(resolveProbeSetter())
        let ours = try XCTUnwrap(ExceptionBreadcrumb.install())

        let baseline = readInstalledHead(ours: ours, setter: setter)
        XCTAssertTrue(baseline.restoreVerified, "Baseline read did not restore the head it found.")

        var previousHead = probeAddress(baseline.head)
        let oursAddress = probeAddress(ours)
        var report: [String] = []

        let baselineLine = """
        baseline: head=\(probeAddressText(baseline.head)) ours=\(probeAddressText(ours)) \
        → \(previousHead == oursAddress ? "STILL-OURS" : "ALREADY-NOT-OURS")
        """
        report.append(baselineLine)
        print("[EXC-PROBE] \(baselineLine)")

        // Each limb is `throws` and guarded, so one unavailable framework
        // reports itself and the probe keeps going.
        let limbs: [(name: String, run: @MainActor () throws -> Void)] = [
            ("Sparkle/SPUUpdater", {
                // Exactly what the app builds at launch: SPUUpdater over our
                // custom SPUUserDriver. No start(), no network.
                _ = UpdateController()
            }),
            ("CoreML/SileroVAD", {
                // Same load the recording path performs: MLModel over the
                // compiled SileroVAD.mlmodelc in the host bundle.
                _ = try SileroVAD()
            }),
            ("AVFAudio/AVAudioEngine", {
                // MicProbe's shape, minus the parts that open hardware: no
                // installTap, no start(), no mic.
                let engine = AVAudioEngine()
                _ = engine.inputNode.outputFormat(forBus: 0)
            }),
            ("Vision/VNRecognizeTextRequest", {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                _ = try request.supportedRecognitionLanguages()
            }),
            ("ScreenCaptureKit/SCStreamConfiguration", {
                // Construction only — no SCShareableContent query, so no
                // Screen Recording permission is touched.
                let config = SCStreamConfiguration()
                config.width = 320
                _ = config.width
            }),
            ("AppKit/NSPanel+NSVisualEffectView", {
                let panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                let blur = NSVisualEffectView()
                blur.material = .hudWindow
                blur.blendingMode = .behindWindow
                blur.state = .active
                panel.contentView = blur
                panel.layoutIfNeeded()
            }),
            ("SwiftUI/NSHostingView (HUDPanel)", {
                // The real HUDPanel: NSHostingView inside the blur view,
                // measured through its validated-geometry chokepoint.
                _ = HUDPanel(rootView: Text("exception-preprocessor probe"))
            }),
        ]

        for limb in limbs {
            var limbError: String?
            do {
                try limb.run()
            } catch {
                limbError = String(describing: error)
            }

            let read = readInstalledHead(ours: ours, setter: setter)
            XCTAssertTrue(
                read.restoreVerified,
                "Read after \(limb.name) did not restore the head it found — the probe's own read is unreliable here."
            )
            let head = probeAddress(read.head)
            let changed = head != previousHead
            let isOurs = head == oursAddress

            let verdict: String
            switch (isOurs, changed) {
            case (true, false):
                verdict = "STILL-OURS"
            case (true, true):
                verdict = "BACK-TO-OURS (head changed during this limb, now ours again)"
            case (false, true):
                verdict = "DISPLACED-BY \(probeAddressText(read.head)) (changed during this limb)"
            case (false, false):
                verdict = "NOT-OURS \(probeAddressText(read.head)) (unchanged by this limb — displaced earlier)"
            }

            let line = "\(limb.name): \(verdict)"
                + (limbError.map { " [limb error: \($0)]" } ?? "")
            report.append(line)
            print("[EXC-PROBE] \(line)")

            XCTContext.runActivity(named: "preprocessor head after \(limb.name)") { activity in
                activity.add(XCTAttachment(string: line))
            }

            previousHead = head
        }

        let final = readInstalledHead(ours: ours, setter: setter)
        XCTAssertTrue(final.restoreVerified, "Final read did not restore the head it found.")
        let summary = probeAddress(final.head) == oursAddress
            ? "VERDICT: nothing displaced ExceptionBreadcrumb across any limb."
            : "VERDICT: the head is NOT ours after the limbs — see the per-limb lines for the culprit."
        report.append(summary)
        print("[EXC-PROBE] \(summary)")

        XCTContext.runActivity(named: "displacement probe report") { activity in
            activity.add(XCTAttachment(string: report.joined(separator: "\n")))
        }
    }
}
