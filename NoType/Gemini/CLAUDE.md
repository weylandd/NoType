# Gemini module

All communication with the Gemini API. Owns the **cache-friendly request shape** that is load-bearing for cost — read carefully before changing.

## Files

- `GeminiClient.swift` — `actor` wrapping `URLSession`. Owns `buildRequestBody`, the system prompt + per-call instruction templates, the **app classifier** (`classifyApp`). Public methods: `transcribe`, `transcribeBatch`, `transcribeShort`, `validateKey`, `classifyApp`.
- `NetworkReachability.swift` — `actor` wrapping a lazily-started `NWPathMonitor`. Answers one narrow question for `sendRequest`'s pre-flight check: *does the system report no network path at all?* Conservative by construction — see "Retry policy" below.
- `Models.swift` — `Codable` types for the REST schema (`GeminiAPI.Request` / `Response` / `Part` / `UsageMetadata` / `Tool` / `GoogleSearchTool` / …).

Per-app categorization, the categorizer's storage, and the AX search override live in `NoType/Instructions/`. This module owns the network round-trip + parser; categories are not a Gemini concept.

## Invariants

1. **One Gemini request in flight per session** (a batched call is the unit of work, not chunks individually). → `solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md`.
2. **Local concatenation, never re-emit.** Each call returns only its own chunk's text. → `solutions/design-patterns/local-chunk-concatenation-2026-05-15.md`.
3. **Cache-friendly part ordering is load-bearing.** The 7 / 8 / 9 user-message text parts have fixed labels and a fixed order. Pinned by `GeminiRequestBuilderTests`.
4. **API key in `x-goog-api-key` header, never in URL.** Stops URL captures (proxy traces, `URLError.failingURL`, OS-level URLSession logs) from leaking the key.
5. **Transcription requests ship without `tools`.** `googleSearch` is enabled only for `classifyApp`. Pinned by `test_transcriptionRequest_doesNotIncludeTools`.
6. **Anti-completion clause is present in both prompts.** Anchor phrase `"Never extend, smooth, or complete"` is intentionally unique. Pinned by `test_systemPrompts_pinAntiCompletionClause`.

## Hard rules

- **Do not reorder the user-message text parts.** Order is determined by implicit caching, not aesthetics. Changing it = cache miss + extra cost + test failures.
- **Do not put audio first.** Putting unique content at the start poisons the prefix.
- **Do not ask the model to re-emit the full transcript.** Output tokens are 6× input tokens; re-emission defeats caching.
- **Do not drop a non-optional section when it's empty.** Empty `Insertion target` keeps both quoted strings; empty `Prior chunks` keeps `(none yet)`. Removing → prefix-shape change → cache miss.
- **Do not toggle an optional section's omission mid-session.** `User instruction` / `Category instruction` are frozen in `ContextSnapshot` at session start. Re-reading mid-session would shift the part count between chunks.
- **Do not rephrase section labels.** The system instruction references them by exact name (`Insertion target`, `Text before cursor`, `Text after cursor`, `Category`, `User instruction`, `Category instruction`, `User languages`, `User dictionary`, `On-screen context`, `Prior chunks (this session)`).
- **Do not move `system_instruction` content into a `user` part.** Different cache key.
- **Do not promote the OCR sub-block to a top-level prompt part.** It lives inside `On-screen context:`; promoting changes the part count and breaks the contract pinned by `test_partOrderAndLabels_stableWithAndWithoutOCR`.
- **Lite path is single-audio by construction.** `precondition(audios.count == 1)` when `useLitePrompt: true`. Don't batch through the lite path.
- **Any change to the system prompt** requires explicit reviewer attention to `GeminiRequestBuilderTests` — that test is the prompt contract.

## Cache-prefix shape (quick reference)

User-message text parts ship in this fixed order:

1. `App:` / `Category:` — always present.
2. `User instruction:` — omitted iff empty (frozen at session start).
3. `Category instruction:` — omitted iff nil (frozen at session start; typical for `.uncategorized`).
4. `User languages:` — always present; body `(empty)` when no languages picked. Frozen at session start from `AppState.outputLanguages`.
5. `User dictionary:` — always present; body `(empty)` when no entries.
6. `Insertion target:` — with `Text before cursor:` / `Text after cursor:` sub-lines.
7. `On-screen context:` — AX tree + optional OCR sub-block when `screenText` is set.
8. `Prior chunks (this session):` — body `(none yet)` on the first chunk.
9. Per-call instruction line.

Then audio `inline_data` parts (1..N for batched calls). The **lite path** drops parts 7 and 8 entirely (different cache namespace at Gemini, by design).

## Generation config

`thinkingLevel: "minimal"`, `top_p: 0.2`, `responseMimeType: "text/plain"`. Don't set `temperature` or `topK`. Don't enable `responseSchema` for transcription.

## Retry policy

**Before the retry loop: a reachability pre-check.** `sendRequest` asks
`NetworkReachability` whether the system reports a network path and, when
it definitively does not, throws without issuing a request. This exists
because the session's `URLSession` runs `waitsForConnectivity = false` with
a 30 s request timeout, so an offline request does *not* fail fast — it
parks for the full 30 s, and with the status-0 retry below one Gemini call
offline cost ~60.5 s. A `splitRetry` over N chunks multiplied that.

Three things about it are load-bearing:

- **Only `NWPath.Status.unsatisfied` short-circuits.** `.satisfied`,
  `.requiresConnection`, an unrecognised future case, and "the monitor has
  not delivered a path yet" all answer *not offline* and let the real
  request decide. A false offline verdict would break transcription for a
  user who is online — strictly worse than the wait being removed. The
  first-delivery rule is not optional: `NWPathMonitor.currentPath` read
  synchronously right after `start(queue:)` returns `.unsatisfied` on a
  fully-online machine, so the verdict is driven only by
  `pathUpdateHandler`. See `NetworkReachability`'s doc-comment.
- **Deliveries are consumed in order.** The handler `yield`s into an
  `AsyncStream` drained by one consumer task, not one unstructured `Task`
  per update — those carry no ordering guarantee relative to each other,
  and a burst (sleep/wake, VPN bring-up, Wi-Fi roaming) that landed
  `.unsatisfied` after a newer `.satisfied` would latch a false offline
  verdict. Nothing re-reads the path afterwards, so that verdict would
  persist until the *next* path change and short-circuit every request in
  between — the one false-offline shape that does not self-heal.
- **The throw sits outside the retry loop.** That is *how* a short-circuit
  avoids being re-issued, without teaching `retryDecision` to distinguish
  bodies — which would have cost a genuine status-0 *timeout* its retry.
  Moving the check into `performOnce` would double every short-circuit;
  `GeminiClientOfflineShortCircuitTests` pins the position.
- **The error is `GeminiError.offlineShortCircuit`, not a new case.** It is
  built by the same `wrapURLError` the real `URLSession` failure goes
  through, so it is byte-identical downstream: `RecordingSession.isTerminal`
  calls it recoverable, `shouldRetain` retains its audio, and
  `AppState.payloadForSessionFailure` peels the code back out for the "no
  internet" HUD. A distinct case would require updating `isTerminal` /
  `shouldRetain` in lockstep — a stop condition in the retry plan.

The monitor is created on the first Gemini request and never at launch —
`GeminiClient` is constructed inside `NoTypeApp.init()`, which runs before
`NSApplicationMain`. See `NoType/UI/CLAUDE.md` "Launch ordering".

Implemented via `retryDecision(for:attempt:)`:

- `URLError` (network / timeout) → 1 retry after 500 ms.
- HTTP 429 → 2 retries with 500 ms then 2 s backoff.
- HTTP 5xx → 1 retry after 500 ms.
- HTTP 4xx other than 429 → no retry.
- `GeminiError.truncated` (`finishReason == MAX_TOKENS`) → no retry (an identical re-issue truncates identically; recovered one layer up as a `[…]` gap marker).

Each attempt logs `attempt=N`. These retries are the HTTP-level safety net inside one Gemini call. **Session-level resilience lives one layer up** in `RecordingSession`: if a call still fails after exhausting its retries, the session classifies the error as terminal (auth, blocked, encode, cancellation) or recoverable (everything else — HTTP, empty, decoding, `.truncated`). Recoverable failures become `RecordingSession.failureMarker` ("[…]") at stitch time and a batched call gets split into N independent `transcribe` retries first. The session aborts only on terminal errors or when every dispatched chunk failed. See `NoType/Recording/CLAUDE.md` "Partial recovery".

`sendRequest` also inspects the candidate's `finishReason` after parsing (response-parsing only — no prompt or cache-prefix change): a content block (SAFETY/RECITATION/PROHIBITED_CONTENT/BLOCKLIST/SPII/IMAGE_SAFETY) throws `GeminiError.blocked` (terminal, same as a prompt-level block); `MAX_TOKENS` throws `GeminiError.truncated` (recoverable → gap marker); `STOP` / absent / unrecognised keep the text. Pinned by `GeminiFinishReasonTests`.

## Endpoint URLs

(force-unwrap is the documented exception for compile-time-known literals):

- `modelsListURL` — file-scope constant, `…/v1beta/models` (used by `validateKey`).
- `generateContentURL(for:)` — static **function** building `…/models/<modelID>:generateContent` from a `GeminiModel`. Transcription passes the session's frozen model (Flash-Lite or 3.5 Flash — Settings → API & Usage); `classifyApp` always passes `.flashLite` (the classifier is model-agnostic so the user's transcription choice doesn't change classifier cost). The model lives in the URL path, not the request body, so the cache-prefix part order is untouched — pinned by `GeminiRequestBuilderTests.test_generateContentURL_perModel_mapsToModelID`.

## Testing

- `NoTypeTests/GeminiRequestBuilderTests.swift` — pins the cache-friendly part ordering and the system-prompt anti-completion clause. Touching this test means the prompt contract changed → explicit reviewer review.
- `NoTypeTests/PromptEvalTests.swift` + `NoTypeTests/PromptEvalHarness.swift` — live-API behavioural eval. Drives 9 audio fixtures through the prompts and asserts on substring / word-count / wordCountCeiling. Gated by Keychain entry `app.notype.tests.gemini` (or `NOTYPE_GEMINI_KEY` env). Skips cleanly when neither is set.
- `NoTypeTests/AppCategorizerTests.swift` — pins the classifier JSON parser.
- `NoTypeTests/NetworkReachabilityTests.swift` — pins the offline verdict's conservatism (only `.unsatisfied`; `nil` / `.requiresConnection` / an unrecognised future case all answer "not offline"), the `NWPath.Status` mapping, the first-delivery wait cap, and last-writer-wins on `record`. `test_liveProbe_onAnOnlineMachine_doesNotReportOffline` starts a **real** `NWPathMonitor` and asserts a value rather than skipping — deliberate, but it means the suite fails on a genuinely offline machine. Don't run the suite with Wi-Fi off during an offline smoke test and read that failure as a regression.
- `NoTypeTests/GeminiClientOfflineShortCircuitTests.swift` — pins the short-circuit error's *shape* (same `.http(0, "URLError code=…")` both producers build, still recoverable and retainable downstream), the log-only status-0 description arm, and the *position* of the check via a source guard: present in `sendRequest`, absent from `performOnce`, and gating an actual `throw` ahead of the retry loop.

## Pointers

- Why Gemini 3.1 Flash-Lite → `solutions/tooling-decisions/gemini-3-1-flash-lite-2026-05-15.md`.
- Why one request in flight (serial actor) → `solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md`.
- Why no streaming → `solutions/design-patterns/no-streaming-gemini-2026-05-15.md`.
- Why local concat → `solutions/design-patterns/local-chunk-concatenation-2026-05-15.md`.
- Per-app classifier → `solutions/architecture-patterns/per-app-categorization-instructions-2026-05-15.md` + `NoType/Instructions/CLAUDE.md`.
- OCR sub-block → `solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md` + `NoType/Context/CLAUDE.md`.
- User dictionary section → `solutions/architecture-patterns/personal-dictionary-2026-05-15.md` + `NoType/Dictionary/CLAUDE.md`.
- Prompt-size audit + Tier 1/2 trim methodology → `solutions/architecture-patterns/gemini-prompt-section-audit-2026-05-17.md`. Current size (post-Tier-2): full ~2 700 tokens, lite ~960 tokens (system + cache prefix, excluding audio).
