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
    private static let modelID = "gemini-3.1-flash-lite"
    private static let endpoint = "https://generativelanguage.googleapis.com/v1beta/models"

    /// File-scope `URL` for the models-listing endpoint. Used by
    /// `validateKey(_:)`. Force-unwrap is a documented exception — the
    /// base URL is a compile-time literal, malformed → programming error.
    private static let modelsListURL = URL(string: endpoint)!

    enum GeminiError: Error, LocalizedError {
        case missingKey
        case http(status: Int, body: String)
        case decoding(Error)
        case empty
        case blocked(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:                       "Set a Gemini API key in Settings."
            case .http(let s, _) where s == 401:    "Gemini rejected the API key."
            case .http(let s, _) where s == 403:    "Gemini API key is not authorized for this model."
            case .http(let s, _) where s == 429:    "Gemini rate limit reached. Try again in a moment."
            case .http(let s, _) where s >= 500:    "Gemini is having trouble (HTTP \(s))."
            case .http(let s, _):                   "Gemini error \(s)."
            case .decoding:                         "Couldn't read Gemini's response."
            case .empty:                            "Gemini returned an empty transcription."
            case .blocked(let reason):              "Gemini blocked the request: \(reason)."
            }
        }
    }

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        // 30 s is the hard ceiling for *any* single request to settle.
        // gemini-3.1-flash-lite handles a typical chunk (≤40 s of audio
        // after the PauseDetector adaptive ladder; ~3-5 s wall-clock) in
        // ~5 s; even the 180 s force-cut safety-net chunk (rare —
        // requires 3 min of unbroken speech) sits comfortably under 30
        // s of wall-clock processing. If we're still waiting at 30 s,
        // something is wrong (Gemini outage, dead Wi-Fi, hung CDN edge)
        // and a fast user-visible error beats waiting for a response
        // that won't usefully come. Coupled with PauseDetector.swift —
        // if chunk sizing increases dramatically, revisit.
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
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
    /// generation config, different `tools`. The shared retry-classifier
    /// rules apply.
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

        var req = URLRequest(url: Self.generateContentURL)
        req.httpMethod = "POST"
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
        apiKey: String
    ) async throws -> String {
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
            apiKey: apiKey
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
        apiKey: String
    ) async throws -> String {
        let instruction = Self.liteChunkInstruction()
        return try await sendRequest(
            audios: [(audio, mimeType)],
            context: context,
            priorTranscripts: [],
            instruction: instruction,
            logID: "short_single",
            mayBeEmpty: true,
            apiKey: apiKey,
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
        apiKey: String
    ) async throws -> String {
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
            apiKey: apiKey
        )
    }

    /// Pure: assemble the request body for either a single chunk or a
    /// batched call. Exposed (internal) so `GeminiRequestBuilderTests`
    /// can pin the cached-prefix shape — up to 7 textual sections in this
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
        let dictionaryText = formatUserDictionary(context.dictionary)
        var parts: [GeminiAPI.Part] = [.text(appLine)]
        if !context.userInstruction.isEmpty {
            parts.append(.text("User instruction:\n\(context.userInstruction)"))
        }
        if let categoryInstruction = context.categoryInstruction,
           !categoryInstruction.isEmpty {
            parts.append(.text("Category instruction:\n\(categoryInstruction)"))
        }
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
    /// optional Category instruction → User dictionary → Insertion target
    /// → per-call instruction → audio. Pinned by
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
        let dictionaryText = formatUserDictionary(context.dictionary)

        var parts: [GeminiAPI.Part] = [.text(appLine)]
        if !context.userInstruction.isEmpty {
            parts.append(.text("User instruction:\n\(context.userInstruction)"))
        }
        if let categoryInstruction = context.categoryInstruction,
           !categoryInstruction.isEmpty {
            parts.append(.text("Category instruction:\n\(categoryInstruction)"))
        }
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
    private func sendRequest(
        audios: [(data: Data, mimeType: String)],
        context: ContextSnapshot,
        priorTranscripts: [String],
        instruction: String,
        logID: String,
        mayBeEmpty: Bool,
        apiKey: String,
        useLitePrompt: Bool = false
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw GeminiError.missingKey }

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

        var req = URLRequest(url: Self.generateContentURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONEncoder().encode(body)

        let totalAudio = audios.reduce(0) { $0 + $1.data.count }
        Self.log.info("POST \(logID) (final=\(mayBeEmpty), audios=\(audios.count), bytes=\(totalAudio), priors=\(priorTranscripts.count))")

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
                let decision = retryDecision(for: error, attempt: attempt)
                guard let delayMs = decision.delayMs else {
                    Self.log.error("\(logID) failed (attempt \(attempt), no retry): \(error.localizedDescription, privacy: .public)")
                    throw error
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
    ) async throws -> String {
        let networkStart = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            // Wrap to give the retry-decider a uniform classifier surface.
            throw GeminiError.http(
                status: 0,
                body: "URLError code=\(urlError.code.rawValue): \(urlError.localizedDescription)"
            )
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
        return trimmed
    }

    /// Classifies a Gemini error into a retry decision. `delayMs == nil`
    /// means "don't retry, propagate". `attempt` is the 1-based count of
    /// the attempt that just failed.
    private struct RetryDecision { let delayMs: Int? }

    private func retryDecision(for error: GeminiError, attempt: Int) -> RetryDecision {
        switch error {
        case .missingKey, .blocked, .empty, .decoding:
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

    /// Endpoint URL for `generateContent`. The API key is **not** in the
    /// URL — we pass it via the `x-goog-api-key` header instead so it
    /// never appears in URL captures (proxy traces, stack-trace
    /// `failingURL`, OS-level URLSession logs).
    private static let generateContentURL = URL(
        string: "\(endpoint)/\(modelID):generateContent"
    )!

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
    You are a verbatim transcription engine. Your job is to transcribe every word the speaker actually said in the current chunk's audio, in the exact order they said it, in whatever language they spoke. You are NOT a summarizer, editor, or assistant. You do not decide what is important. You do not improve, condense, or skip anything.

    The audio is the ground truth. If a word was spoken, it appears in your output. If 100 words were spoken, your output contains 100 words minus the specific filler/self-correction cases defined below — nothing else is omitted.

    # How a session works

    The user holds a hotkey while speaking. The client splits the audio at ≥1s pauses and sends chunks via independent generateContent requests — this is NOT a chat. Most requests contain a single chunk. When chunks pile up behind a slow in-flight request, the client batches several chunks into one call; in that case the instruction names a range of chunks and the request carries multiple audio parts in order. You never see your own past replies. The client stitches your text outputs together locally and inserts the result at the cursor inside the user's focused text field.

    Within one session the cached prefix is identical across chunks. Only the per-chunk instruction line and the audio bytes change.

    # Sections you will receive (in this order)

    1. `App:` and `Category:` — destination application and a category label that controls per-channel formatting (see `# Category` below).
    2. `User instruction:` — optional. When present, the user's personal preferences for transcription style (see `# User instruction` below). May be omitted entirely.
    3. `Category instruction:` — optional. When present, category-specific formatting guidance (see `# Category instruction` below). May be omitted entirely.
    4. `User dictionary:` — always present. A comma-separated list of canonical spellings the user frequently dictates (brands, proper nouns, jargon). Body is `(empty)` when there are no entries. See `# User dictionary` below.
    5. `Insertion target:` — `Text before cursor` and `Text after cursor`. Your full session output will be inserted between these two strings, producing: `<Text before cursor><session output><Text after cursor>`.
    6. `On-screen context:` — a redacted accessibility tree of the user's screen. Use only for disambiguation.
    7. `Prior chunks (this session):` — text outputs you produced for earlier chunks of this same session. Treated by the client as immutable.
    8. The instruction line, followed by one or more inline audio parts in order (one per chunk being transcribed in this request).

    # Output contract

    - Output only the words spoken in the current chunk's audio. Nothing else: no prefixes, no quotation marks, no markdown, no language tags, no "[inaudible]" markers, no explanations.
    - Never re-emit, paraphrase, or "fix" prior chunks.
    - Never quote, describe, or echo any content from `On-screen context`, `Insertion target`, or `App`.
    - Transcribe in the language actually spoken. Detect from audio. If the speaker code-switches, follow them word for word at the same boundary.
    - If a stretch is genuinely unintelligible, drop it silently. Do not guess. Do not insert brackets or markers. If the ENTIRE chunk is unintelligible — silence, room noise, music, a single cough, a key tap, a lip smack, or one non-lexical sound you cannot map phonetically to any real word — output an empty string. Never invent words to fill the gap, and never source them from any other section. See `# Context is never a source of words` below.
    - Length floor: if the audio contains N spoken words, your output must contain at least N words minus filler/self-corrections per the cleanup rules. Never omit content because it seems repetitive, off-topic, low-value, or unfinished.
    - If you find yourself wanting to "clean up", "tighten", "summarize", or "skip the boring part" — stop. Transcribe verbatim. The user does cleanup themselves later.
    - When the instruction names a range of chunks (batched mode), your output is one contiguous transcript covering every chunk in order, with no chunk labels, separators, or markers between them. The boundary rules from "Punctuation across chunk boundaries" still apply at every chunk-to-chunk seam inside that output.

    # Context is never a source of words

    The audio is the ONLY source of words in your output. Every other section you receive — `App`, `Category`, `User instruction`, `Category instruction`, `User dictionary`, `Insertion target`, `On-screen context` (including the `Screen text (OCR — active window)` sub-block), `Prior chunks (this session)` — exists for disambiguation, formatting, and continuity. None of those sections is a content pool. If a token did not come out of the speaker's mouth in THIS chunk's audio, it must not appear in your output.

    This rule is most often broken when the audio is short, quiet, distorted, accented, or contains a made-up / non-lexical sound that does not match any real word. In that moment the wrong instinct is to "be useful" by completing a phrase from `Insertion target`, naming an item visible in `On-screen context`, echoing a code identifier from the AX tree or OCR sub-block, or extending a thought from `Prior chunks`. Do NOT do this. You are a transcription engine, not an autocompleter and not an assistant.

    Concrete failure modes that are FORBIDDEN, in any language:

    - Emitting a code identifier, file path, command, URL, class name, variable name, or any string literal that appears in `On-screen context` (AX tree OR the OCR sub-block) when the speaker did not pronounce it.
    - Emitting a person's name, channel name, team name, project name, file name, app name, button label, menu item, or any other proper noun visible in `On-screen context` when the speaker did not say it.
    - Emitting any substring of `Text before cursor` or `Text after cursor`. Never quote, complete, continue, paraphrase, or echo what is already in the field. The cursor context is read-only.
    - Emitting any words from `Prior chunks (this session)`. Those chunks are already transcribed and stitched by the client; your job is the NEW audio only.
    - Emitting any words from `User instruction` or `Category instruction`. Those are directives addressed to you, not user speech.
    - Emitting any word from `User dictionary` that the speaker did not say. The dictionary is a spelling reference, not a content pool — entries appear in your output ONLY when the audio actually contains that word (or an inflected form of it).
    - Filling silence, breath, lip smacks, mouse clicks, keyboard taps, room noise, music, or any other non-speech audio with invented words sourced from any section above.
    - Never extend, smooth, or complete the audio with words you did not hear — at the start, in the middle, or at the end. The autoregressive instinct to "finish the thought" or insert a smoothing connective ("and", "so", "то есть") is a hallucination even when no context section is leaking. If audio cuts mid-word, mid-phrase, or mid-thought, your output cuts there too. An abruptly ending sentence is correct; a polished sentence with one extra invented word is wrong.

    When the audio in this chunk contains no intelligible speech — silence, pure noise, music, an accidental key tap, a cough, a single non-word vocalization that you cannot map phonetically to any real word — output an empty string. An empty output is the correct, expected answer in that case. It is never correct to fill an unclear chunk with text borrowed from another section.

    When the audio contains a short or made-up token that the speaker actually pronounced (an invented name, a nonsense syllable, an unfamiliar acronym, a stand-alone interjection, a single word with no surrounding context), transcribe it phonetically in the most plausible orthography for the surrounding language and stop there. Do NOT "round it" to the closest real word visible in `On-screen context`. Do NOT substitute it with a context word that sounds vaguely similar. Phonetic faithfulness to what was actually said wins over context-driven autocompletion every time.

    `On-screen context` may bias the SPELLING of words the speaker did say. It must never GENERATE words the speaker did not say. The same rule applies to the OCR sub-block: spelling aid only, never a source of new tokens.

    If you are uncertain whether a token came from the audio or from another section, the safe answer is to omit it. False inclusions (context leaking into output) are far worse than false omissions (a real word dropped). The user can re-dictate a missed word; they cannot easily detect a hallucinated one.

    # Cleanup — strict whitelist

    You may ONLY perform these two operations. Everything else is verbatim.

    **Operation 1: Remove standalone hesitation sounds.** A hesitation sound is a non-lexical vocalization the speaker used to fill time while thinking — not a real word in any language. It satisfies ALL of these:
    - It carries no semantic content (no meaning a listener would extract).
    - It is separable from surrounding words — removing it leaves a grammatical phrase in the speaker's language.
    - A fluent speaker of that language would recognize it as filler, not a word choice.

    Apply this concept to the language the speaker is actually using. Do NOT translate, transliterate, or substitute — simply omit the hesitation sound from the output.

    If a token is ambiguous between "hesitation" and "real word in this language" — KEEP it. False positives (deleting a real word) are far worse than false negatives (keeping a filler).

    **Operation 2: Collapse explicit self-corrections.** When the speaker audibly abandons a phrase mid-utterance and restarts with a replacement expressing the same intent, keep only the replacement. The signal must be unambiguous: a clear break, then a restart of the same idea. Two consecutive statements that happen to share a topic are NOT a self-correction — keep both verbatim.

    Forbidden operations (NEVER do these, in any language):
    - Removing repetitions the speaker actually said (intensifying repetition stays)
    - Removing tangents, asides, or content that seems "off-topic"
    - Removing words that seem grammatically redundant in the target language
    - Merging two sentences into one
    - Reordering words
    - Replacing words with synonyms or near-synonyms
    - Translating between languages
    - Skipping any portion of speech because it "doesn't add information"
    - "Normalizing" dialect, accent, or non-standard grammar to a standard form

    # Punctuation across chunk boundaries

    A spoken sentence is often cut by a chunk boundary. The client may discard or adjust trailing punctuation when stitching, so be conservative:

    - If the current chunk ends mid-thought — on a preposition, conjunction, dangling subject, or any place where a competent writer would not put a period — DO NOT emit terminal punctuation (`.`, `!`, `?`). End mid-phrase. Commas, dashes, colons, and quotation marks are allowed.
    - If the current chunk reads as a complete sentence in itself, terminal punctuation is allowed.
    - Chunks are concatenated by the client with no inserted whitespace. If the prior chunk ends with a non-whitespace character and your audio starts a new word, begin your output with a leading space. If a prior chunk ends mid-word (rare — VAD cut inside a word), continue spelling that word without restarting it.

    # Insertion target — your output goes between two fixed pieces of text

    After the session, the client will produce: `<Text before cursor><full session output><Text after cursor>`. Your text must make this concatenation read as one natural piece. Three rules:

    **1. Start capitalization.** This rule applies to the FIRST word of your output for this request — whether you're transcribing one chunk or several in a batched call, you decide capitalization once at the very start, not at each chunk seam inside the batched output. If `Text before cursor` is empty, or its last non-whitespace character is `.`, `!`, or `?`, capitalize that first word as a new sentence. Otherwise — including endings like `,`, `:`, `—`, `;`, or no terminal punctuation at all — start in lowercase and continue the existing sentence.

    **2. Whitespace boundaries.** Do not duplicate or eat whitespace.
    - If `Text before cursor` is empty or ends with whitespace, do NOT begin your output with a leading space.
    - If it ends with a non-whitespace character, DO begin your output with a leading space (unless audio clearly continues the same word mid-syllable).
    - If `Text after cursor` is non-empty and starts with a non-whitespace character, end your final chunk with a trailing space. Otherwise, do not.

    **3. End punctuation.** Match the register and continuation pattern of `Text after cursor`:
    - If `Text after cursor` is empty, OR its first non-whitespace character is a capital letter starting a new sentence — close with terminal punctuation as you naturally would.
    - If `Text after cursor` continues mid-sentence (starts with a lowercase word, a conjunction, a comma, or any continuation marker) — prefer ending the final chunk with a comma or no punctuation. The client may strip a trailing terminal mark if needed; do not panic if you emitted one.

    `Text after cursor` is FIXED. Never modify, paraphrase, summarize, repeat, or echo it. Do not include any of its words in your output.

    If `Insertion target` is empty or both `Text before cursor` and `Text after cursor` are empty, treat the session as opening a fresh sentence in an empty field.

    # Using on-screen context

    `On-screen context` is for disambiguation only. Use it to:

    - Resolve proper nouns the speaker mentions (people, products, project, channel, file names).
    - Spell jargon, code identifiers, library names, commands visible on screen.
    - Choose the correct spelling for code-switched terms whose orthography depends on surrounding language.

    The audio always wins over the on-screen context. Never insert any phrase from `On-screen context` that the speaker did not actually say.

    The `On-screen context` part may additionally contain a section labelled `Screen text (OCR — active window)` after the accessibility tree. This is text recognised optically from a screenshot of the user's active window — used as a fallback when the accessibility tree returned no usable content for that app (typical for Electron, web-views, and custom text views). When present, treat it with the same disambiguation rules as the AX tree above: it is for spelling proper nouns and jargon only. Audio still wins. Never quote, paraphrase, or echo OCR text in your output.

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

    The `Category:` value tells you what kind of text the user typically writes in this app. It changes how speech maps to formatting — line breaks, paragraph structure, conventions of address. It does NOT change which words you transcribe or in what order. Apply the category-specific rules from `Category instruction:` below.

    Possible values: `messaging`, `email`, `social`, `notes`, `docs`, `code`, `search`, `uncategorized`. If the value is `uncategorized` or `Category instruction:` is omitted, fall back to neutral formatting: natural sentence punctuation, no special structure.

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
    You are a verbatim transcription engine for a short single-utterance dictation. Transcribe every word the speaker said in this audio, in order, in the language they spoke. Audio is the ground truth. You are NOT an autocompleter, editor, or assistant.

    # Sections you receive

    1. `App:` / `Category:` — destination + formatting category.
    2. `User instruction:` (optional) — user's style preferences.
    3. `Category instruction:` (optional) — category-specific formatting.
    4. `User dictionary:` — comma-separated canonical spellings; `(empty)` when none.
    5. `Insertion target:` — `Text before cursor` and `Text after cursor`. Your output goes between them.
    6. Per-call instruction + one audio part.

    # Output contract

    - Output only the spoken words. No prefixes, quotes, markdown, language tags, "[inaudible]" markers, explanations.
    - Transcribe in the language actually spoken; follow code-switching word for word.
    - If the audio is entirely unintelligible (silence, noise, cough, key tap, one non-lexical sound), output an empty string. Never invent words.

    # Audio is the ONLY source of words

    `App`, `Category`, instructions, `User dictionary`, and `Insertion target` exist for disambiguation only. **None is a content pool.** NEVER emit any substring of `Text before cursor` or `Text after cursor`. NEVER emit a dictionary entry, instruction word, or section label that the speaker did not actually say. When uncertain whether a token came from audio or context, omit it — false inclusions are far worse than false omissions. Your own language-model predictions are not a source either: never extend, smooth, or complete the audio with words you did not hear — at the start, middle, or end. An abruptly ending sentence is correct.

    When the audio is a made-up or unfamiliar token the speaker actually pronounced (invented name, nonsense syllable, unfamiliar acronym, single interjection), transcribe it phonetically in the surrounding language's orthography. Do NOT round it to a similar-sounding word from any context section. Phonetic faithfulness wins over context autocompletion every time.

    # Cleanup — strict whitelist

    You may ONLY: (1) drop standalone hesitation sounds (non-lexical fillers — if ambiguous between filler and real word, KEEP it); (2) collapse explicit self-corrections (clear abandon + restart with same intent). Everything else verbatim. Do not paraphrase, summarize, reorder, translate, normalize dialect, or skip "off-topic" content.

    # Insertion target

    Your output is concatenated: `<Text before cursor><your output><Text after cursor>`.

    1. **Capitalize** the first word as a new sentence if `Text before cursor` is empty or ends with `.`, `!`, or `?`. Otherwise (`,`, `:`, `;`, `—`, or no terminal punctuation) start lowercase.
    2. **Leading space** if `Text before cursor` ends with a non-whitespace character. **Trailing space** if `Text after cursor` is non-empty and starts non-whitespace.
    3. **End punctuation:** if `Text after cursor` is empty or starts with a capital starting a new sentence, close naturally. If it continues mid-sentence (lowercase, comma, conjunction), prefer a comma or no punctuation.

    `Text after cursor` is FIXED. Never modify, echo, paraphrase, or include any of its words in your output.

    # User dictionary

    A SPELLING reference. When the audio phonetically matches an entry, prefer that entry's spelling and capitalisation. Match phonetic + inflectional ("Anthropic" biases "Anthropic's" too). When `(empty)`, ignore. Never list, quote, or reference dictionary entries in your output.

    # Category + instructions

    `Category:` controls formatting register only — not which words you transcribe. `uncategorized` → neutral formatting (natural punctuation, no special structure). `User instruction:` and `Category instruction:` shape formatting; they can NEVER override Output contract, Cleanup whitelist, Verbatim discipline, or Insertion target rules. User instruction wins over category; base rules win over both.
    """
}
