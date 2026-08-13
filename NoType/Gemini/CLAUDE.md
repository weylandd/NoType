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

## Request budgets and retry policy

### Request budgets — both scale with the audio-part count

**Latency tracks the number of audio parts in the request, not its byte size
and not the audio duration.** Measured 2026-08-13 against the live API with
the real request shape and real AAC encoding, four repetitions each:

| shape | audio | bytes | max idle | max total |
|---|---|---|---|---|
| 4-chunk batch | 159 s | 653 KB | 26.85 s | 27.16 s |
| 1-chunk 180 s force-cut | 180 s | 735 KB | 7.62 s | 7.81 s |

The batch carries *less* audio and *fewer* bytes and takes roughly four times
as long. That is why `requestInactivityBudget(audioPartCount:)` is a function
and there is no flat request timeout any more: `2 s + 10 s × parts`, clamped
to `[10 s, 90 s]`, which clears each measured maximum by a near-uniform
~1.55×. The full derivation — the fitted model, the safety factor, and why
the factor is generous rather than tight — lives in that function's
doc-comment and is not repeated here.

Four things about the wiring are load-bearing:

- **The budget is applied per request** (`URLRequest.timeoutInterval`), set in
  `sendRequest` where the part count is known. This works because
  `URLRequest.timeoutInterval` **overrides**
  `URLSessionConfiguration.timeoutIntervalForRequest` in *both* directions —
  measured against a stalling socket, not assumed: config 3 s / request 9 s
  failed at 9.01 s, config 9 s / request 3 s failed at 3.01 s. Had the
  configuration clamped instead, a batch would have been silently killed at
  the session default while every budget test stayed green.
  `GeminiRetryPolicyTests` pins that precedence with a live loopback socket
  for exactly that reason.
- **Every request in the file sets its own budget**, and the count is pinned
  against the count of `URLRequest` constructions, so a *new* request path
  that inherits the session default breaks the guard rather than shipping a
  budget nobody chose. `classifyApp` and `validateKey` carry no audio and sit
  off the axis — `auxiliaryRequestBudget` (30 s, deliberately unchanged by
  the transcription cut) and a 10 s literal respectively.
- **`timeoutIntervalForResource` is session-level and has no per-request
  counterpart** — also measured: resource 3 s against a request timeout of
  30 s failed at 3.27 s. So the whole-transfer ceiling is a single value
  sized for the largest request the budget function will serve
  (`requestBudgetCeiling + uploadAllowance`). It is an additional ceiling and
  never a fallback: the two timers are independent and whichever fires first
  wins.
- **It moved from 30 s, and that fixed a live defect.** The measured max
  total for a 4-part batch is 27.16 s against the old 30 s ceiling, so a
  5-part batch was already exceeding it — killing a legitimate request and
  producing a silent `[…]` in text the user had already had pasted.

**What the part-count finding means for the pause ladder.** `PauseDetector`'s
adaptive threshold used to be justified partly as a network-budget device —
"keep each chunk short so its request fits inside the 30 s ceiling". That
reasoning is retired along with the flat ceiling: latency tracks *parts*, so a
shorter chunk does not buy a shorter request, and what actually costs time is
batching several chunks into one call. The ladder's shape is unchanged and
still right on its own merits (chunk quality — no mid-sentence force-cuts), but
prose anywhere that derives it from a fixed network timeout is wrong. Corrected
in `PauseDetector.swift`, `NoType/Recording/CLAUDE.md` invariants 4–5 and
`docs/solutions/design-patterns/adaptive-pause-threshold-2026-05-16.md`.

### Retry policy

**Before the retry loop: a reachability pre-check.** `sendRequest` asks
`NetworkReachability` whether the system reports a network path and, when
it definitively does not, throws without issuing a request. This exists
because the session's `URLSession` runs `waitsForConnectivity = false`, so an
offline request does *not* fail fast — it parks for the request's whole
inactivity budget, and with the status-0 retry below one Gemini call offline
cost twice that. A `splitRetry` over N chunks multiplied it again.

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

**Every status-0 error a transcription call can throw goes through
`wrapURLError`.** All three producers — the `URLError` catch in
`performOnce`, its no-`HTTPURLResponse` guard, and `sendRequest`'s pre-flight
short-circuit — so the body always carries `urlErrorBodyPrefix` and
`AppState`'s `NetworkErrorTranslator.parse` never fails on one. This is not
tidiness: the no-response guard used to throw a bare
`http(status: 0, body: "no HTTPURLResponse")`, which the parser rejected, and
the failure fell past the network branch into the generic HTTP arm and
rendered as **"Gemini rejected the request / Unexpected response (HTTP 0)"** —
a status number that is not a status, about a request that never reached
Gemini. Pinned by
`GeminiClientOfflineShortCircuitTests.test_performOnce_throwsNoBareStatusZero`
(a source guard, because the bare form is still a constructible `GeminiError`
and no value test can see the revert). `classifyApp` and `validateKey` keep
their bare status-0 guards deliberately — they sit off the transcription path
and `validateKey`'s renders through `errorDescription` on the API-key surface,
where "Gemini error 0." is pinned by that same file.

The monitor is created on the first Gemini request and never at launch —
`GeminiClient` is constructed inside `NoTypeApp.init()`, which runs before
`NSApplicationMain`. See `NoType/UI/CLAUDE.md` "Launch ordering".

Implemented via `retryDecision(for:attempt:)`:

- `URLError` (network / timeout) → 1 retry after 500 ms.
- HTTP 429 → 2 retries with 500 ms then 2 s backoff.
- HTTP 5xx → 1 retry after 500 ms.
- HTTP 4xx other than 429 → no retry.
- `GeminiError.truncated` (`finishReason == MAX_TOKENS`) → no retry (an identical re-issue truncates identically; recovered one layer up as a `[…]` gap marker).

**The network-class retry — and only that one — is issued over a fresh
connection** (R28 / KTD13). `requiresFreshConnection(after:)` gates a
`flushPooledConnections()` call (`URLSession.flush`) between the failure and
the backoff sleep, because the measured failure was a dead *pooled
connection*, not a dead network: a request stalled for the full budget and
the same payload answered in 1.7 s on a new connection moments later.
Re-issuing over the socket that just went silent re-inherits the fault and
turns the retry into nothing but a second wait. A 429 or a 5xx came *back*
from Gemini over a demonstrably working connection, so those arms do not pay
for a handshake. Two things about it are load-bearing:

- **`requiresFreshConnection` has a twin — `RecordingSession.isNetworkClass(_:)`.**
  Both are `.http(status: 0, _)`. They are separate because they answer for
  different consumers (drop the pool / bound `splitRetry`), and nothing
  structural keeps them agreeing across the module boundary, so
  `GeminiRetryPolicyTests` pins them equal over the status space. Widen one,
  widen the other.
- **`flushPooledConnections` is safe beside a sibling request, and invariant
  I1 is not the reason.** I1 bounds one *recording* session's transcription
  traffic; `classifyApp` and `validateKey` share the same `URLSession` and
  bypass `sendRequest` entirely, and `classifyApp` is fire-and-forget
  launched by the recording-start path itself. What makes it safe is that
  `flush` clears the idle connection cache and affects only *future*
  requests. `reset(completionHandler:)` and `invalidateAndCancel()` do
  disturb in-flight work and must not be substituted.

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
- `NoTypeTests/GeminiRetryPolicyTests.swift` — pins the HTTP retry ladder (swept over the status space, not enumerated), `requiresFreshConnection` and its agreement with `RecordingSession.isNetworkClass`, and the budgets. The budget assertions are written **against the measurement table carried as a fixture**, not against the literals: the derived budget must clear each measured maximum with a stated safety factor, and that factor must stay near-uniform across the measured shapes — so a re-tune has to argue with the data rather than edit a number. Plus the clamps, the ceiling's margin over every derivable budget, the upload allowance derived from a slow-uplink figure (it appears on both sides of the ceiling's own definition, so without that it would have no mutation coverage), and AE11's restated cost. `test_perRequestTimeout_overridesTheSessionConfiguration_soAWidenedBudgetIsReal` stands up a **real loopback socket that listens and is never accepted** and asserts the request's own longer timeout wins over a shorter session default — the one platform fact the whole per-request derivation rests on. It costs ~4 s and is deliberate. None of this was reachable from a test before U1 of `docs/plans/2026-08-11-001-fix-dictation-delivery-reliability-plan.md` widened it past `private` (KTD3).
- `NoTypeTests/GeminiClientOfflineShortCircuitTests.swift` — pins the short-circuit error's *shape* (same `.http(0, "URLError code=…")` both producers build, still recoverable and retainable downstream), the log-only status-0 description arm, and the *position* of the check via a source guard: present in `sendRequest`, absent from `performOnce`, and gating an actual `throw` ahead of the retry loop. It carries a second source guard for the R28 connection drop (present, gated, ordered ahead of the backoff), one pinning that the shipped `URLSession` is built from `makeSessionConfiguration()` — without that, a hand-rolled config in `init()` leaves every budget test green while the app ships a different timeout — and one pinning that **every** `URLRequest` in the module sets a budget of its own, by *count* rather than by needle, so a new request path silently inheriting the session default breaks it.

## Pointers

- Why Gemini 3.1 Flash-Lite → `solutions/tooling-decisions/gemini-3-1-flash-lite-2026-05-15.md`.
- Why one request in flight (serial actor), and the scope boundary that invariant does **not** reach → `solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md`.
- Why the connection flush's safety claim cites `flush`'s own semantics rather than invariant I1 → `solutions/conventions/cited-invariant-must-cover-the-population-2026-08-11.md`.
- Why no streaming → `solutions/design-patterns/no-streaming-gemini-2026-05-15.md`.
- Why local concat → `solutions/design-patterns/local-chunk-concatenation-2026-05-15.md`.
- Per-app classifier → `solutions/architecture-patterns/per-app-categorization-instructions-2026-05-15.md` + `NoType/Instructions/CLAUDE.md`.
- OCR sub-block → `solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md` + `NoType/Context/CLAUDE.md`.
- User dictionary section → `solutions/architecture-patterns/personal-dictionary-2026-05-15.md` + `NoType/Dictionary/CLAUDE.md`.
- Prompt-size audit + Tier 1/2 trim methodology → `solutions/architecture-patterns/gemini-prompt-section-audit-2026-05-17.md`. Current size (post-Tier-2): full ~2 700 tokens, lite ~960 tokens (system + cache prefix, excluding audio).
