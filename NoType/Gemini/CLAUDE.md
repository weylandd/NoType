# Gemini module

All communication with the Gemini API. Owns the **cache-friendly request shape** that is load-bearing for cost — read carefully before changing.

## Files

- `GeminiClient.swift` — `actor` wrapping `URLSession`. Owns `buildRequestBody`, the system prompt + per-call instruction templates, the **app classifier** (`classifyApp`). Public methods: `transcribe`, `transcribeBatch`, `transcribeShort`, `validateKey`, `classifyApp`.
- `Models.swift` — `Codable` types for the REST schema (`GeminiAPI.Request` / `Response` / `Part` / `UsageMetadata` / `Tool` / `GoogleSearchTool` / …).

Per-app categorization, the categorizer's storage, and the AX search override live in `NoType/Instructions/`. This module owns the network round-trip + parser; categories are not a Gemini concept.

## Invariants

1. **One Gemini request in flight per session** (a batched call is the unit of work, not chunks individually). → `solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md`.
2. **Local concatenation, never re-emit.** Each call returns only its own chunk's text. → `solutions/design-patterns/local-chunk-concatenation-2026-05-15.md`.
3. **Cache-friendly part ordering is load-bearing.** The 6 / 7 / 8 user-message text parts have fixed labels and a fixed order. Pinned by `GeminiRequestBuilderTests`.
4. **API key in `x-goog-api-key` header, never in URL.** Stops URL captures (proxy traces, `URLError.failingURL`, OS-level URLSession logs) from leaking the key.
5. **Transcription requests ship without `tools`.** `googleSearch` is enabled only for `classifyApp`. Pinned by `test_transcriptionRequest_doesNotIncludeTools`.
6. **Anti-completion clause is present in both prompts.** Anchor phrase `"Never extend, smooth, or complete"` is intentionally unique. Pinned by `test_systemPrompts_pinAntiCompletionClause`.

## Hard rules

- **Do not reorder the user-message text parts.** Order is determined by implicit caching, not aesthetics. Changing it = cache miss + extra cost + test failures.
- **Do not put audio first.** Putting unique content at the start poisons the prefix.
- **Do not ask the model to re-emit the full transcript.** Output tokens are 6× input tokens; re-emission defeats caching.
- **Do not drop a non-optional section when it's empty.** Empty `Insertion target` keeps both quoted strings; empty `Prior chunks` keeps `(none yet)`. Removing → prefix-shape change → cache miss.
- **Do not toggle an optional section's omission mid-session.** `User instruction` / `Category instruction` are frozen in `ContextSnapshot` at session start. Re-reading mid-session would shift the part count between chunks.
- **Do not rephrase section labels.** The system instruction references them by exact name (`Insertion target`, `Text before cursor`, `Text after cursor`, `Category`, `User instruction`, `Category instruction`, `On-screen context`, `Prior chunks (this session)`).
- **Do not move `system_instruction` content into a `user` part.** Different cache key.
- **Do not promote the OCR sub-block to a top-level prompt part.** It lives inside `On-screen context:`; promoting changes the part count and breaks the contract pinned by `test_partOrderAndLabels_stableWithAndWithoutOCR`.
- **Lite path is single-audio by construction.** `precondition(audios.count == 1)` when `useLitePrompt: true`. Don't batch through the lite path.
- **Any change to the system prompt** requires explicit reviewer attention to `GeminiRequestBuilderTests` — that test is the prompt contract.

## Cache-prefix shape (quick reference)

User-message text parts ship in this fixed order:

1. `App:` / `Category:` — always present.
2. `User instruction:` — omitted iff empty (frozen at session start).
3. `Category instruction:` — omitted iff nil (frozen at session start; typical for `.uncategorized`).
4. `User dictionary:` — always present; body `(empty)` when no entries.
5. `Insertion target:` — with `Text before cursor:` / `Text after cursor:` sub-lines.
6. `On-screen context:` — AX tree + optional OCR sub-block when `screenText` is set.
7. `Prior chunks (this session):` — body `(none yet)` on the first chunk.
8. Per-call instruction line.

Then audio `inline_data` parts (1..N for batched calls). The **lite path** drops parts 6 and 7 entirely (different cache namespace at Gemini, by design).

## Generation config

`thinkingLevel: "minimal"`, `top_p: 0.2`, `responseMimeType: "text/plain"`. Don't set `temperature` or `topK`. Don't enable `responseSchema` for transcription.

## Retry policy

Implemented via `retryDecision(for:attempt:)`:

- `URLError` (network / timeout) → 1 retry after 500 ms.
- HTTP 429 → 2 retries with 500 ms then 2 s backoff.
- HTTP 5xx → 1 retry after 500 ms.
- HTTP 4xx other than 429 → no retry.

Each attempt logs `attempt=N`. When a session fails partway through, **don't paste a partial transcript** — better to lose work than to insert incomplete text.

## Endpoint URLs

Both file-scope constants (force-unwrap is the documented exception for compile-time-known literals):

- `modelsListURL` — `…/v1beta/models` (used by `validateKey`).
- `generateContentURL` — `…/models/<modelID>:generateContent` (used by transcription + classification).

## Testing

- `NoTypeTests/GeminiRequestBuilderTests.swift` — pins the cache-friendly part ordering and the system-prompt anti-completion clause. Touching this test means the prompt contract changed → explicit reviewer review.
- `NoTypeTests/AppCategorizerTests.swift` — pins the classifier JSON parser.
- Live-API tests gated by `NOTYPE_INTEGRATION=1`.

## Pointers

- Why Gemini 3.1 Flash-Lite → `solutions/tooling-decisions/gemini-3-1-flash-lite-2026-05-15.md`.
- Why one request in flight (serial actor) → `solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md`.
- Why no streaming → `solutions/design-patterns/no-streaming-gemini-2026-05-15.md`.
- Why local concat → `solutions/design-patterns/local-chunk-concatenation-2026-05-15.md`.
- Per-app classifier → `solutions/architecture-patterns/per-app-categorization-instructions-2026-05-15.md` + `NoType/Instructions/CLAUDE.md`.
- OCR sub-block → `solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md` + `NoType/Context/CLAUDE.md`.
- User dictionary section → `solutions/architecture-patterns/personal-dictionary-2026-05-15.md` + `NoType/Dictionary/CLAUDE.md`.
