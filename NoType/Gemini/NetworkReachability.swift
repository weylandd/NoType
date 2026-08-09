import Foundation
import Network

/// Lazily-started `NWPathMonitor` wrapper whose only job is to answer one
/// deliberately narrow question: *does this machine currently have no
/// network path at all?*
///
/// **Why this exists.** `GeminiClient`'s `URLSession` runs with
/// `timeoutIntervalForRequest = 30` and `waitsForConnectivity = false`, so
/// a request issued with the Wi-Fi off does not fail fast — it parks for
/// the full 30 s before `URLSession` gives up. `sendRequest`'s retry policy
/// then grants a wrapped `URLError` one retry, so a single Gemini call
/// offline costs ~60.5 s, and a session that splits into N single-chunk
/// calls multiplies that. Asking the system whether a path exists before
/// issuing the request removes that wait entirely.
///
/// **Conservatism is the whole design.** A false "offline" verdict would
/// break transcription outright for a user who is in fact online — a much
/// worse failure than the wait being removed. So the answer is `true` for
/// exactly one observed state and `false` for every other state, including
/// every flavour of "don't know":
///
/// | Observed | `isDefinitelyOffline` | Why |
/// |---|---|---|
/// | `.unsatisfied` | **`true`** | The system says no interface can carry the flow. |
/// | `.satisfied` | `false` | A path exists. |
/// | `.requiresConnection` | `false` | A path exists but needs bring-up (VPN on demand, dial-on-demand). `URLSession` triggers that bring-up itself; short-circuiting would break the very case the state is for. |
/// | future `NWPath.Status` case | `false` | Mapped to `.unrecognized`; an unknown state is not evidence of absence. |
/// | monitor never started / no update yet | `false` | See the first-delivery note below. |
///
/// **The first delivery is load-bearing, not an optimisation.** Reading
/// `NWPathMonitor.currentPath` synchronously right after `start(queue:)`
/// returns `.unsatisfied` on a fully-online machine — measured, not
/// assumed — because the monitor has not yet been handed a path. Trusting
/// that read would short-circuit every first Gemini request of the process.
/// So `lastObserved` is written **only** from `pathUpdateHandler`, and a
/// query that finds it `nil` waits up to ``firstPathWaitCap`` for the first
/// real delivery before answering. That first delivery arrives in ~1 ms in
/// practice (it is a local kernel query, not a network round-trip), the
/// wait is paid at most once per process, and if it is ever exceeded the
/// answer is `false` — "assume online and let the real request decide".
///
/// Nothing here is constructed or started at launch. `GeminiClient` builds
/// this on its first request, which is long after `NSApplicationMain` — see
/// `NoType/UI/CLAUDE.md` "Launch ordering", the rule `LaunchOrderingTests`
/// scans for.
actor NetworkReachability {

    /// `NWPath.Status` mirrored into a `Sendable`, exhaustively-switchable
    /// value so the verdict below can be a pure function testable without a
    /// live monitor. `.unrecognized` is the landing site for any case Apple
    /// adds later — it exists so a new case is conservatively treated as
    /// "not offline" rather than accidentally matching `.unsatisfied`.
    enum PathStatus: Sendable, Equatable {
        case satisfied
        case unsatisfied
        case requiresConnection
        case unrecognized

        init(_ status: NWPath.Status) {
            switch status {
            case .satisfied:          self = .satisfied
            case .unsatisfied:        self = .unsatisfied
            case .requiresConnection: self = .requiresConnection
            @unknown default:         self = .unrecognized
            }
        }
    }

    /// The verdict, as a pure function over what the monitor last
    /// delivered. `nil` means the monitor has not delivered anything yet
    /// (never started, or started microseconds ago).
    ///
    /// **`.unsatisfied` is the only `true`.** Widening this — to include
    /// `.requiresConnection`, or to treat `nil` as offline — turns a
    /// latency fix into a correctness bug for users who are online. Pinned
    /// by `NetworkReachabilityTests`.
    nonisolated static func isDefinitelyOffline(lastObserved: PathStatus?) -> Bool {
        lastObserved == .unsatisfied
    }

    /// Ceiling on the one-time wait for the monitor's first delivery. Paid
    /// at most once per process, and only by the first Gemini request.
    /// Exceeding it answers `false` (assume online).
    nonisolated static let firstPathWaitCap: Duration = .milliseconds(250)

    /// Poll granularity while waiting for the first delivery. Polling
    /// rather than a continuation on purpose: the handler can fire before
    /// the waiter registers, and a resume-once continuation racing a
    /// pre-arrived value is a stall waiting to happen for no gain on a
    /// path measured in single-digit milliseconds.
    private static let pollInterval: Duration = .milliseconds(10)

    /// Serial queue the monitor delivers on. Not `.main` — this must never
    /// depend on main-runloop availability.
    private static let deliveryQueue = DispatchQueue(
        label: "app.notype.reachability",
        qos: .utility
    )

    /// `nil` until the first query starts it. Held so `start(queue:)` is
    /// called exactly once and the monitor outlives the call that made it.
    private var monitor: NWPathMonitor?

    /// Last status delivered by `pathUpdateHandler`. **Never** seeded from
    /// `NWPathMonitor.currentPath` — see the first-delivery note above.
    private var lastObserved: PathStatus?

    /// `true` only when the system has told us there is no usable network
    /// path. Every ambiguous case answers `false`.
    func isDefinitelyOffline() async -> Bool {
        startIfNeeded()
        if lastObserved == nil { await awaitFirstPath() }
        return Self.isDefinitelyOffline(lastObserved: lastObserved)
    }

    private func startIfNeeded() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            // Map inside the handler so only a `Sendable` value crosses
            // into the actor — `NWPath` itself never leaves this closure.
            let status = PathStatus(path.status)
            Task { await self?.record(status) }
        }
        m.start(queue: Self.deliveryQueue)
        monitor = m
    }

    private func record(_ status: PathStatus) {
        lastObserved = status
    }

    private func awaitFirstPath() async {
        let deadline = ContinuousClock.now.advanced(by: Self.firstPathWaitCap)
        // The cancellation term matters: `try?` on a cancelled sleep
        // returns immediately, so without it a cancelled task would spin
        // this loop hot until the deadline.
        while lastObserved == nil, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}
