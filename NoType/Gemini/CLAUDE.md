# Gemini module

This module owns all communication with the Gemini API. It implements transcription requests with **cache-friendly part ordering** that is load-bearing for cost — read carefully before changing request shape.

Files:
- `GeminiClient.swift` — `actor` wrapping a `URLSession`. Owns the request-assembly path (`buildRequestBody`), the per-call instruction templates, the system prompt, and the one-shot **app classifier** call (`classifyApp(...)` — see ADR-015 and `NoType/Instructions/CLAUDE.md`). Exposes `transcribe`, `transcribeBatch`, `validateKey`, `classifyApp`.
- `Models.swift` — `Codable` types for the REST schema we use (`GeminiAPI.Request` / `Response` / `Part` / `UsageMetadata` / `Tool` / `GoogleSearchTool` / …).

Per-app categorization and the related `User instruction:` / `Category instruction:` cached-prefix sections live in `NoType/Instructions/` (the categories, the assignment store, and the categorizer actor). This module exposes the underlying network calls; the categories themselves are not a Gemini concept.

---

## Endpoint & auth

```
POST https://generativelanguage.googleapis.com/v1beta/models/{MODEL_ID}:generateContent
  Headers:
    Content-Type:    application/json
    x-goog-api-key:  {API_KEY}
```

- Model ID: `gemini-3.1-flash-lite` (post-GA). Single constant in `GeminiClient.swift`.
- API key from `SecretStore` (see `NoType/Keychain/CLAUDE.md`). Passed via the `x-goog-api-key` HTTP header — never in the URL — so it can't leak through stack traces (`URLError.failingURL`), proxy traces, or OS-level URLSession logging. Never log the value yourself.

---

## Request shape — DO NOT REORDER

Every chunk request has the following structure. The order of `parts` is **load-bearing** for implicit caching.

The user `parts` use **fixed labels** in this exact order:

1. `App:` / `Category:` (always present).
2. `User instruction:` (omitted iff `ContextSnapshot.userInstruction` is empty).
3. `Category instruction:` (omitted iff `ContextSnapshot.categoryInstruction` is `nil` — typical for `.uncategorized`).
4. `User dictionary:` (always present; body `(empty)` when no entries — see ADR-016).
5. `Insertion target:` with `Text before cursor:` and `Text after cursor:` sub-lines.
6. `On-screen context:` (the AX tree, plus optional OCR sub-block when `screenText` is set).
7. `Prior chunks (this session):`.
8. The per-call instruction line.

Then one or more audio `inline_data` parts. The system instruction is written against these exact labels — do not rephrase them. ADR-015 introduced sections 1–3; ADR-016 introduced section 4; sections 5–8 predate them.

```jsonc
{
  "system_instruction": { "parts": [{ "text": "<see PromptTemplates>" }] },
  "contents": [
    {
      "role": "user",
      "parts": [
        // ─── Cached prefix (byte-stable across chunks of one session) ──
        { "text": "App: Slack (com.tinyspeck.slackmacgap)\nCategory: messaging" },

        // Optional: omitted entirely when ContextSnapshot.userInstruction
        // is empty (typical when the user hasn't filled the textarea in
        // the Instructions tab). Frozen at session start — see ADR-015.
        { "text": "User instruction:\nalways use Em-dashes, never colons" },

        // Optional: omitted entirely when ContextSnapshot.categoryInstruction
        // is nil (the default for `Category: uncategorized`; also possible
        // if the user blanked the override for a real category).
        { "text": "Category instruction:\nThis text is going into a chat or messenger app. Users in this context write short, conversational messages..." },

        // Insertion target: содержимое поля под курсором + позиция курсора.
        // Снимается один раз на старте сессии (см. NoType/Context/CLAUDE.md).
        // Если поля нет / Electron вернул мусор — обе строки "" (секция остаётся!).
        { "text": "Insertion target:\n  Text before cursor: \"Hey John, thanks for the update — \"\n  Text after cursor: \"\"" },

        { "text": "On-screen context:\n<redacted AX tree>" },

        // Секция остаётся даже на первом чанке — с телом "(none yet)".
        // Иначе shape префикса между чанком 1 и чанком 2 не совпадёт и кеш промахнётся.
        { "text": "Prior chunks (this session):\n  chunk_1: \"...\"\n  chunk_2: \"...\"" },

        // ─── Per-call variable suffix ───
        { "text": "Now transcribe chunk_3. is_final=false. Output only the words spoken in this chunk's audio. If the phrase ends mid-thought, omit terminal punctuation (. ! ?)." },
        { "inline_data": { "mime_type": "audio/mp4", "data": "<base64 m4a>" } }
        // Batched calls append additional inline_data parts here, one per chunk, in order.
      ]
    }
  ],
  "generationConfig": {
    "thinkingConfig": { "thinkingLevel": "minimal" },
    "top_p": 0.2,
    "responseMimeType": "text/plain"
  }
}
```

The shape collapses gracefully:

- Unknown app + no global user instruction → 5 text parts (App+Category, Insertion target, On-screen, Prior chunks, instruction). Same count the pre-ADR-015 path emitted.
- User instruction set but app uncategorized → 6 parts.
- Classified app, no user instruction → 6 parts.
- Both set → 7 parts.

`GeminiRequestBuilderTests` pins each of these branches.

### Why this order

Implicit caching (on by default for Gemini 3.x) hits on the longest common prefix between requests in your project. Across chunks of a single session:
- `system_instruction` is identical.
- `App:` / `Category:` are identical.
- `User instruction:` and `Category instruction:` are identical (captured into `ContextSnapshot` from a frozen `InstructionsContext` at session start — see `NoType/Instructions/CLAUDE.md`). Either omitted or unchanged — never partially present across chunks of one session.
- `Insertion target:` is identical — captured once at session start; the cursor doesn't move during a session because the user is holding the hotkey.
- AX tree is identical (we snapshot it once at session start).
- `Prior chunks (this session):` is identical for chunks 1..N-1 when sending chunk N (chunk 2 sees chunk 1's transcript; chunk 3 sees chunks 1+2; etc.). The prefix grows monotonically but each prefix-of-prefix matches.

Only the per-chunk *instruction* and *audio* parts at the end are unique per request. By keeping these last, the entire common prefix above hits the cache → ~90% discount on those tokens.

**Minimum cached prefix length** for Gemini 3/3.1 is 4096 tokens per Google docs. AX tree alone (full-screen) is typically 5–15K tokens. So once we have any meaningful AX context, the prefix easily clears the floor.

For very short single-chunk sessions, there is no prior chunk → no cache hit possible. That's fine, only one request was made.

### What you must NEVER do

- **Don't put the audio first.** Even though some examples online do, putting unique content at the start poisons the prefix.
- **Don't ask Gemini to re-emit the full transcript.** Each chunk returns only its own text. We concat client-side.
- **Don't change part order for "readability".** The order is determined by caching, not aesthetics.
- **Don't drop a non-optional section when it's empty.** Empty `Insertion target` keeps both fields with `""`; empty `Prior chunks` keeps the body `(none yet)`. Removing one changes the prefix shape and breaks cache hits.
- **Don't toggle an optional section's omission mid-session.** `User instruction` / `Category instruction` are captured into `ContextSnapshot` from `InstructionsContext` at session start. If the user edits the Instructions tab while a session is in flight, the in-flight session keeps its frozen value. If you ever change this and re-read mid-session, the part count would shift between chunks and break cache.
- **Don't rephrase the section labels.** The system instruction references them by exact name (`Text before cursor`, `Text after cursor`, `Category`, `User instruction`, `Category instruction`, etc.). Renaming any label is a prompt-contract change.
- **Don't move `system_instruction` content into a `user` part** — different fields, both serve as prefix, but mixing them up changes the cache key.
- **Don't promote the OCR fallback to a new top-level prompt part.** The optional `Screen text (OCR — active window)` sub-block lives **inside** the `On-screen context:` text part, appended after the AX tree text. Promoting it would change the part count and break the cache contract pinned by `GeminiRequestBuilderTests.test_partOrderAndLabels_stableWithAndWithoutOCR`.
- **Don't ship transcription requests with `tools` declared.** Web search (`googleSearch`) is only enabled for the one-shot app classifier (`classifyApp`). Transcription requests must encode without a top-level `tools` field — pinned by `test_transcriptionRequest_doesNotIncludeTools`.

### Short-session lite path

For short single-utterance sessions (user release before VAD detects a pause, total audio < 2 s, no prior chunks of the same session), `GeminiClient.transcribeShort(audio:mimeType:context:apiKey:)` ships a deliberately reduced prompt shape via `Self.buildLiteRequestBody`. Discriminator and snapshot assembly live in `RecordingSession` — see `NoType/Recording/CLAUDE.md` "Short final-only path (lite context)".

Differences from the full path:

| Aspect | Full path | Lite path |
|---|---|---|
| `system_instruction` | `Self.systemPrompt` (~3500 words) | `Self.systemPromptLite` (~600 words) |
| User-message text parts | 6–8 (App+Category, optional UI, optional CI, User dictionary, Insertion target, On-screen context, Prior chunks, instruction) | 4–6 (App+Category, optional UI, optional CI, User dictionary, Insertion target, instruction) |
| `On-screen context:` part | **always present** (body `(no on-screen context available)` when empty) | **omitted entirely** |
| `Prior chunks (this session):` part | **always present** (body `(none yet)` on chunk 1) | **omitted entirely** |
| Per-call instruction | `midChunkInstruction(chunkIndex:)` / `finalChunkInstruction(chunkIndex:)` / `batchedChunkInstruction(indices:isFinal:)` | `liteChunkInstruction()` — single audio, no chunk index, no batched / mid-chunk fork |
| Audio parts | 1..N (batching) | exactly 1 (lite is single-audio by construction; `sendRequest` has `precondition(audios.count == 1)` when `useLitePrompt: true`) |

**Cache implications.** Lite and full live in **different implicit-cache namespaces** at Gemini — they don't share prefix bytes (different system instruction, different part shape) and thus can't share cache. By design:

- Lite sessions are single-chunk by construction, so there's no within-session cache to hit anyway.
- Cross-session lite-to-lite cache hits are possible when two short sessions share the same system instruction + App+Category + (optional) user/category instruction + user dictionary. In practice that's frequent (same app, same user), so the lite namespace does build up its own cache over time.
- Cross-session lite-to-full or full-to-lite hits never happen — accepted.

`Self.systemPromptLite` deliberately does NOT reference `On-screen context`, `Prior chunks`, OCR sub-block, batched mode, or "Punctuation across chunk boundaries". It keeps verbatim discipline, cleanup whitelist (two operations), insertion target rules, user dictionary rules, and category / user instruction / category instruction guidance — everything load-bearing for a single short utterance.

Pinned by `GeminiRequestBuilderTests.test_litePrompt_*`. Any change to the lite prompt shape requires those tests to be updated explicitly.

### Optional OCR fallback sub-block (ADR-014)

When `ContextSnapshot.screenText` is set, `buildRequestBody` appends `screenText.formattedForPrompt()` inside the **existing** `On-screen context:` text part. The sub-block opens with a separator line so the model can tell AX content from OCR content:

```
On-screen context:
=== ... ===
Window: ...
  - ...

--- Screen text (OCR — active window) ---
=== Slack (com.tinyspeck.slackmacgap) ===
Window:
  #engineering
  John Doe
  hi team, can someone review the design draft
```

The trigger and security boundary are documented in `NoType/Context/CLAUDE.md`. Within a single session the snapshot (including `screenText`) is captured once, so the cached prefix is byte-stable across chunks 2..N exactly like in the AX-only case. Across sessions the prefix shape doesn't have to match — different sessions don't share cache anyway.

The system instruction picks up the sub-block in a single paragraph under "Using on-screen context" — it tells the model that the OCR text follows the same disambiguation rules as the AX tree above and that audio still wins. No new top-level label needs documenting in "Sections you will receive (in this order)".

---

## Generation config

| Field | Value | Why |
|---|---|---|
| `thinkingLevel` | `"minimal"` | Transcription is not a reasoning task; we want lowest latency. |
| `top_p` | `0.2` | Tight nucleus — keeps the model close to the highest-probability transcription path without the determinism artefacts of `temperature=0`. |
| `responseMimeType` | `"text/plain"` | We don't want JSON wrapping. |

Do not set `temperature` or `topK` — defaults are fine.

Do not enable `responseSchema` for transcription. Plain text out, we keep it simple.

---

## Final chunk

Identical request shape, but the instruction text changes. The final-chunk instruction explicitly references `Text after cursor` so the model knows whether to apply a terminal mark or continue mid-sentence:

> "Now transcribe chunk_N. **is_final=true**. This is the last chunk of the session. Output only the words spoken in this chunk's audio. Apply final punctuation as natural for the spoken phrase, taking `Text after cursor` into account per the Insertion target rules. Do not repeat or re-emit any earlier chunks. Do not echo any text from `Text after cursor`."

The prefix is unchanged — caching still works. Only the instruction part differs.

Note: the model's leading-space + terminal-punctuation choices are advisory. The client always runs `finalizeForInsertion(stitched, textBefore, textAfter)` (see `NoType/Injection/CLAUDE.md`) before paste — it strips stranded terminal punctuation when `Text after cursor` continues mid-text (lowercase / continuation punct / closing bracket / closing quote) and inserts a leading space when `Text before cursor` ends with a non-whitespace character. Catches the "no final chunk" edge case (release after >1 s of silence — no final request gets sent) and corrects model misjudgements deterministically.

---

## Serial execution + batching

`GeminiClient` is an `actor`. It exposes two transcription paths:

```swift
actor GeminiClient {
    /// Single chunk — used when nothing is queued behind the in-flight call.
    func transcribe(audio: Data, mimeType: String, context: ContextSnapshot,
                    priorTranscripts: [String], chunkIndex: Int,
                    isFinal: Bool, apiKey: String) async throws -> String

    /// 2..N chunks in one round-trip. Used when chunks pile up behind a
    /// slow request — typically at release, when the final chunk plus
    /// any still-pending non-final chunks all go out together.
    func transcribeBatch(audios: [(data: Data, mimeType: String)],
                         context: ContextSnapshot, priorTranscripts: [String],
                         chunkIndices: [Int], isFinal: Bool,
                         apiKey: String) async throws -> String
}
```

Both paths share the same private `sendRequest` builder, so the cached-prefix shape is byte-identical between them. Only the per-request instruction line and the count of `inline_data` parts differ. The model's contract for batched calls: produce one contiguous text spanning all audios, applying continuation/whitespace/punctuation rules across chunk boundaries inside the response.

`RecordingSession` decides single vs batch on the fly: its sender task drains the `pending` queue each time it wakes; if there's exactly one chunk waiting it calls `transcribe`, otherwise `transcribeBatch`. The actor still gives us "at most one in-flight HTTP request per session" — the unit of work is now a batch instead of a strict 1-chunk call.

The actor holds a session-scoped `URLSession` configured with:
- `timeoutIntervalForRequest = 30s`
- `timeoutIntervalForResource = 60s`
- `waitsForConnectivity = false` (we want to fail fast offline, not queue)

---

## Retry policy

Implemented in `GeminiClient.sendRequest` via the `retryDecision(for:attempt:)` classifier (`GeminiClient.swift:618`):

- **Network errors / timeout (`URLError`):** 1 retry with 500 ms delay. Then fail the session.
- **HTTP 429 (rate limit):** 2 retries with 500 ms then 2 s backoff. Then fail.
- **HTTP 5xx:** 1 retry with 500 ms delay. Then fail.
- **HTTP 4xx other than 429 (auth, bad request, not found):** no retry. Fail immediately, surface in UI.

The retry loop is shared by both `transcribe` and `transcribeBatch` — single-chunk and batched paths see the same behaviour. Each attempt is logged with `attempt=N` so retry storms are visible at the log level.

When a session fails partway through we do **not** paste a partial transcript. Better to lose work than to paste something incomplete.

---

## Token usage tracking

Every response includes `usageMetadata` with:
- `promptTokenCount`
- `candidatesTokenCount`
- `cachedContentTokenCount` ← this is what we monitor

In debug builds, log `cachedContentTokenCount / promptTokenCount` ratio. Should be >0.7 for any non-first chunk in a session that has AX context. If it's not, our prefix ordering broke.

In release builds, do not log token counts (PII-adjacent — reveals usage patterns).

---

## Prompt templates

All prompt-template strings live in `GeminiClient.swift` today:

- `Self.systemPrompt` — the transcription system instruction for the **full** path (mid-session chunks, multi-chunk final batches, all sessions ≥ 2 s of audio). Tells the model how to use `Category` / `User instruction` / `Category instruction`, on-screen context, prior chunks, and how the boundary rules layer on top.
- `Self.systemPromptLite` — trimmed system instruction (~600 words) for the **short-session lite path** only. Reachable via `transcribeShort(...)` when `RecordingSession.shouldUseLitePath(...)` fires. Drops references to `On-screen context`, `Prior chunks`, OCR sub-block, batched mode, and chunk-boundary rules. Different cache namespace from `systemPrompt` — by design.
- `Self.categorizerPrompt` — system instruction for the one-shot app classifier (`classifyApp`). Verbatim text in ADR-015's source brief; do not rephrase without updating `AppCategorizerTests.test_parseClassifierResponse_*`.
- `Self.midChunkInstruction(chunkIndex:)`, `Self.finalChunkInstruction(chunkIndex:)`, `Self.batchedChunkInstruction(indices:isFinal:)`, `Self.liteChunkInstruction()` — per-call variable suffix that goes immediately before the audio parts. `liteChunkInstruction` is single-audio with no chunk index — paired with `systemPromptLite`.
- Default per-category prompt texts live on `AppCategory.defaultPrompt` (see `NoType/Instructions/AppCategory.swift`). The user can override per category from the Instructions tab; overrides are stored in `InstructionsStore.categoryPromptOverrides`.

### System instruction (load-bearing — change only with full review)

The system instruction is **the** prompt contract. It references the exact section labels (`Category`, `User instruction`, `Category instruction`, `Insertion target`, `Text before cursor`, `Text after cursor`, `On-screen context`, `Prior chunks (this session)`) and dictates capitalization/whitespace/punctuation behavior at the cursor boundary. Any change here must be reviewed against `GeminiRequestBuilderTests` (which sees the rendered prompt) and the test cases listed below.

The actual text lives in `Self.systemPrompt`. Highlights:

- "Sections you will receive (in this order)" now enumerates 7 items: `App` / `Category`, `User instruction` (optional), `Category instruction` (optional), `Insertion target`, `On-screen context`, `Prior chunks (this session)`, instruction + audio.
- A `# Category` section explains the values and the fallback to neutral formatting when `Category: uncategorized` or `Category instruction:` is omitted.
- A `# User instruction` section explains precedence: base rules > user instruction > category instruction. The model is told to never let the user instruction override the Output contract / Cleanup whitelist / Verbatim discipline / Insertion target rules.
- A `# Category instruction` section bounds the per-category formatting guidance with the same constraints as user instruction.

Outside those three sections, the system instruction is unchanged from the pre-feature version (Output contract, Cleanup whitelist, Punctuation across chunk boundaries, Insertion target rules, Using on-screen context).

The forbidden-failure-modes list inside `# Context is never a source of words` carries an additional bullet ("Never extend, smooth, or complete the audio with words you did not hear …") that closes the autoregressive-completion class of hallucinations — model dropping in a smoothing connective in the middle of a phrase, or completing a thought past the audio's end — which is orthogonal to context leakage. The lite prompt carries the same idea as a single sentence at the end of `# Audio is the ONLY source of words`. Pinned by `GeminiRequestBuilderTests.test_systemPrompts_pinAntiCompletionClause`. Anchor phrase `"Never extend, smooth, or complete"` is intentionally unique — `smooth` appears nowhere else in either prompt.

### Per-chunk instruction templates

The variable suffix that goes immediately before the `inline_data` audio part. `\(chunkIndex)` is 1-based and is **not** reset on the final chunk.

For `is_final=false`:

```
Now transcribe chunk_\(chunkIndex). is_final=false. Output only the words spoken in this chunk's audio. If the phrase ends mid-thought, omit terminal punctuation (. ! ?).
```

For `is_final=true`:

```
Now transcribe chunk_\(chunkIndex). is_final=true. This is the last chunk of the session. Output only the words spoken in this chunk's audio. Apply final punctuation as natural for the spoken phrase, taking `Text after cursor` into account per the Insertion target rules. Do not repeat or re-emit any earlier chunks. Do not echo any text from `Text after cursor`.
```

### App classifier (`classifyApp`)

`classifyApp(displayName:bundleID:apiKey:)` is the second public REST entry point in this module (alongside `transcribe` / `transcribeBatch` / `validateKey`). One-shot generateContent call with:

- The categorizer system instruction (`Self.categorizerPrompt`).
- One user `text` part with `display_name` and `bundle_id` (window title is intentionally NOT sent in v1 — would leak PII without scrubbing first).
- `tools: [{"google_search": {}}]` so the model can look up unfamiliar bundle ids.
- `generationConfig` with `top_p=0.0`, `responseMimeType=application/json`, `thinkingLevel=minimal`.

Returns `GeminiClient.AppCategoryClassification` (an `(AppCategory, Confidence)` tuple). The parser `Self.parseClassifierResponse` is exposed (internal) so `AppCategorizerTests` can pin the JSON shape — unknown values collapse to `.uncategorized` / `.low`, fenced code blocks (` ```json ... ``` `) are stripped, malformed inputs throw `.decoding`.

The categorizer is driven by `AppCategorizer` in `NoType/Instructions/` — that actor owns the dedup logic, low-confidence handling, and the assignment-write to `InstructionsStore`. This module only owns the network round-trip + parser.

---

## Testing

Tests live in `NoTypeTests/`:
- `GeminiRequestBuilderTests.swift` — **must** verify part order AND section labels. The user-message text parts appear in this exact sequence (with optionals omitted as documented above):
  1. `App: ` / `Category: `
  2. `User instruction:` (when non-empty)
  3. `Category instruction:` (when non-nil)
  4. `Insertion target:` (with `Text before cursor:` and `Text after cursor:` sub-lines)
  5. `On-screen context:` — may carry an optional `Screen text (OCR — active window)` sub-block when `ContextSnapshot.screenText` is set; sub-block lives INSIDE this part, not as a new part. Pinned by `test_partOrderAndLabels_stableWithAndWithoutOCR`.
  6. `Prior chunks (this session):`
  7. The per-call instruction line

  Then one or more `inline_data` audio parts. If this test changes, the cache invariant changed → require explicit review.
- `AppCategorizerTests.swift` — pins JSON parsing (`GeminiClient.parseClassifierResponse`), categorizer actor's concurrency dedup, and the low-confidence / uncategorized "don't cache" paths.
- Mock-`URLSession` retry-policy tests are planned alongside the retry implementation (see "Retry policy" above).
- Integration tests against the real API live alongside the unit tests in `NoTypeTests/`, gated by env var `NOTYPE_INTEGRATION=1`.

Required behavioral cases (integration, against the real API with fixtures):

1. **Cursor mid-sentence + no final chunk.** Last emitted chunk = `"the meeting is at three"` (model closed with a period). No final chunk is sent (release after silence). `Text after cursor = " before lunch"`. Stitched expected: `"the meeting is at three"` (period stripped by `finalizeForInsertion`).
2. **Cursor in empty field, normal session.** Final-chunk request is sent. `Text after cursor = ""`. Trailing period preserved.
3. **Cursor right after a period, `Text after cursor = " Next paragraph"`.** Model starts the first chunk with a capital letter. Final terminal punctuation preserved.
4. **Cursor right after a comma, `Text after cursor = ""`.** Model starts in lowercase. Final terminal punctuation preserved.
5. **Empty field, single short chunk "yes", `is_final=true`.** Verify chunk numbering doesn't break (chunk_1 is also the final).
6. **Cache hit.** Send 2 chunks in one session; verify `cachedContentTokenCount / promptTokenCount > 0.7` on chunk 2 — confirmation that prefix shape didn't break.

---

## Model version

Currently pinned to `gemini-3.1-flash-lite` (post-GA) in `GeminiClient.swift:15`. When upgrading to a newer model, verify response shape hasn't changed, and update `Models.swift` if Google adds new fields we want.
