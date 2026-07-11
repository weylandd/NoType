# Gemini module

All communication with the Gemini API. Owns the **cache-friendly request shape** that is load-bearing for cost — read carefully before changing.

## Files

- `GeminiClient.swift` — `actor` wrapping `URLSession`. Owns `buildRequestBody`, the system prompt + per-call instruction templates, the **app classifier** (`classifyApp`). Public methods: `transcribe`, `transcribeBatch`, `transcribeShort`, `validateKey`, `classifyApp`.
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

## Pointers

- Why Gemini 3.1 Flash-Lite → `solutions/tooling-decisions/gemini-3-1-flash-lite-2026-05-15.md`.
- Why one request in flight (serial actor) → `solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md`.
- Why no streaming → `solutions/design-patterns/no-streaming-gemini-2026-05-15.md`.
- Why local concat → `solutions/design-patterns/local-chunk-concatenation-2026-05-15.md`.
- Per-app classifier → `solutions/architecture-patterns/per-app-categorization-instructions-2026-05-15.md` + `NoType/Instructions/CLAUDE.md`.
- OCR sub-block → `solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md` + `NoType/Context/CLAUDE.md`.
- User dictionary section → `solutions/architecture-patterns/personal-dictionary-2026-05-15.md` + `NoType/Dictionary/CLAUDE.md`.
- Prompt-size audit + Tier 1/2 trim methodology → `solutions/architecture-patterns/gemini-prompt-section-audit-2026-05-17.md`. Current size (post-Tier-2): full ~2 700 tokens, lite ~960 tokens (system + cache prefix, excluding audio).
