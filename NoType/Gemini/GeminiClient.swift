import Foundation
import OSLog

/// Serial actor that owns all Gemini transcription traffic. By construction
/// at most one `generateContent` request is outstanding at a time
/// (invariant I1, ADR-006); chunk boundaries that fire while a request is
/// in flight queue behind it on the actor.
///
/// The user-message `parts` order is **load-bearing for cost**. See
/// `NoType/Gemini/CLAUDE.md` for the rationale. Editing this without
/// understanding implicit caching will silently undo a ~90 % discount on
/// the prefix tokens.
actor GeminiClient {
    private static let log = Logger(subsystem: "app.notype", category: "gemini")
    private static let endpoint = "https://generativelanguage.googleapis.com/v1beta/models"

    /// File-scope `URL` for the models-listing endpoint. Used by
    /// `validateKey(_:)`. Force-unwrap is a documented exception — the
    /// base URL is a compile-time literal, malformed → programming error.
    private static let modelsListURL = URL(string: endpoint)!

    /// `generateContent` endpoint for a specific model. The model is
    /// chosen per-request now: Settings → API & Usage lets the user
    /// switch *transcription* between Flash-Lite (default) and Flash to
    /// A/B quality, frozen into each `RecordingSession` at start. The
    /// app-categorizer (`classifyApp`) always passes `.flashLite`.
    /// Force-unwrap is the same documented compile-time-literal
    /// exception as `modelsListURL` — `model.rawValue` is a fixed model
    /// id, never user input.
    static func generateContentURL(for model: GeminiModel) -> URL {
        URL(string: "\(endpoint)/\(model.rawValue):generateContent")!
    }

    enum GeminiError: Error, LocalizedError {
        case missingKey
        case http(status: Int, body: String)
        case decoding(Error)
        case empty
        case blocked(String)
        /// Gemini stopped generating because it hit the output-token cap
        /// (`finishReason == "MAX_TOKENS"`) — the returned text is a
        /// partial, silently-cut transcript. Recoverable (not terminal):
        /// classified as a gap so the user sees a `[…]` marker instead of
        /// a sentence that looks complete but isn't. See
        /// `finishReasonError(_:)` and `RecordingSession.isTerminal(_:)`.
        case truncated

        var errorDescription: String? {
            switch self {
            case .missingKey:                       "Set a Gemini API key in Settings."
            case .http(let s, _) where s == 401:    "Gemini rejected the API key."
            case .http(let s, _) where s == 403:    "Gemini API key is not authorized for this model."
            case .http(let s, _) where s == 429:    "Gemini rate limit reached. Try again in a moment."
            case .http(let s, _) where s >= 500:    "Gemini is having trouble (HTTP \(s))."
            // Status 0 carrying a wrapped `URLError` — the offline /
            // timed-out / DNS-failed class. Without this arm it falls into
            // the generic branch below and renders as "Gemini error 0.",
            // which discards the one fact worth logging: *which* network
            // failure it was. `RecordingSession` logs this string at
            // `.public` on every recoverable failure, so that loss made
            // offline, timeout and DNS indistinguishable in Console.
            //
            // Deliberately gated on the `URLError code=` prefix rather than
            // on `s == 0` alone, so it is provably log-only: the only other
            // producer of a status-0 error is `validateKey`'s
            // "no HTTPURLResponse" body, which has no prefix, keeps the
            // generic rendering, and is the one status-0 shape that reaches
            // a user-facing surface (`GeminiKeyRow.errorMessage`).
            case .http(let s, let body) where s == 0 && body.hasPrefix(Self.urlErrorBodyPrefix):
                "Gemini network failure — \(body)"
            case .http(let s, let body):
                Self.descriptionForGenericHTTP(status: s, body: body)
            case .decoding:                         "Couldn't read Gemini's response."
            case .empty:                            "Gemini returned an empty transcription."
            case .blocked(let reason):              "Gemini blocked the request: \(reason)."
            case .truncated:                        "Gemini cut the transcription short."
            }
        }

        /// Prefix of the `body` every wrapped `URLError` carries. Read by
        /// `NetworkErrorTranslator.parse` (which recovers **both** the
        /// numeric code and the OS sentence for the HUD) and by the
        /// status-0 arm of `errorDescription` above. Declared once so the
        /// producer (`wrapURLError`) and the two consumers cannot drift.
        ///
        /// Note that `parse` returns the code and the sentence *together*,
        /// deliberately: a code-only accessor was deleted in U2 because a
        /// caller taking the code and rendering the whole body is exactly
        /// how `URLError code=…` reached a user's screen (R17).
        static let urlErrorBodyPrefix = "URLError code="

        /// The single place a `URLError` becomes a `GeminiError`.
        ///
        /// Status 0 is the project's "this never reached Gemini" marker:
        /// `RecordingSession.isTerminal` calls it recoverable,
        /// `RecordingSession.shouldRetain` retains its audio, and
        /// `AppState.payloadForSessionFailure` peels the code back out of
        /// the body for the offline / timed-out HUDs. Both producers — the
        /// real `URLSession` failure in `performOnce` and the pre-flight
        /// short-circuit in `sendRequest` — go through here so a
        /// short-circuited request is byte-for-byte indistinguishable
        /// downstream from the timed-out request it replaces.
        ///
        /// The body's second half is the OS's own sentence for the code.
        /// That is not incidental: `AppState`'s HUD builder passes *it*,
        /// never the whole body, so the two network paths render the same
        /// copy and no `URLError code=…` diagnostic reaches a user.
        static func wrapURLError(_ urlError: URLError) -> GeminiError {
            .http(
                status: 0,
                body: "\(urlErrorBodyPrefix)\(urlError.code.rawValue): \(urlError.localizedDescription)"
            )
        }

        /// The error thrown when the pre-flight reachability check reports
        /// no network path. Shaped exactly like the `URLError`
        /// `URLSession` would have produced one inactivity budget later
        /// (`requestInactivityBudget(audioPartCount:)`), so every
        /// downstream classifier — `isTerminal`, `shouldRetain`, the
        /// retention path, `payloadForURLErrorCode` — behaves identically.
        /// Introducing a distinct error case here instead would require
        /// updating `isTerminal` / `shouldRetain` in lockstep, which the
        /// retry plan names as a stop condition.
        static var offlineShortCircuit: GeminiError {
            wrapURLError(URLError(.notConnectedToInternet))
        }

        /// `true` when Google's response body indicates the caller's
        /// country is on Gemini's unsupported-region list (Russia,
        /// Belarus, …). The block is independent of key validity —
        /// a valid paid key in a blocked region still gets HTTP 400
        /// + `FAILED_PRECONDITION` + this exact `error.message`.
        /// All three consumers (`errorDescription`,
        /// `OnboardingAPIKeyStep.continueTapped`,
        /// `AppState.payloadForSessionFailure`) call this so a
        /// Google rewording is a one-line fix.
        static func isRegionBlocked(body: String) -> Bool {
            body.contains("User location is not supported")
        }

        /// Extracts Google's `error.message` from the JSON body and
        /// masks API-key-shaped substrings before returning it.
        /// Returns `nil` when the body is not JSON, has no
        /// `error.message`, or the message is empty after trimming.
        ///
        /// **Security contract (revised from plan §548 / §571):**
        /// the raw body must not be surfaced verbatim, but the
        /// sanitized `error.message` may be — it's typically the
        /// most actionable piece of info Google gives the user
        /// ("API key not valid", "Generative Language API has not
        /// been used in project …", "Quota exceeded for …").
        /// The redactor masks the AIzaSy-prefixed 39-char key
        /// pattern so a partial key echo (Google sometimes includes
        /// one in invalid-key responses) never reaches the UI.
        /// Add new redaction patterns here when a new leak shape
        /// is observed in the wild; do NOT surface body bytes that
        /// haven't been through this filter.
        static func sanitizedGoogleMessage(body: String) -> String? {
            guard let data = body.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let errorObj = root["error"] as? [String: Any],
                  let raw = errorObj["message"] as? String else {
                return nil
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return redactSecrets(in: trimmed)
        }

        /// Pattern + literal for AIzaSy-prefixed Google API keys
        /// (39 chars total: 6-char prefix + 33-char body). Compiled
        /// once at type init — force-unwrap is the documented
        /// project exception for compile-time-known regex literals.
        private static let apiKeyRedactor = try! NSRegularExpression(
            pattern: #"AIzaSy[A-Za-z0-9_-]{33}"#
        )

        private static func redactSecrets(in s: String) -> String {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            return Self.apiKeyRedactor.stringByReplacingMatches(
                in: s,
                range: range,
                withTemplate: "AIzaSy••••••••"
            )
        }

        /// Renders the user-facing copy for the generic `.http(_,_)`
        /// arm — region-block hint when the body matches, sanitized
        /// `error.message` from Google when present, generic
        /// fallback otherwise. The three consumers should all reach
        /// this through `errorDescription` (Settings path),
        /// `descriptionForGenericHTTP(status:body:trailing:)` (UI
        /// callers wanting to append " Try again." etc.), or via
        /// `sanitizedGoogleMessage(body:)` directly when assembling
        /// a richer `ErrorPayload`.
        static func descriptionForGenericHTTP(status: Int, body: String, trailing: String = "") -> String {
            if isRegionBlocked(body: body) {
                return "Gemini isn't available in your region. Try connecting through a VPN.\(trailing.isEmpty ? "" : " \(trailing)")"
            }
            if let msg = sanitizedGoogleMessage(body: body) {
                return "Gemini error \(status): \(msg).\(trailing.isEmpty ? "" : " \(trailing)")"
            }
            return "Gemini error \(status).\(trailing.isEmpty ? "" : " \(trailing)")"
        }
    }

    private let session: URLSession

    /// Most recent successful response's `UsageMetadata`. Read-only
    /// from outside the actor. **Test-only convenience** — production
    /// code doesn't consume this; the prompt-eval harness reads it
    /// after each `transcribe*` call to record per-fixture token
    /// deltas during the U2 audit (see
    /// `docs/plans/2026-05-17-001-refactor-gemini-prompt-audit-and-trim-plan.md`).
    ///
    /// Single-call-at-a-time semantics by construction — the
    /// serial-actor invariant (I1) means at most one in-flight
    /// request per session. Cross-test contamination is also a
    /// non-issue because each test instantiates a fresh
    /// `GeminiClient` in `setUp()`.
    ///
    /// `nil` until the first successful call; reset on each
    /// successful response. Untouched on errors (so the value
    /// from the last good call survives a subsequent failure).
    private(set) var lastUsage: GeminiAPI.UsageMetadata?

    /// Pre-flight "is there a network path at all?" probe, created on the
    /// first request and never before.
    ///
    /// **Deliberately not built in `init()`.** `GeminiClient` is one of the
    /// types `NoTypeApp.init()` constructs, which runs before
    /// `NSApplicationMain` has started the application; starting an
    /// `NWPathMonitor` there would schedule background delivery inside that
    /// window. See `NoType/UI/CLAUDE.md` "Launch ordering". Being reached
    /// only from `sendRequest` also keeps it invisible to
    /// `LaunchPathScanner`, which walks initializers and the methods
    /// reachable from them — the guard and the placement agree rather than
    /// the placement merely evading the guard.
    private var reachability: NetworkReachability?

    private func reachabilityProbe() -> NetworkReachability {
        if let existing = reachability { return existing }
        let probe = NetworkReachability()
        reachability = probe
        return probe
    }

    // MARK: - Request budgets
    //
    // Both `URLSession` timers are sized from **the number of audio parts in
    // the request**. That axis is a measured finding, not a guess — see
    // `requestInactivityBudget(audioPartCount:)`.

    /// Fixed term of the latency model, before the safety factor: the part of
    /// a request's wall-clock that does not scale with the audio it carries
    /// (TLS resumption, the byte-stable cache prefix, response assembly).
    /// Fitted at ~1.4 s; carried at 2 s after the factor. See
    /// `requestInactivityBudget(audioPartCount:)` for the derivation.
    nonisolated static let requestBudgetFixedOverhead: TimeInterval = 2

    /// Per-audio-part term of the latency model, after the safety factor.
    /// Fitted at ~6.5 s per part; carried at 10 s.
    nonisolated static let requestBudgetPerAudioPart: TimeInterval = 10

    /// Shortest silence this client is willing to call a stall.
    ///
    /// Guards the *slope*, not the part count: the measured healthy maximum
    /// for a single part was 7.8 s, so a budget below ten seconds would start
    /// re-issuing against ordinary API latency rather than a dead transport,
    /// and the retry would be pure cost. It binds today only for a request
    /// carrying no audio at all (`audioPartCount <= 0`) — a shape
    /// `sendRequest` cannot produce, but which a future refactor could, and
    /// which must not compute a two-second budget from the fixed term alone.
    nonisolated static let requestBudgetFloor: TimeInterval = 10

    /// Hard cap on the derived budget, whatever the part count.
    ///
    /// Bounds a *pathological* batch rather than serving a legitimate one.
    /// The chunker's own limits make a batch beyond ~8 parts a defect rather
    /// than a session (chunks pile up behind one in-flight request, and the
    /// adaptive pause ladder cuts long enough that a handful is the realistic
    /// maximum), and 90 s still serves 8 parts at the full safety factor.
    /// Past that the choice is between an unbounded freeze — the hotkey is
    /// dead for the whole wait — and a bounded failure that keeps its audio
    /// and offers a retry. The bounded failure is recoverable; the freeze is
    /// not.
    nonisolated static let requestBudgetCeiling: TimeInterval = 90

    /// How long a request may go **without a byte moving** before
    /// `URLSession` fails it, as a function of how many audio parts it
    /// carries. Applied per request via `URLRequest.timeoutInterval`.
    ///
    /// ## What the measurement said
    ///
    /// Four repetitions of each of the two shapes the 2026-08-11 field sample
    /// lacked, against the live API with the real request shape and real AAC
    /// encoding (2026-08-13, one machine, one network):
    ///
    /// | shape                  | audio | bytes  | max idle | max total |
    /// |------------------------|-------|--------|----------|-----------|
    /// | 4-part batch           | 159 s | 653 KB | 26.85 s  | 27.16 s   |
    /// | 1-part 180 s force-cut | 180 s | 735 KB |  7.62 s  |  7.81 s   |
    ///
    /// **Latency tracks the number of audio parts — not the byte size and not
    /// the audio duration.** The 4-part batch carries *less* audio and *fewer*
    /// bytes than the single-part force-cut and takes roughly four times as
    /// long. That finding is the whole reason this is a function rather than
    /// a constant: per part the two shapes agree (5.1–7.6 s), so one number
    /// that clears the batch would leave the common single-part request
    /// waiting nearly four times longer than it can possibly need.
    ///
    /// **KTD2's stop condition fired, and the flat cut R20 asked for is
    /// dead.** 26.85 s sits against the retired 30 s ceiling, so no single
    /// value both helps the common case and spares a large batch.
    ///
    /// ## The arithmetic
    ///
    /// Fitting a line through the two measured maxima gives ~1.4 s fixed plus
    /// ~6.5 s per part. Multiplying both terms by a safety factor of **1.5**
    /// and rounding up gives `requestBudgetFixedOverhead` = 2 s and
    /// `requestBudgetPerAudioPart` = 10 s, which clears each measured maximum
    /// by a near-uniform **~1.55×**:
    ///
    /// | parts | budget | measured max | factor |
    /// |-------|--------|--------------|--------|
    /// | 1     | 12 s   | 7.81 s       | 1.54×  |
    /// | 4     | 42 s   | 27.16 s      | 1.55×  |
    ///
    /// The factor is deliberately generous rather than tight. The sample is
    /// four runs per shape on one machine and one network — it is a sample,
    /// not a distribution — and the cost of being wrong is asymmetric: too
    /// generous and the user waits, too tight and a legitimate request is
    /// killed, which becomes a `[…]` in text **already pasted into the user's
    /// document**, where no retry can reach it.
    ///
    /// What the user actually pays in the common case: a single-part request
    /// that stalls costs `2 × 12 s` plus the 500 ms backoff — 24.5 s against
    /// the ~60.5 s the retired ceiling cost, so R22's "the hotkey comes back
    /// in well under half the time" holds for the single-part case. It does
    /// **not** hold for a large batch, and that is the honest reading of AE11
    /// now: a 4-part batch that stalls costs 2 × 42 s. The compensation is
    /// that a batch is rarer than a single chunk and that the alternative for
    /// it is not a shorter wait but a lost chunk.
    ///
    /// ## Why the inactivity timer is the right control (KTD2 step 2)
    ///
    /// The response is not streamed, so the entire window from the last
    /// uploaded byte to the first response byte is idle. Upload measured
    /// 0.06–0.31 s in **every** row — under 1.5 % of the total — so
    /// essentially all of the wait *is* the inactivity window. This timer is
    /// therefore a direct cap on how long a chunk may take, not merely a
    /// stall detector, and the whole-transfer ceiling can only bind on a
    /// trickling upload. See `resourceCeiling`.
    ///
    /// Hoisted out of `init` so a test can reach it at all (KTD3);
    /// `GeminiRetryPolicyTests` pins the values, the clamps and the safety
    /// factor against the measured maxima, and
    /// `GeminiClientOfflineShortCircuitTests` pins that every request in this
    /// file sets a budget of its own.
    nonisolated static func requestInactivityBudget(audioPartCount: Int) -> TimeInterval {
        let derived = requestBudgetFixedOverhead
            + requestBudgetPerAudioPart * TimeInterval(max(0, audioPartCount))
        return min(requestBudgetCeiling, max(requestBudgetFloor, derived))
    }

    /// Inactivity budget for the requests that carry no audio and therefore
    /// sit off the axis above: `classifyApp`, which sets it explicitly, and
    /// — as the session-configuration default — anything that neglects to.
    /// `validateKey` narrows further to 10 s of its own.
    ///
    /// Held at the value the whole client used before the derivation landed,
    /// on purpose: the classifier is a grounded (`google_search`) call whose
    /// latency was never measured here, and shortening it would be collateral
    /// damage from a cut aimed at transcription. It is a ceiling on a
    /// fire-and-forget background call, not on anything the user waits for.
    nonisolated static let auxiliaryRequestBudget: TimeInterval = 30

    /// Headroom the whole-transfer ceiling leaves above the inactivity budget
    /// for the upload itself.
    ///
    /// The measurement uploaded 653–735 KB in 0.06–0.31 s. Thirty seconds
    /// covers roughly a hundredfold slower uplink (~200 kbit/s); below that a
    /// dictation is not going to work at all. Generous on purpose — this
    /// margin exists so the resource timer can never be the one that kills a
    /// request the inactivity timer would have allowed.
    nonisolated static let uploadAllowance: TimeInterval = 30

    /// Whole-transfer ceiling (`timeoutIntervalForResource`): the hard cap on
    /// a single request from first byte to last, across any number of idle
    /// periods.
    ///
    /// **An additional ceiling, never a fallback** (KTD1). The two timers are
    /// independent and whichever fires first wins, so this one cannot rescue
    /// a request the inactivity budget has already killed — it only bounds
    /// the case where bytes keep trickling and the inactivity timer keeps
    /// resetting.
    ///
    /// **It moved, and KTD1's "leave it at 30 s" no longer holds.** The
    /// measured max *total* for a 4-part batch is 27.16 s against a 30 s
    /// ceiling, so a 5-part batch was already exceeding it — killing a
    /// legitimate request and producing a silent `[…]`. That was a live
    /// shipped defect, not a future risk.
    ///
    /// **Flat rather than per-request, because the platform has no
    /// per-request knob.** `URLRequest.timeoutInterval` overrides
    /// `timeoutIntervalForRequest` in both directions (measured), but there
    /// is no `URLRequest` counterpart for the resource timer: with
    /// `timeoutIntervalForResource = 3` and `URLRequest.timeoutInterval = 30`
    /// against a stalling socket, the task failed at 3.27 s — session-level
    /// and not overridable. So this is sized for the largest request the
    /// budget function will ever serve (`requestBudgetCeiling`) plus the
    /// upload allowance, which is the same axis evaluated at its maximum.
    /// The cost of that flatness is borne only by a request whose *upload*
    /// trickles for minutes, and the safe direction there is to let it
    /// finish.
    nonisolated static let resourceCeiling: TimeInterval = requestBudgetCeiling + uploadAllowance

    /// The session configuration, built in one testable place so the budgets
    /// above are provably the ones that ship. Splitting this out of `init` is
    /// the other half of KTD3: a constant nothing can read is a constant no
    /// test can pin, and a test that pins the constant but not its wiring
    /// stays green when the wiring is what breaks.
    ///
    /// Note what `timeoutIntervalForRequest` means here now: it is only the
    /// **default** for a request that sets no `timeoutInterval` of its own.
    /// Every request this file builds sets one — pinned by
    /// `GeminiClientOfflineShortCircuitTests` — so the value below is a
    /// backstop for a future path that forgets, and it is deliberately the
    /// auxiliary budget rather than a transcription one.
    nonisolated static func makeSessionConfiguration() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = auxiliaryRequestBudget
        cfg.timeoutIntervalForResource = resourceCeiling
        // Off on purpose: `URLSession` must fail an offline request rather
        // than park on it indefinitely. `sendRequest`'s reachability
        // pre-check is what turns that failure into a fast one.
        cfg.waitsForConnectivity = false
        return cfg
    }

    init() {
        self.session = URLSession(configuration: Self.makeSessionConfiguration())
    }

    /// Output of `classifyApp(...)`. The classifier may return any of
    /// `AppCategory.classifierCases` plus `.uncategorized` as an
    /// honest "I don't know" answer. `confidence == .low` is the
    /// signal not to cache — `AppCategorizer` re-tries on the next
    /// session.
    struct AppCategoryClassification: Sendable, Equatable {
        let category: AppCategory
        let confidence: AppCategoryAssignment.Confidence
    }

    /// One-shot app-classifier call. Sends `display_name` + `bundle_id`
    /// to Gemini with the `google_search` tool enabled so the model can
    /// look up unfamiliar bundles. Returns the parsed category +
    /// confidence; `AppCategorizer` decides what to persist.
    ///
    /// Independent of transcription state: no audio, no `ContextSnapshot`,
    /// no implicit-cache prefix to preserve. Different prompt, different
    /// generation config, different `tools`. Unlike the `transcribe*`
    /// methods, this call does **not** go through the shared `sendRequest`
    /// retry loop (`retryDecision`) — it issues a single
    /// `URLSession.data(for:)` request and throws on any non-200 or
    /// network error. Retry resilience lives one layer up: `AppCategorizer`
    /// logs the failure and re-classifies on the next session.
    func classifyApp(
        displayName: String,
        bundleID: String,
        apiKey: String
    ) async throws -> AppCategoryClassification {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw GeminiError.missingKey }
        guard !bundleID.isEmpty else {
            throw GeminiError.http(status: 400, body: "empty bundle id")
        }

        // Minimal user input. Window title is intentionally omitted in
        // v1 — it can leak PII (e.g. a draft subject line) and we'd need
        // to run it through `SecureFieldMasker.scrubContent` first.
        let userInput =
            "display_name: \"\(escape(displayName))\"\n" +
            "bundle_id: \"\(escape(bundleID))\""

        let body = GeminiAPI.Request(
            contents: [GeminiAPI.Content(role: "user", parts: [.text(userInput)])],
            generationConfig: GeminiAPI.GenerationConfig(
                topP: 0.0,
                responseMimeType: "application/json",
                thinkingConfig: GeminiAPI.ThinkingConfig(thinkingLevel: "MINIMAL")
            ),
            systemInstruction: GeminiAPI.Content(
                role: nil,
                parts: [.text(Self.categorizerPrompt)]
            ),
            tools: [GeminiAPI.Tool(googleSearch: GeminiAPI.GoogleSearchTool())]
        )

        // Classifier always runs on Flash-Lite — it's a cheap background
        // categorization call where the larger model wouldn't move the
        // needle, and keeping it fixed means the user's transcription
        // model choice doesn't change classifier cost.
        var req = URLRequest(url: Self.generateContentURL(for: .flashLite))
        req.httpMethod = "POST"
        // Explicit rather than inherited from the session configuration: the
        // transcription paths derive their budget from the audio-part count,
        // and a request that silently took whatever default was left over
        // would be a budget nobody chose. This one carries no audio, so it
        // sits off that axis — see `auxiliaryRequestBudget`.
        req.timeoutInterval = Self.auxiliaryRequestBudget
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONEncoder().encode(body)

        Self.log.info("classify POST bundle=\(bundleID, privacy: .public) name=\(displayName, privacy: .public)")
        let networkStart = Date()
        let (data, response) = try await session.data(for: req)
        let networkMs = Int(Date().timeIntervalSince(networkStart) * 1000)

        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.http(status: 0, body: "no HTTPURLResponse")
        }
        if http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            Self.log.error("classify HTTP \(http.statusCode) (bundle=\(bundleID, privacy: .public)): \(bodyStr, privacy: .private)")
            throw GeminiError.http(status: http.statusCode, body: bodyStr)
        }

        let parsed: GeminiAPI.Response
        do {
            parsed = try JSONDecoder().decode(GeminiAPI.Response.self, from: data)
        } catch {
            throw GeminiError.decoding(error)
        }
        if let block = parsed.promptFeedback?.blockReason, !block.isEmpty {
            throw GeminiError.blocked(block)
        }

        let raw = parsed
            .candidates?
            .first?
            .content?
            .parts?
            .compactMap { $0.text }
            .joined() ?? ""
        let result = try Self.parseClassifierResponse(raw)
        Self.log.info(
            "classify OK bundle=\(bundleID, privacy: .public) → \(result.category.rawValue, privacy: .public) (\(result.confidence.rawValue, privacy: .public)) network=\(networkMs)ms"
        )
        return result
    }

    /// Parses the model's JSON output into a strongly-typed
    /// classification. Exposed (internal) so unit tests can drive the
    /// parser without hitting the network. Unknown / missing values
    /// collapse to `.uncategorized` + `.low` so the caller treats a
    /// confused response the same as a low-confidence one (no cache).
    static func parseClassifierResponse(_ raw: String) throws -> AppCategoryClassification {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The model sometimes wraps JSON in a fenced code block despite
        // `responseMimeType=application/json`. Strip a leading ```json
        // / trailing ``` if present.
        let unwrapped: String = {
            var s = trimmed
            if s.hasPrefix("```") {
                if let nl = s.firstIndex(of: "\n") {
                    s = String(s[s.index(after: nl)...])
                }
                if s.hasSuffix("```") {
                    s = String(s.dropLast(3))
                }
            }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        guard let data = unwrapped.data(using: .utf8) else {
            throw GeminiError.decoding(NSError(domain: "Classifier", code: 0))
        }
        struct Raw: Decodable {
            let category: String?
            let confidence: String?
        }
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            throw GeminiError.decoding(error)
        }
        let category = AppCategory.parseClassifierResponse(raw.category ?? "")
        let confidence = AppCategoryAssignment.Confidence(rawClassifierValue: raw.confidence ?? "") ?? .low
        return AppCategoryClassification(category: category, confidence: confidence)
    }

    /// Maps a candidate's `finishReason` to a `GeminiError`, or `nil` to
    /// keep the returned text. A clean transcription ends with `STOP`;
    /// anything else is worth a log at the call site. Two classes get
    /// mapped to errors:
    ///
    /// - **Content blocks** (`SAFETY` / `RECITATION` / `PROHIBITED_CONTENT`
    ///   / `BLOCKLIST` / `SPII` / `IMAGE_SAFETY`) → `.blocked` — same
    ///   terminal treatment as a prompt-level `promptFeedback.blockReason`,
    ///   surfacing the reason to the user rather than silently pasting the
    ///   empty/partial candidate.
    /// - **`MAX_TOKENS`** → `.truncated` — the text is a silently-cut
    ///   partial; recoverable so it becomes a `[…]` gap marker instead of
    ///   looking like a complete sentence.
    ///
    /// Unknown / future reasons (`OTHER`, `LANGUAGE`, unspecified, …) return
    /// `nil`: we don't reject a usable transcript over a reason we don't
    /// recognise — the caller just logs it. Pinned by
    /// `GeminiFinishReasonTests`.
    static func finishReasonError(_ finishReason: String?) -> GeminiError? {
        guard let reason = finishReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else {
            return nil
        }
        switch reason.uppercased() {
        case "STOP":
            return nil
        case "MAX_TOKENS":
            return .truncated
        case "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "IMAGE_SAFETY":
            return .blocked(reason)
        default:
            return nil
        }
    }

    /// Escape display name / bundle id for embedding inside a quoted
    /// JSON-ish input line. Same conservative rules as the insertion
    /// target escape — backslashes, inner quotes, newlines, tabs.
    private func escape(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    /// Free-of-charge "does this key work?" check. Hits the public
    /// `models` listing endpoint, which 200s for any valid key and 401/403
    /// for a bad one — no transcription tokens are spent. Used by the
    /// onboarding manual-setup screen before we save the key.
    ///
    /// Intentionally separate from `transcribe` / `transcribeBatch`: it
    /// has no audio, no context, no implicit-cache prefix to worry about.
    /// Bad-key paths throw `GeminiError.http(401, …)` / `.http(403, …)`.
    func validateKey(_ apiKey: String) async throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GeminiError.missingKey }

        var req = URLRequest(url: Self.modelsListURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue(trimmed, forHTTPHeaderField: "x-goog-api-key")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.http(status: 0, body: "no HTTPURLResponse")
        }
        if http.statusCode == 200 { return }
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        throw GeminiError.http(status: http.statusCode, body: bodyStr)
    }

    /// Transcribe a single chunk of a session.
    ///
    /// - `priorTranscripts`: text of all previously-finalized chunks of
    ///   *this* session, in order. Joined into the cached-prefix part. For
    ///   chunk_1 pass `[]`.
    /// - `chunkIndex`: 1-based — used in the per-request instruction text
    ///   so the model can refer to "chunk_3" naturally.
    /// - `isFinal`: true on the last chunk of a session (release fired).
    ///   Switches the instruction so the model applies final punctuation.
    func transcribe(
        audio: Data,
        mimeType: String,
        context: ContextSnapshot,
        priorTranscripts: [String],
        chunkIndex: Int,
        isFinal: Bool,
        apiKey: String,
        model: GeminiModel
    ) async throws -> String {
        try await transcribeWithUsage(
            audio: audio,
            mimeType: mimeType,
            context: context,
            priorTranscripts: priorTranscripts,
            chunkIndex: chunkIndex,
            isFinal: isFinal,
            apiKey: apiKey,
            model: model
        ).text
    }

    /// Token-aware variant of `transcribe`. Returns the transcript
    /// AND the `TokenUsage` Gemini billed for this single response.
    /// Added in U5 (plan 2026-05-18-001 §473) — production path
    /// (`RecordingSession`) switches to the `*WithUsage` overloads
    /// so session-level token aggregation is honest. Existing
    /// `transcribe(...)` stays as a backwards-compat shim
    /// (PromptEvalHarness reads `lastUsage` directly post-call,
    /// untouched). Path (a) per plan recommendation — smaller blast
    /// radius than renaming the existing return types.
    func transcribeWithUsage(
        audio: Data,
        mimeType: String,
        context: ContextSnapshot,
        priorTranscripts: [String],
        chunkIndex: Int,
        isFinal: Bool,
        apiKey: String,
        model: GeminiModel
    ) async throws -> (text: String, tokens: TokenUsage) {
        let instruction = isFinal
            ? Self.finalChunkInstruction(chunkIndex: chunkIndex)
            : Self.midChunkInstruction(chunkIndex: chunkIndex)
        return try await sendRequest(
            audios: [(audio, mimeType)],
            context: context,
            priorTranscripts: priorTranscripts,
            instruction: instruction,
            logID: "chunk_\(chunkIndex)",
            mayBeEmpty: isFinal,
            apiKey: apiKey,
            model: model
        )
    }

    /// Short-session lite path. Triggered by `RecordingSession` only when
    /// the discriminator `shouldUseLitePath` fires — a final-only batch of
    /// a single short chunk with no prior chunks. Differs from `transcribe`
    /// in three ways:
    ///
    /// 1. Uses `Self.systemPromptLite` (the trimmed ~600-word system
    ///    instruction) instead of the full `Self.systemPrompt`.
    /// 2. Drops the `On-screen context:` and `Prior chunks (this session):`
    ///    user-message parts entirely (no empty placeholders either) —
    ///    different prefix shape from the full path on purpose. There is
    ///    no implicit cross-cache between lite and full requests; that's
    ///    acceptable because lite sessions are single-chunk by definition.
    /// 3. Uses `Self.liteChunkInstruction()` (single-utterance variant —
    ///    no chunk index, no batched / mid-chunk forks).
    ///
    /// See ADR / `merry-percolating-hare.md` plan + `NoType/Gemini/CLAUDE.md`
    /// "Short-session lite path" subsection.
    func transcribeShort(
        audio: Data,
        mimeType: String,
        context: ContextSnapshot,
        apiKey: String,
        model: GeminiModel
    ) async throws -> String {
        try await transcribeShortWithUsage(
            audio: audio,
            mimeType: mimeType,
            context: context,
            apiKey: apiKey,
            model: model
        ).text
    }

    /// Token-aware variant of `transcribeShort`. See
    /// `transcribeWithUsage` for the path-(a) rationale.
    func transcribeShortWithUsage(
        audio: Data,
        mimeType: String,
        context: ContextSnapshot,
        apiKey: String,
        model: GeminiModel
    ) async throws -> (text: String, tokens: TokenUsage) {
        let instruction = Self.liteChunkInstruction()
        return try await sendRequest(
            audios: [(audio, mimeType)],
            context: context,
            priorTranscripts: [],
            instruction: instruction,
            logID: "short_single",
            mayBeEmpty: true,
            apiKey: apiKey,
            model: model,
            useLitePrompt: true
        )
    }

    /// Transcribe a batch of consecutive chunks in a single round-trip.
    ///
    /// Used when chunks pile up behind an in-flight request (typically at
    /// release: the in-flight non-final chunk is followed by one or more
    /// queued chunks plus the final one). The model sees N audio parts in
    /// order and returns one contiguous transcript covering all of them.
    /// Each `inline_data` part is matched to its `chunkIndices[i]` for
    /// logging / future structured-output upgrades.
    ///
    /// Cache prefix is identical to the single-chunk path — the only
    /// difference is the per-batch instruction line and N audios instead
    /// of 1. So implicit caching still hits everything before the
    /// instruction.
    func transcribeBatch(
        audios: [(data: Data, mimeType: String)],
        context: ContextSnapshot,
        priorTranscripts: [String],
        chunkIndices: [Int],
        isFinal: Bool,
        apiKey: String,
        model: GeminiModel
    ) async throws -> String {
        try await transcribeBatchWithUsage(
            audios: audios,
            context: context,
            priorTranscripts: priorTranscripts,
            chunkIndices: chunkIndices,
            isFinal: isFinal,
            apiKey: apiKey,
            model: model
        ).text
    }

    /// Token-aware variant of `transcribeBatch`. Returns the
    /// transcript covering every chunk in the batch AND the single
    /// per-request `TokenUsage` Gemini billed. Tokens are **not**
    /// divided across chunks — Gemini's billing model is
    /// per-response, and synthesising a per-chunk split would be a
    /// guess (see `TokenUsage` doc-comment). The caller (a
    /// `RecordingSession` sender) records one `TokenUsage` per
    /// Gemini call and sums at session end.
    func transcribeBatchWithUsage(
        audios: [(data: Data, mimeType: String)],
        context: ContextSnapshot,
        priorTranscripts: [String],
        chunkIndices: [Int],
        isFinal: Bool,
        apiKey: String,
        model: GeminiModel
    ) async throws -> (text: String, tokens: TokenUsage) {
        precondition(audios.count == chunkIndices.count, "audios / indices mismatch")
        precondition(audios.count > 1, "use transcribe(audio:...) for single chunks")
        let instruction = Self.batchedChunkInstruction(indices: chunkIndices, isFinal: isFinal)
        // `chunkIndices.count > 1` per precondition above — the `?? -1`
        // fallbacks exist purely so the log line can't crash on a future
        // refactor that loosens that contract.
        let logID = "chunks_\(chunkIndices.first ?? -1)..\(chunkIndices.last ?? -1)"
        return try await sendRequest(
            audios: audios,
            context: context,
            priorTranscripts: priorTranscripts,
            instruction: instruction,
            logID: logID,
            mayBeEmpty: isFinal,
            apiKey: apiKey,
            model: model
        )
    }

    /// Pure: assemble the request body for either a single chunk or a
    /// batched call. Exposed (internal) so `GeminiRequestBuilderTests`
    /// can pin the cached-prefix shape — up to 9 textual sections in this
    /// exact order with these exact labels, then N audio inline_data
    /// parts. Two sections are conditionally omitted:
    /// - `User instruction:` — omitted iff `context.userInstruction` is
    ///   empty.
    /// - `Category instruction:` — omitted iff `context.categoryInstruction`
    ///   is `nil` (typical for `.uncategorized`).
    /// Both decisions are stable for the lifetime of a session, so the
    /// part count is byte-stable across that session's chunks.
    static func buildRequestBody(
        audios: [(data: Data, mimeType: String)],
        context: ContextSnapshot,
        priorTranscripts: [String],
        instruction: String
    ) -> GeminiAPI.Request {
        let appLine =
            "App: \(context.activeApp.name) (\(context.activeApp.bundleID))\n" +
            "Category: \(context.category.rawValue)"
        let insertionText = formatInsertionTarget(context.insertionTarget)
        // `On-screen context:` part may carry two sub-blocks: the AX tree
        // (always present, possibly empty) and an optional OCR fallback
        // (only when AX returned nothing useful for the active app's
        // bundle id AND the user granted Screen Recording). Keeping them
        // inside the same prompt part preserves the cached-prefix shape
        // — adding a new top-level section would change the prefix and
        // break implicit caching contracts pinned by
        // `GeminiRequestBuilderTests`.
        var screenText = "On-screen context:\n" + context.tree.formattedForPrompt()
        if let ocr = context.screenText {
            screenText += ocr.formattedForPrompt()
        }
        let priorsText = formatPriorTranscripts(priorTranscripts)

        // ─── Cached prefix ─────────────────────────────────────────────
        // Order matters; the system instruction references these labels
        // by exact name and `GeminiRequestBuilderTests` pins the contract.
        // The two `*_instruction` sections are conditionally omitted —
        // see the doc-comment above — but every other section is always
        // present, with `(none yet)` / `(empty)` / empty-quoted bodies
        // when empty.
        let languagesText = formatUserLanguages(context.userLanguages)
        let dictionaryText = formatUserDictionary(context.dictionary)
        var parts: [GeminiAPI.Part] = [.text(appLine)]
        if !context.userInstruction.isEmpty {
            parts.append(.text("User instruction:\n\(context.userInstruction)"))
        }
        if let categoryInstruction = context.categoryInstruction,
           !categoryInstruction.isEmpty {
            parts.append(.text("Category instruction:\n\(categoryInstruction)"))
        }
        parts.append(.text(languagesText))
        parts.append(.text(dictionaryText))
        parts.append(.text(insertionText))
        parts.append(.text(screenText))
        parts.append(.text(priorsText))
        parts.append(.text(instruction))
        for (audio, mime) in audios {
            parts.append(.inlineData(mimeType: mime, data: audio.base64EncodedString()))
        }

        return GeminiAPI.Request(
            contents: [GeminiAPI.Content(role: "user", parts: parts)],
            generationConfig: GeminiAPI.GenerationConfig(
                topP: 0.2,
                responseMimeType: "text/plain",
                // ADR-003: transcription is not a reasoning task — minimal
                // thinking shaves significant time off each request.
                thinkingConfig: GeminiAPI.ThinkingConfig(thinkingLevel: "MINIMAL")
            ),
            systemInstruction: GeminiAPI.Content(role: nil, parts: [
                .text(systemPrompt)
            ])
        )
    }

    /// Pure: assemble the **lite** request body for the short-session
    /// path. Differs from `buildRequestBody` by:
    /// - Dropping the `On-screen context:` part (no AX tree, no OCR).
    /// - Dropping the `Prior chunks (this session):` part (lite path
    ///   triggers only when `priorTranscripts.isEmpty`, so the section
    ///   would always render `(none yet)` — better to omit entirely and
    ///   match the trimmed system prompt).
    /// - Using `systemPromptLite` for the `system_instruction`.
    ///
    /// Resulting part order: App+Category → optional User instruction →
    /// optional Category instruction → User languages → User dictionary
    /// → Insertion target → per-call instruction → audio. Pinned by
    /// `GeminiRequestBuilderTests.test_litePrompt_*`.
    static func buildLiteRequestBody(
        audio: Data,
        mimeType: String,
        context: ContextSnapshot,
        instruction: String
    ) -> GeminiAPI.Request {
        let appLine =
            "App: \(context.activeApp.name) (\(context.activeApp.bundleID))\n" +
            "Category: \(context.category.rawValue)"
        let insertionText = formatInsertionTarget(context.insertionTarget)
        let languagesText = formatUserLanguages(context.userLanguages)
        let dictionaryText = formatUserDictionary(context.dictionary)

        var parts: [GeminiAPI.Part] = [.text(appLine)]
        if !context.userInstruction.isEmpty {
            parts.append(.text("User instruction:\n\(context.userInstruction)"))
        }
        if let categoryInstruction = context.categoryInstruction,
           !categoryInstruction.isEmpty {
            parts.append(.text("Category instruction:\n\(categoryInstruction)"))
        }
        parts.append(.text(languagesText))
        parts.append(.text(dictionaryText))
        parts.append(.text(insertionText))
        parts.append(.text(instruction))
        parts.append(.inlineData(mimeType: mimeType, data: audio.base64EncodedString()))

        return GeminiAPI.Request(
            contents: [GeminiAPI.Content(role: "user", parts: parts)],
            generationConfig: GeminiAPI.GenerationConfig(
                topP: 0.2,
                responseMimeType: "text/plain",
                thinkingConfig: GeminiAPI.ThinkingConfig(thinkingLevel: "MINIMAL")
            ),
            systemInstruction: GeminiAPI.Content(role: nil, parts: [
                .text(systemPromptLite)
            ])
        )
    }

    /// Internal: assemble the request, send it (with the documented retry
    /// policy), and parse the response. Shared by `transcribe` and
    /// `transcribeBatch` so the prefix shape stays in lockstep between
    /// the two paths.
    ///
    /// Retry policy (see `NoType/Gemini/CLAUDE.md` "Retry policy"):
    /// - URLError (network / timeout): 1 retry after 500 ms.
    /// - HTTP 429 (rate limit): 2 retries with 500 ms then 2 s backoff.
    /// - HTTP 5xx: 1 retry after 500 ms.
    /// - HTTP 4xx other than 429: no retry; fail immediately.
    /// - `GeminiError.blocked` / `.empty` / `.decoding` / `.missingKey`:
    ///   non-retryable.
    /// - A network-class retry additionally **drops the pooled connections**
    ///   before re-issuing (R28 / KTD13) — see `requiresFreshConnection(after:)`
    ///   and `flushPooledConnections()`. The other arms do not.
    ///
    /// Before any of that, a pre-flight reachability check short-circuits
    /// the call when the system reports no network path. **That throw sits
    /// outside the retry loop below on purpose** — it is how a
    /// short-circuited request avoids being re-issued without touching
    /// `retryDecision`, so a genuine status-0 *timeout* (which reaches the
    /// loop the normal way, through `performOnce`) keeps its one retry.
    /// Moving the check into `performOnce` would silently double every
    /// short-circuit; `GeminiClientOfflineShortCircuitTests` pins the
    /// position.
    private func sendRequest(
        audios: [(data: Data, mimeType: String)],
        context: ContextSnapshot,
        priorTranscripts: [String],
        instruction: String,
        logID: String,
        mayBeEmpty: Bool,
        apiKey: String,
        model: GeminiModel,
        useLitePrompt: Bool = false
    ) async throws -> (text: String, tokens: TokenUsage) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw GeminiError.missingKey }

        // Pre-flight: fail immediately when the system reports no network
        // path, instead of parking on this request's whole inactivity budget
        // (`waitsForConnectivity` is off, so `URLSession` does not fail
        // fast on its own). Conservative by construction — only a
        // definitively `.unsatisfied` path short-circuits; see
        // `NetworkReachability`. Deliberately before the request body is
        // built and before the retry loop.
        if await reachabilityProbe().isDefinitelyOffline() {
            let offline = GeminiError.offlineShortCircuit
            Self.log.error("\(logID) no network path — failing without issuing a request: \(offline.localizedDescription, privacy: .public)")
            throw offline
        }

        let body: GeminiAPI.Request
        if useLitePrompt {
            // Lite path is single-audio by construction (see
            // `transcribeShort`). `audios.first!` is safe.
            precondition(audios.count == 1, "lite path requires single audio")
            let one = audios[0]
            body = Self.buildLiteRequestBody(
                audio: one.data,
                mimeType: one.mimeType,
                context: context,
                instruction: instruction
            )
        } else {
            body = Self.buildRequestBody(
                audios: audios,
                context: context,
                priorTranscripts: priorTranscripts,
                instruction: instruction
            )
        }

        var req = URLRequest(url: Self.generateContentURL(for: model))
        req.httpMethod = "POST"
        // The budget is derived here because here is where the axis it
        // depends on — how many audio parts this request carries — is known.
        // Per request rather than on the session configuration: a batch and a
        // single chunk share one `URLSession`, and the measurement says they
        // need very different budgets. Verified that this actually takes
        // effect rather than assumed: `URLRequest.timeoutInterval` overrides
        // `URLSessionConfiguration.timeoutIntervalForRequest` in **both**
        // directions (against a stalling socket, config 3 s / request 9 s
        // failed at 9.01 s, and config 9 s / request 3 s failed at 3.01 s), so
        // a batch genuinely gets more room than the session default and not
        // silently less.
        req.timeoutInterval = Self.requestInactivityBudget(audioPartCount: audios.count)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONEncoder().encode(body)

        let totalAudio = audios.reduce(0) { $0 + $1.data.count }
        let budgetSeconds = Int(req.timeoutInterval)
        Self.log.info("POST \(logID) (final=\(mayBeEmpty), audios=\(audios.count), bytes=\(totalAudio), priors=\(priorTranscripts.count), budget=\(budgetSeconds)s)")

        // Retry-loop driver. `attempt` is 1-based for log readability.
        // The number of *retries* is dictated by the error class on the
        // previous attempt's failure — see `RetryDecision` below.
        var attempt = 1
        while true {
            do {
                return try await performOnce(
                    request: req,
                    logID: logID,
                    attempt: attempt,
                    mayBeEmpty: mayBeEmpty
                )
            } catch let error as GeminiError {
                let decision = Self.retryDecision(for: error, attempt: attempt)
                guard let delayMs = decision.delayMs else {
                    Self.log.error("\(logID) failed (attempt \(attempt), no retry): \(error.localizedDescription, privacy: .public)")
                    throw error
                }
                // R28 / KTD13: a network-class failure is, in the measured
                // case, a dead *pooled connection* rather than a dead
                // network — a request stalled for the full budget and the
                // same payload answered in 1.7 s on a new connection
                // moments later. Re-issuing over the socket that just went
                // silent would re-inherit the fault and turn the retry into
                // nothing but a second wait, so drop the pool first. This
                // is the axis that can make the retry *succeed*, which is
                // what distinguishes it from the longer-wait and
                // longer-ladder alternatives KD7 rejected.
                if Self.requiresFreshConnection(after: error) {
                    Self.log.info("\(logID) network-class failure — dropping pooled connections before retry")
                    await flushPooledConnections()
                }
                Self.log.info("\(logID) retrying after \(delayMs)ms (attempt \(attempt) → \(attempt + 1)): \(error.localizedDescription, privacy: .public)")
                try await Task.sleep(for: .milliseconds(delayMs))
                attempt += 1
            } catch {
                // URLError (or any non-Gemini error) — wrapped as `.http(0, …)`
                // by performOnce, so this branch only fires for cancellation /
                // Task.sleep failures during backoff. Surface as-is.
                throw error
            }
        }
    }

    /// One HTTP round-trip + response parsing. Translates all errors into
    /// `GeminiError`. Network failures become `.http(status: 0, body:)`.
    private func performOnce(
        request: URLRequest,
        logID: String,
        attempt: Int,
        mayBeEmpty: Bool
    ) async throws -> (text: String, tokens: TokenUsage) {
        let networkStart = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            // Cancellation surfaces from URLSession as `URLError(-999)`
            // *not* `CancellationError`. Translate so the session-level
            // retry / partial-recovery layer can classify it as
            // terminal — otherwise `splitRetry` keeps issuing requests
            // against an already-cancelled task. See
            // `RecordingSession.isTerminal(_:)`.
            if urlError.code == .cancelled {
                throw CancellationError()
            }
            // Wrap to give the retry-decider a uniform classifier
            // surface. The URLError code is embedded in the body so
            // `AppState.payloadForSessionFailure` can recover it for
            // the "no internet" / "timed out" HUDs.
            throw GeminiError.wrapURLError(urlError)
        }
        let networkMs = Int(Date().timeIntervalSince(networkStart) * 1000)

        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.http(status: 0, body: "no HTTPURLResponse")
        }

        if http.statusCode != 200 {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
            // Body may contain user-typed key in echo'd error — keep it private.
            Self.log.error("\(logID) HTTP \(http.statusCode) (attempt \(attempt)): \(bodyStr, privacy: .private)")
            throw GeminiError.http(status: http.statusCode, body: bodyStr)
        }

        let parsed: GeminiAPI.Response
        do {
            parsed = try JSONDecoder().decode(GeminiAPI.Response.self, from: data)
        } catch {
            throw GeminiError.decoding(error)
        }

        if let block = parsed.promptFeedback?.blockReason, !block.isEmpty {
            throw GeminiError.blocked(block)
        }

        // Inspect the candidate's finishReason. A clean transcription ends
        // with STOP; a content block (SAFETY/RECITATION/…) surfaces here as
        // a candidate-level reason even when promptFeedback carries none,
        // and MAX_TOKENS means the text is a silently-cut partial. Map both
        // to errors (blocked → terminal, truncated → recoverable `[…]`
        // marker); log any other non-STOP reason but keep the text.
        let finishReason = parsed.candidates?.first?.finishReason
        if let reasonError = Self.finishReasonError(finishReason) {
            Self.log.error("\(logID) non-STOP finishReason=\(finishReason ?? "nil", privacy: .public)")
            throw reasonError
        } else if let reason = finishReason, reason.uppercased() != "STOP" {
            Self.log.notice("\(logID) unhandled finishReason=\(reason, privacy: .public) — keeping text")
        }

        // Capture usage metadata before any further can-throw paths.
        // Production code ignores this; the prompt-eval harness reads
        // `lastUsage` after a successful call. Set on every parsed
        // response (including ones we're about to reject for being
        // empty mid-session) — the test surface still benefits from
        // knowing the model billed us before deciding the output was
        // unusable.
        self.lastUsage = parsed.usageMetadata

        let text = parsed
            .candidates?
            .first?
            .content?
            .parts?
            .compactMap { $0.text }
            .joined() ?? ""

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty text on the final chunk (or a final-containing batch)
        // just means the user said nothing new at the end — fine. Empty
        // mid-session is an error worth reporting.
        if trimmed.isEmpty && !mayBeEmpty {
            throw GeminiError.empty
        }

        // Debug-only: cache hit ratio. >0.7 expected on chunk 2+ once we
        // have a real prefix to cache.
        #if DEBUG
        if let usage = parsed.usageMetadata {
            let total = usage.promptTokenCount ?? 0
            let cached = usage.cachedContentTokenCount ?? 0
            let pct = total > 0 ? Int(Double(cached) / Double(total) * 100) : 0
            Self.log.debug("\(logID) usage: prompt=\(total) cached=\(cached) (\(pct)%) candidates=\(usage.candidatesTokenCount ?? 0)")
        }
        #endif

        Self.log.info("\(logID) length=\(trimmed.count) network=\(networkMs)ms attempt=\(attempt)")
        return (trimmed, TokenUsage(from: parsed.usageMetadata))
    }

    /// One failed attempt's place on the retry ladder. `delayMs == nil`
    /// means "don't retry, propagate".
    ///
    /// Widened past `private` with `retryDecision` below, deliberately
    /// (KTD3) — the ladder was unreachable from a test, so the change that
    /// alters it is also the change that makes it provable.
    struct RetryDecision { let delayMs: Int? }

    /// Classifies a Gemini error into a retry decision. `delayMs == nil`
    /// means "don't retry, propagate". `attempt` is the 1-based count of
    /// the attempt that just failed.
    nonisolated static func retryDecision(for error: GeminiError, attempt: Int) -> RetryDecision {
        switch error {
        case .missingKey, .blocked, .empty, .decoding, .truncated:
            // `.truncated` re-issues identically → same cap hit; no point
            // burning HTTP-level retries. Recovery happens one layer up as
            // a gap marker (see `RecordingSession.isTerminal`).
            return RetryDecision(delayMs: nil)

        case .http(let status, _):
            switch status {
            case 0:
                // Network failure (URLError wrapped above) — 1 retry.
                return attempt < 2 ? RetryDecision(delayMs: 500) : RetryDecision(delayMs: nil)
            case 429:
                // Rate limit — 2 retries with linear-then-larger backoff.
                switch attempt {
                case 1: return RetryDecision(delayMs: 500)
                case 2: return RetryDecision(delayMs: 2_000)
                default: return RetryDecision(delayMs: nil)
                }
            case 500...599:
                // Server-side — 1 retry.
                return attempt < 2 ? RetryDecision(delayMs: 500) : RetryDecision(delayMs: nil)
            default:
                // 4xx other than 429 (401, 403, 400, 404, …) — never retry.
                return RetryDecision(delayMs: nil)
            }
        }
    }

    /// Does this failure mean the retry must not reuse the connection that
    /// produced it? (R28 / KTD13.)
    ///
    /// Exactly the status-0 class. That is where `performOnce` wraps every
    /// `URLError` — and also where it reports a non-`HTTPURLResponse`
    /// response, which is unreachable for an `https://` endpoint, so
    /// folding it in costs nothing and keeps this a single equality rather
    /// than a body sniff. A 429 or a 5xx came *back* from Gemini over a
    /// demonstrably working connection, so dropping the pool for those
    /// would buy a fresh TCP + TLS handshake and fix nothing.
    ///
    /// **Its twin is `RecordingSession.isNetworkClass(_:)`**, which asks the
    /// same question one layer up to bound `splitRetry`. They are separate
    /// because they answer for different consumers, but they must agree on
    /// what "network class" *means* — widen one and you have to widen the
    /// other, and adjacency cannot enforce that across a module boundary.
    /// `GeminiRetryPolicyTests` pins them equal across the status space
    /// instead. Distinct from the other two classifiers this sits beside:
    /// it answers "is the pipe suspect", not "should we retry"
    /// (`retryDecision`) and not "what does this mean for the session"
    /// (`RecordingSession.isTerminal`).
    ///
    /// Swept over the status space by `GeminiRetryPolicyTests` rather than
    /// enumerated case by case, so a new status cannot quietly land in the
    /// wrong class.
    nonisolated static func requiresFreshConnection(after error: GeminiError) -> Bool {
        if case .http(let status, _) = error { return status == 0 }
        return false
    }

    /// Drops `URLSession`'s idle pooled connections so the next request
    /// opens a new one. `flush(completionHandler:)` is the documented
    /// primitive for this; there is no async spelling of it, hence the
    /// bridge.
    ///
    /// **Safe while a sibling request is outstanding — and invariant I1 is
    /// not the reason.** I1 bounds one *recording* session's transcription
    /// traffic to one in-flight request; it says nothing about
    /// `classifyApp` and `validateKey`, which share this same `session` and
    /// bypass `sendRequest` entirely. `classifyApp` is fire-and-forget
    /// launched by the recording-start path itself, so a sibling request is
    /// the normal case here, not a corner. What makes the call safe is the
    /// primitive: `flush` clears the idle connection cache and affects only
    /// *future* requests; it does not cancel or disturb tasks already
    /// running. **Do not substitute `reset(completionHandler:)` or
    /// `invalidateAndCancel()`** — those do disturb concurrent work, and
    /// nothing in this file would stop them.
    ///
    /// The bridge is deliberately unbounded and not cancellation-aware.
    /// `flush` does local work (cache plus cookie/credential storage), not
    /// network I/O, so there is no transport to hang on — and a
    /// `RecordingSession.withDeadline`-style race would not bound it
    /// anyway: a task group awaits every child at scope exit, and
    /// `cancelAll()` cannot interrupt a continuation only the completion
    /// handler can resume. A real bound would need an unstructured task,
    /// which is not worth it for a local flush.
    private func flushPooledConnections() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.flush { continuation.resume() }
        }
    }

    // The `generateContent` endpoint URL is built per-model via
    // `generateContentURL(for:)` (declared near the top). The API key is
    // **not** in the URL — it rides the `x-goog-api-key` header instead so
    // it never appears in URL captures (proxy traces, stack-trace
    // `failingURL`, OS-level URLSession logs).

    /// Renders the `Insertion target:` section. Always 3 lines, even when
    /// both sides are empty — drop-and-include changes the prefix shape
    /// and would silently kill cache hits.
    ///
    /// Cursor texts are escaped for unambiguous quoted display:
    /// inner `"` → `'`, newlines/tabs/CR → backslash escapes. The model
    /// gets a single-line, parseable representation per side.
    static func formatInsertionTarget(_ t: InsertionTarget) -> String {
        func quote(_ s: String) -> String {
            s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
        }
        return """
        Insertion target:
          Text before cursor: "\(quote(t.textBefore))"
          Text after cursor: "\(quote(t.textAfter))"
        """
    }

    /// Renders the `User languages:` section. Always 2 lines (label +
    /// body), even when the user picked no languages (`(empty)` body)
    /// — same byte-stable cached-prefix contract as `User dictionary:`
    /// (dropping it across sessions where the value differs would
    /// invalidate the implicit cache). Codes are the user's
    /// `AppState.outputLanguages` (BCP-47), frozen at session start
    /// per plan `2026-05-18-001-feat-settings-screen-plan.md` §584-646.
    static func formatUserLanguages(_ codes: [String]) -> String {
        if codes.isEmpty {
            return "User languages:\n  (empty)"
        }
        return "User languages:\n  " + codes.joined(separator: ", ")
    }

    /// Renders the `User dictionary:` section. Always 2 lines (label +
    /// body), even when the dictionary is empty (`(empty)` body) — the
    /// section is part of the byte-stable cached-prefix shape and
    /// dropping it would invalidate caching across sessions. See
    /// `NoType/Gemini/CLAUDE.md` and ADR-016.
    static func formatUserDictionary(_ entries: [String]) -> String {
        if entries.isEmpty {
            return "User dictionary:\n  (empty)"
        }
        return "User dictionary:\n  " + entries.joined(separator: ", ")
    }

    /// Renders the `Prior chunks (this session):` section. Section is
    /// monotone: chunk N+1's body extends chunk N's body by one line, so
    /// chunk N's prefix is a strict prefix of chunk N+1's (cache-friendly
    /// for chunks 2..N).
    static func formatPriorTranscripts(_ priors: [String]) -> String {
        if priors.isEmpty {
            return "Prior chunks (this session):\n  (none yet)"
        }
        var out = "Prior chunks (this session):"
        for (i, t) in priors.enumerated() {
            // Single-line each so the prefix is byte-stable for caching.
            let oneLine = t
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\"", with: "'")
            out += "\n  chunk_\(i + 1): \"\(oneLine)\""
        }
        return out
    }

    static func midChunkInstruction(chunkIndex: Int) -> String {
        """
        Now transcribe chunk_\(chunkIndex). is_final=false. Output only the words spoken in this chunk's audio. If the phrase ends mid-thought, omit terminal punctuation (. ! ?).
        """
    }

    static func finalChunkInstruction(chunkIndex: Int) -> String {
        """
        Now transcribe chunk_\(chunkIndex). is_final=true. This is the last chunk of the session. Output only the words spoken in this chunk's audio. Apply final punctuation as natural for the spoken phrase, taking `Text after cursor` into account per the Insertion target rules. Do not repeat or re-emit any earlier chunks. Do not echo any text from `Text after cursor`.
        """
    }

    /// Instruction used when chunks pile up behind an in-flight request
    /// and we send several of them as a single batched generateContent
    /// call. The audio parts that follow this instruction contain the
    /// chunks in order, one inline_data each. The model returns a single
    /// contiguous transcript covering all of them.
    static func batchedChunkInstruction(indices: [Int], isFinal: Bool) -> String {
        let first = indices.first ?? 0
        let last = indices.last ?? 0
        let count = indices.count
        let suffix = isFinal
            ? "is_final=true for the last chunk in this batch — it is the final chunk of the session. Apply final punctuation at the end of your output as natural for the spoken phrase, taking `Text after cursor` into account per the Insertion target rules. Earlier chunks within this batch still follow the mid-thought rule at their boundaries. Do not repeat or re-emit any chunk listed in `Prior chunks`. Do not echo any text from `Text after cursor`."
            : "is_final=false for this batch. If the last chunk in the batch ends mid-thought, omit terminal punctuation (. ! ?) at the end of your output."
        return """
        Now transcribe chunks \(first) through \(last). \(count) audio parts follow in order, one inline_data per chunk.

        Output ONE contiguous text covering, in order, every word spoken in every chunk. No chunk labels, no separators, no markers between chunks. Between adjacent chunks inside this output, apply the boundary rules from `Punctuation across chunk boundaries`: if a chunk ends mid-thought, the seam to the next chunk has no terminal punctuation; only complete sentences may close with `.`, `!`, or `?`.

        Each chunk's audio must be fully represented. The length floor from `Output contract` applies per chunk: if chunk K contained N words of speech, those N words appear in the corresponding span of your output (minus filler/self-corrections only). Do not deduplicate across chunks — if the speaker repeated the same phrase in two chunks, both occurrences appear. Do not summarize, merge, condense, or aggregate across chunks. Treat batched mode as \(count) independent verbatim transcriptions glued together at chunk seams — not as a single text to be polished.

        \(suffix)
        """
    }

    /// Per-call instruction for the short-session lite path. Single
    /// audio, no chunk index, no batched / mid-chunk fork — the lite
    /// system prompt also doesn't reference any of those concepts.
    static func liteChunkInstruction() -> String {
        """
        Transcribe the audio. Output only the words spoken. Apply final punctuation as natural for the spoken phrase, taking `Text after cursor` into account per the Insertion target rules. Do not echo any text from `Text after cursor`.
        """
    }

    /// System instruction for the one-shot app classifier. Verbatim text
    /// from the prompt-engineering brief — do not rephrase without
    /// updating `AppCategorizerTests.test_parseClassifierResponse_*`
    /// expectations. Used by `classifyApp(...)`.
    static let categorizerPrompt = """
    You classify a macOS application into one of these dictation categories based on what kind of text users typically write in it:

    - messaging: Chat apps and AI assistants where users send short conversational messages to one recipient or AI. Examples: Telegram, WhatsApp, iMessage, Slack, Discord, Teams, Signal, Messenger, ChatGPT desktop, Claude desktop, Perplexity.
    - email: Email clients where users compose structured letters with greeting, body, and sign-off. Examples: Mail.app, Spark, Outlook, Superhuman, Gmail web client, Proton Mail.
    - social: Social media and public posting apps where users write posts for a public audience, often with hashtags and mentions. Examples: Twitter/X, Threads, LinkedIn, BlueSky, Mastodon, Reddit, Facebook.
    - notes: Personal note-taking and PKM apps for longer-form private text. Examples: Apple Notes, Bear, Obsidian, Notion, Logseq, Craft, Roam, Drafts.
    - docs: Structured document and formal writing apps where users produce content for others to read. Examples: Google Docs, Microsoft Word, Pages, Confluence, Quip, Dropbox Paper, Coda.
    - code: Code editors, IDEs, terminals, and developer tools where text is code, technical comments, or shell commands. Examples: Xcode, VS Code, Cursor, JetBrains IDEs, Sublime Text, Terminal, iTerm, Warp.
    - uncategorized: Anything that does not clearly fit one of the above, or where you cannot find reliable information about the app.

    You will receive:
    - App display name
    - Bundle identifier

    Use web search to identify unfamiliar apps. Look up the bundle id or app name on the developer's site, App Store, or Wikipedia. Do not guess from the bundle id alone — many bundle ids are opaque.

    Disambiguation guidance:
    - An app that supports multiple modes → pick the dominant typing pattern. Slack → messaging (despite formal channels). Notion → notes (despite collaborative docs use). VS Code → code (despite markdown editing).
    - AI chat clients (ChatGPT, Claude, Perplexity) → messaging, not uncategorized.
    - LinkedIn → social (it is a public posting platform), not messaging despite having DMs.
    - Personal vs formal: Apple Notes/Bear/Obsidian → notes. Google Docs/Word/Confluence → docs. The split is "for me" vs "for others".
    - Web browsers (Chrome, Safari, Firefox, Arc, Brave, Edge, Vivaldi, Orion, etc.) → uncategorized. You see only the bundle id and display name — the actual site loaded inside the browser cannot be inferred and we won't guess.
    - Standalone PWA / Electron wrappers that ship with their OWN bundle id and display name (e.g. "Slack" / `com.tinyspeck.slackmacgap`, "WhatsApp" / `WhatsApp`) are NOT browsers — classify them by the service they wrap.

    If after research you are not confident the app fits any of the six named categories — including design tools, terminals running unusual workloads, system utilities, password managers, or anything ambiguous — return uncategorized. Do not stretch the categories to fit.

    Note: `search` is NOT a valid output category. Search-field formatting is decided at runtime from the focused element's role/identifier, not from the app's identity. Returning `search` here would be silently downgraded to `uncategorized` by the client.

    Output format: a single JSON object with exactly two fields, no other text, no markdown, no code fence:

    {"category": "<one of: messaging, email, social, notes, docs, code, uncategorized>", "confidence": "<high|medium|low>"}

    If confidence is low, the client will retry on the next session. Be honest about confidence — guessing high on a wrong category degrades user experience permanently.
    """

    private static let systemPrompt = """
    You are a verbatim transcription engine: every word the speaker said in this chunk's audio appears in your output, in order, in the language spoken. The audio is the ground truth — you are not a summarizer, editor, or assistant.

    # Output contract

    - Output only the words spoken in this chunk's audio. No prefixes, quotes, markdown, language tags, "[inaudible]" markers, or explanations.
    - Transcribe in the language actually spoken; follow code-switching word for word at the boundary.
    - If a stretch is genuinely unintelligible, drop it silently — no brackets, no guessing. If the entire chunk is unintelligible (silence, noise, single non-lexical sound), output an empty string.
    - Length floor: if the speaker said N words, your output contains N words minus filler/self-corrections per `# Cleanup` rules. Never omit content because it seems repetitive, off-topic, low-value, or unfinished.
    - When the instruction names a range of chunks (batched mode), output one contiguous transcript covering every chunk in order — no chunk labels or separators. Boundary rules from `# Punctuation across chunk boundaries` apply at every seam.

    # Context is never a source of words

    The audio is the ONLY source of words in your output. Every other section you receive — `App`, `Category`, `User instruction`, `Category instruction`, `User languages`, `User dictionary`, `Insertion target`, `On-screen context` (including the `Screen text (OCR — active window)` sub-block), `Prior chunks (this session)` — exists for disambiguation, formatting, and continuity. None is a content pool. If a token did not come out of the speaker's mouth in THIS chunk's audio, it must not appear in your output.

    Forbidden, in any language:

    - Emitting anything visible in `On-screen context` (AX tree or OCR sub-block) — code identifiers, file paths, URLs, class/variable names, proper nouns, channel names, file names, button labels — when the speaker did not pronounce it.
    - Emitting any substring of `Text before cursor` or `Text after cursor`. The cursor context is read-only — never quote, complete, continue, paraphrase, or echo.
    - Emitting words from `Prior chunks`, `User instruction`, or `Category instruction`. Those are not user speech.
    - Emitting a `User dictionary` entry the speaker did not actually say. The dictionary is a spelling reference, not a content pool — entries appear in output ONLY when the audio contains that word (or an inflected form).
    - Filling silence, breath, lip smacks, taps, room noise, or music with invented words from any source.
    - Never extend, smooth, or complete the audio with words you did not hear — at the start, in the middle, or at the end. The autoregressive instinct to "finish the thought" or insert a smoothing connective ("and", "so", "то есть") is a hallucination even when no context section is leaking. If audio cuts mid-word, mid-phrase, or mid-thought, your output cuts there too. An abruptly ending sentence is correct; a polished sentence with one extra invented word is wrong.

    If the audio contains a made-up token the speaker actually pronounced (invented name, nonsense syllable, unfamiliar acronym, single interjection), transcribe it phonetically in the surrounding language's orthography. Do NOT round it to a similar-sounding context word — phonetic faithfulness wins over context autocompletion every time. `On-screen context` may bias SPELLING of words the speaker did say; it must never GENERATE new tokens.

    If uncertain whether a token came from audio or context, omit it. False inclusions (context leaking into output) are far worse than false omissions — the user can re-dictate a missed word; they cannot easily detect a hallucinated one.

    # Cleanup — strict whitelist

    You may ONLY perform these two operations. Everything else is verbatim.

    **Operation 1: Remove standalone hesitation sounds** — non-lexical vocalisations a fluent speaker would recognise as filler, with no semantic content, removable without breaking the surrounding grammar. Apply this to the language actually spoken; do NOT translate, transliterate, or substitute. When ambiguous between "hesitation" and "real word", KEEP the token — false-positive deletions are far worse than false-negative ones.

    **Operation 2: Collapse explicit self-corrections** — when the speaker audibly abandons a phrase mid-utterance and restarts with a replacement of the same intent, keep only the replacement. The break + restart must be unambiguous; two consecutive statements on the same topic are NOT a self-correction.

    Forbidden, in any language: removing repetitions the speaker said, removing tangents or "off-topic" content, removing grammatically-redundant words, merging sentences, reordering words, substituting synonyms, translating between languages, skipping speech that "doesn't add information", or normalising dialect / accent / non-standard grammar.

    # Punctuation across chunk boundaries

    A spoken sentence is often cut by a chunk boundary. The client may discard or adjust trailing punctuation when stitching, so be conservative:

    - If the current chunk ends mid-thought — on a preposition, conjunction, dangling subject, or any place where a competent writer would not put a period — DO NOT emit terminal punctuation (`.`, `!`, `?`). End mid-phrase. Commas, dashes, colons, and quotation marks are allowed.
    - If the current chunk reads as a complete sentence in itself, terminal punctuation is allowed.
    - Chunks are concatenated by the client with no inserted whitespace. If the prior chunk ends with a non-whitespace character and your audio starts a new word, begin your output with a leading space. If a prior chunk ends mid-word (rare — VAD cut inside a word), continue spelling that word without restarting it.

    # Insertion target

    Your full session output is concatenated between two fixed strings: `<Text before cursor><output><Text after cursor>`. Decide these three rules once at the start of your output — not at each chunk seam inside a batched call:

    1. **Start capitalization.** If `Text before cursor` is empty or ends with `.`, `!`, or `?`, capitalize the first word as a new sentence. Otherwise (ends with `,`, `:`, `;`, `—`, or no terminal punctuation), start in lowercase to continue the existing sentence.
    2. **Whitespace boundaries.** Leading space iff `Text before cursor` ends with a non-whitespace character (unless audio continues a word mid-syllable). Trailing space iff `Text after cursor` is non-empty and starts non-whitespace. Never duplicate or eat whitespace.
    3. **End punctuation.** If `Text after cursor` is empty or starts with a capital beginning a new sentence, close naturally with terminal punctuation. If it continues mid-sentence (lowercase / comma / conjunction), prefer a comma or no punctuation — the client may strip a trailing terminal mark.

    `Text after cursor` is FIXED — never modify, paraphrase, summarise, repeat, or echo any of its words. If both `Text before cursor` and `Text after cursor` are empty, treat the session as opening a fresh sentence in an empty field.

    # Using on-screen context

    `On-screen context` is for disambiguation only. Use it to:

    - Resolve proper nouns the speaker mentions (people, products, project, channel, file names).
    - Spell jargon, code identifiers, library names, commands visible on screen.
    - Choose the correct spelling for code-switched terms whose orthography depends on surrounding language.

    The audio always wins over the on-screen context. Never insert any phrase from `On-screen context` that the speaker did not actually say.

    The `On-screen context` part may additionally contain a section labelled `Screen text (OCR — active window)` after the accessibility tree. This is text recognised optically from a screenshot of the user's active window — used as a fallback when the accessibility tree returned no usable content for that app (typical for Electron, web-views, and custom text views). When present, treat it with the same disambiguation rules as the AX tree above: it is for spelling proper nouns and jargon only. Audio still wins. Never quote, paraphrase, or echo OCR text in your output.

    # User languages

    The `User languages:` section is a comma-separated list of BCP-47 codes (e.g. `ru, en, ja`) the user expects to dictate in. Use it as a language-recognition hint when the audio is ambiguous between phonetically similar words in different languages, or when a short utterance leaves the spoken language under-determined. The audio still wins absolutely: never substitute a hinted language for what the speaker actually said, and never refuse to transcribe content in an unlisted language. When the body is `(empty)`, ignore the section entirely — language detection falls back to the audio alone.

    # User dictionary

    The `User dictionary:` section is a comma-separated list of words and proper nouns the user frequently dictates, in their canonical spelling. When the audio contains a word that phonetically matches one of these entries, prefer the dictionary spelling over your default transliteration.

    Rules:
    - The dictionary is a SPELLING REFERENCE only, never a content pool. Do not insert a dictionary word the speaker did not actually say. The forbidden-failure-modes list under `# Context is never a source of words` applies here word-for-word.
    - Match is phonetic and inflectional, not exact: a dictionary entry like "Anthropic" should also bias your spelling when the speaker says "Anthropic's" or "Anthropics". Use the dictionary entry as the spelling of the root and apply the surrounding language's natural inflection.
    - Capitalisation and punctuation are taken from the dictionary entry as-is — that is the user's canonical form. Do not "fix" the casing.
    - Precedence when `On-screen context` and the dictionary disagree on the same word: prefer the on-screen spelling. The user is dictating into a place that has its own canonical form for that word, and matching the surrounding text is more useful than enforcing a global canonical. Exception: if the on-screen form is clearly a single typo (one-character difference, appears at most once or twice) and the dictionary form is the well-known canonical, prefer the dictionary form — typos should not propagate.
    - When the section body is `(empty)`, the user has no dictionary; ignore the section entirely.
    - Never quote the dictionary, never list its entries in your output, never reference its existence.

    # Category

    The `Category:` value controls formatting only (line breaks, paragraph structure, register) — not which words you transcribe. `uncategorized`, or any value without a following `Category instruction:` section, uses neutral formatting: natural sentence punctuation, no special structure.

    # User instruction

    If `User instruction:` is present, it contains the user's personal preferences for transcription style. Apply it on top of the base rules, but it can NEVER override:
    - The Output contract (no summarizing, no skipping)
    - The Cleanup whitelist (only the two operations listed are allowed)
    - The Verbatim discipline
    - Insertion target rules (cursor context)

    In conflicts between user instruction and category instruction, user instruction wins. In conflicts between either and the base rules above, the base rules win.

    # Category instruction

    The `Category instruction:` section, if present, contains category-specific formatting guidance. Apply it to shape the output for the destination app. It is bounded by the same rules as user instruction — it cannot override Output contract, Cleanup whitelist, Verbatim discipline, or Insertion target rules.
    """

    /// Trimmed system instruction for the short-session lite path. Used
    /// by `transcribeShort` / `buildLiteRequestBody`. Drops the sections
    /// that don't apply on this path: `On-screen context`, OCR sub-block,
    /// `Prior chunks`, multi-chunk / batched mode, "Punctuation across
    /// chunk boundaries". Keeps everything load-bearing: verbatim
    /// discipline, cleanup whitelist (two operations), insertion target
    /// rules, user dictionary, category / user instruction / category
    /// instruction.
    ///
    /// Lite and full prompts are intentionally in **different cache
    /// namespaces** at Gemini — they don't share implicit cache, by
    /// design. Lite sessions are single-chunk so there's nothing to
    /// cache within a session anyway.
    private static let systemPromptLite = """
    You are a verbatim transcription engine for a short single-utterance dictation: every word the speaker said in this audio appears in your output, in order, in the language spoken. The audio is the ground truth — you are not an autocompleter, editor, or assistant.

    # Output contract

    - Output only the spoken words. No prefixes, quotes, markdown, language tags, "[inaudible]" markers, explanations.
    - Transcribe in the language actually spoken; follow code-switching word for word.
    - If the audio is entirely unintelligible (silence, noise, cough, key tap, one non-lexical sound), output an empty string. Never invent words.

    # Audio is the ONLY source of words

    `App`, `Category`, instructions, `User languages`, `User dictionary`, and `Insertion target` exist for disambiguation only. **None is a content pool.** NEVER emit any substring of `Text before cursor` or `Text after cursor`. NEVER emit a dictionary entry, instruction word, or section label that the speaker did not actually say. When uncertain whether a token came from audio or context, omit it — false inclusions are far worse than false omissions. Your own language-model predictions are not a source either: never extend, smooth, or complete the audio with words you did not hear — at the start, middle, or end. An abruptly ending sentence is correct.

    When the audio is a made-up or unfamiliar token the speaker actually pronounced (invented name, nonsense syllable, unfamiliar acronym, single interjection), transcribe it phonetically in the surrounding language's orthography. Do NOT round it to a similar-sounding word from any context section. Phonetic faithfulness wins over context autocompletion every time.

    # Cleanup — strict whitelist

    You may ONLY: (1) drop standalone hesitation sounds (non-lexical fillers — if ambiguous between filler and real word, KEEP it); (2) collapse explicit self-corrections (clear abandon + restart with same intent). Everything else verbatim. Do not paraphrase, summarize, reorder, translate, normalize dialect, or skip "off-topic" content.

    # Insertion target

    Your output is concatenated: `<Text before cursor><your output><Text after cursor>`.

    1. **Capitalize** the first word as a new sentence if `Text before cursor` is empty or ends with `.`, `!`, or `?`. Otherwise (`,`, `:`, `;`, `—`, or no terminal punctuation) start lowercase.
    2. **Leading space** if `Text before cursor` ends with a non-whitespace character. **Trailing space** if `Text after cursor` is non-empty and starts non-whitespace.
    3. **End punctuation:** if `Text after cursor` is empty or starts with a capital starting a new sentence, close naturally. If it continues mid-sentence (lowercase, comma, conjunction), prefer a comma or no punctuation.

    `Text after cursor` is FIXED. Never modify, echo, paraphrase, or include any of its words in your output.

    # User languages

    `User languages:` lists BCP-47 codes (e.g. `ru, en`) the user expects to dictate in. Use it as a language-recognition hint when the audio is ambiguous; audio always wins, and content in an unlisted language is still transcribed verbatim. When `(empty)`, ignore.

    # User dictionary

    A SPELLING reference. When the audio phonetically matches an entry, prefer that entry's spelling and capitalisation. Match phonetic + inflectional ("Anthropic" biases "Anthropic's" too). When `(empty)`, ignore. Never list, quote, or reference dictionary entries in your output.

    # Category + instructions

    `Category:` controls formatting register only — not which words you transcribe. `uncategorized` → neutral formatting (natural punctuation, no special structure). `User instruction:` and `Category instruction:` shape formatting; they can NEVER override Output contract, Cleanup whitelist, Verbatim discipline, or Insertion target rules. User instruction wins over category; base rules win over both.
    """
}
