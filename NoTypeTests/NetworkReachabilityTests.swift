import XCTest
import Network
@testable import NoType

/// Pins the conservatism policy of the offline pre-check.
///
/// The value of this feature is removing a whole-inactivity-budget wait
/// per attempt when the machine is offline — `GeminiClient
/// .requestInactivityBudget(audioPartCount:)`, doubled by the status-0
/// retry. Its risk is the exact opposite: a false
/// "offline" verdict breaks transcription outright for a user who is
/// online. So the tests that matter here are the ones asserting the states
/// that must **not** short-circuit — every one of them is a way the fix
/// could turn into a regression.
final class NetworkReachabilityTests: XCTestCase {

    // MARK: - The verdict

    func test_unsatisfied_isTheOnlyOfflineVerdict() {
        XCTAssertTrue(
            NetworkReachability.isDefinitelyOffline(lastObserved: .unsatisfied),
            "An `.unsatisfied` path is the one state the system is telling us there is no network."
        )
    }

    func test_satisfied_isNotOffline() {
        XCTAssertFalse(NetworkReachability.isDefinitelyOffline(lastObserved: .satisfied))
    }

    /// `.requiresConnection` means a path exists but needs bring-up (VPN on
    /// demand, dial-on-demand). `URLSession` triggers that bring-up itself,
    /// so short-circuiting here would break the very case the state exists
    /// for.
    func test_requiresConnection_isNotOffline() {
        XCTAssertFalse(
            NetworkReachability.isDefinitelyOffline(lastObserved: .requiresConnection),
            "requiresConnection is a path that needs bring-up, not an absent path."
        )
    }

    /// A future `NWPath.Status` case maps to `.unrecognized`. An unknown
    /// state is not evidence of absence.
    func test_unrecognized_isNotOffline() {
        XCTAssertFalse(NetworkReachability.isDefinitelyOffline(lastObserved: .unrecognized))
    }

    /// The single most dangerous state: the monitor has been created but
    /// has not yet delivered a path. Reading `NWPathMonitor.currentPath`
    /// synchronously at that moment returns `.unsatisfied` on a fully
    /// online machine, which is exactly why `lastObserved` is written only
    /// from `pathUpdateHandler` and why `nil` must answer "not offline".
    func test_noObservationYet_isNotOffline() {
        XCTAssertFalse(
            NetworkReachability.isDefinitelyOffline(lastObserved: nil),
            "An unstarted / not-yet-delivered monitor must never short-circuit a request."
        )
    }

    // MARK: - NWPath.Status mapping

    func test_mapping_coversEveryKnownStatus() {
        XCTAssertEqual(NetworkReachability.PathStatus(NWPath.Status.satisfied), .satisfied)
        XCTAssertEqual(NetworkReachability.PathStatus(NWPath.Status.unsatisfied), .unsatisfied)
        XCTAssertEqual(NetworkReachability.PathStatus(NWPath.Status.requiresConnection), .requiresConnection)
    }

    /// The mapping must not collapse distinct statuses onto `.unsatisfied`
    /// — that is the shape a careless `@unknown default` would produce.
    func test_mapping_doesNotCollapseOntoUnsatisfied() {
        let mapped: [NetworkReachability.PathStatus] = [
            .init(NWPath.Status.satisfied),
            .init(NWPath.Status.requiresConnection),
        ]
        XCTAssertFalse(mapped.contains(.unsatisfied))
    }

    // MARK: - The one-time first-delivery wait

    /// The wait is a bounded fallback, not a synchronisation primitive: it
    /// must stay small enough that paying it once per process is invisible
    /// next to a Gemini round-trip (~2-5 s), and it must not be zero or the
    /// first request of every process is answered from a `nil` observation.
    func test_firstPathWaitCap_isBoundedAndNonZero() {
        XCTAssertGreaterThan(NetworkReachability.firstPathWaitCap, .zero)
        XCTAssertLessThanOrEqual(NetworkReachability.firstPathWaitCap, .milliseconds(500))
    }

    // MARK: - Delivery ordering

    /// The verdict is last-writer-wins over a field only the delivery
    /// consumer writes, so the order those writes land in *is* the verdict.
    ///
    /// This is the false-offline failure that does not heal: nothing
    /// re-reads the path after the first delivery, so an `.unsatisfied`
    /// that lands after a newer `.satisfied` short-circuits every Gemini
    /// request until the *next* path change — which on a stable connection
    /// may be hours. A burst of updates (waking from sleep, VPN bring-up,
    /// Wi-Fi roaming) is exactly when two deliveries arrive close enough
    /// together for the hop to reorder, which is why the handler feeds a
    /// single-consumer `AsyncStream` rather than spawning one unstructured
    /// `Task` per update — unstructured tasks have no ordering guarantee
    /// relative to each other.
    ///
    /// **Scope, stated so a green run is not over-trusted:** these two
    /// cases pin the *semantics* `record` must have — the newest delivery
    /// decides, in both directions — which is what makes ordering the only
    /// remaining variable. They do **not** prove the ordering itself: they
    /// drive `record` sequentially from the test, so they pass under the
    /// unstructured-`Task` shape too. The ordering guarantee is structural
    /// (one consumer draining one stream) and is not observable from
    /// outside this actor without injecting the delivery source.
    func test_recordsAreLastWriterWins_soTheNewestDeliveryDecides() async {
        let probe = NetworkReachability()
        await probe.record(.unsatisfied)
        await probe.record(.satisfied)
        let offline = await probe.isDefinitelyOffline()
        XCTAssertFalse(
            offline,
            "A newer `.satisfied` delivery must win. If an older `.unsatisfied` can land last, an online machine is locked out of transcription until the next path change."
        )
    }

    /// The complement, so the assertion above is not passing merely because
    /// the verdict is stuck on `false`.
    func test_recordsAreLastWriterWins_inTheOfflineDirectionToo() async {
        let probe = NetworkReachability()
        await probe.record(.satisfied)
        await probe.record(.unsatisfied)
        let offline = await probe.isDefinitelyOffline()
        XCTAssertTrue(offline, "The newest delivery decides in both directions.")
    }

    /// End-to-end against a live monitor. This machine has a network path
    /// while the suite runs, so the assertion is the safe direction: a real
    /// monitor on a real online machine must not report offline. If this
    /// ever fails on a genuinely offline runner it is telling the truth,
    /// which is why it asserts a value rather than skipping.
    func test_liveProbe_onAnOnlineMachine_doesNotReportOffline() async throws {
        let probe = NetworkReachability()
        let offline = await probe.isDefinitelyOffline()
        XCTAssertFalse(
            offline,
            "A live path monitor reported no network path. Either this runner is offline, or the first-delivery guard regressed and the synchronous `currentPath` read leaked back in."
        )
    }
}
