import XCTest
import Network
@testable import NoType

/// Pins the conservatism policy of the offline pre-check.
///
/// The value of this feature is removing a 30-second-per-attempt wait when
/// the machine is offline. Its risk is the exact opposite: a false
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
