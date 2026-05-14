# Dictionary module

Owns the data and logic behind two independent features that share the Dictionary tab:

1. **`User dictionary:` cache-prefix section** — comma-separated list of canonical spellings (brands, proper nouns, jargon) shipped to Gemini on every transcription request between `Category instruction:` (optional) and `Insertion target:`. Biases transcription toward the user's canonical forms without being a content pool (see system instruction's `# User dictionary` section). Section is **always present**, even when the dictionary is empty — body renders as `(empty)`.
2. **Auto-replacement pass** — user-defined `from → to` pairs applied to the final stitched transcript **between** `TextInjector.finalizeForInsertion` and `TextInjector.paste`. Pure client-side; never sent to Gemini.

See ADR-016 in `docs/decisions.md` for rationale.

Files:
- `DictionaryEntry.swift` — value types: `DictionaryEntry { id, word, source: .user|.auto, addedAt }`, `DictionaryReplacement { id, from, to, createdAt }`, `DictionarySnapshot { entries, replacements }`. The snapshot also exposes `promptEntries()` — what to ship in `User dictionary:` (user → auto, newest-first within each bucket).
- `DictionaryStore.swift` — actor wrapping `dictionary.json` in App Support. Atomic writes, corruption recovery (`.corrupt-<ts>` rename). Public API: snapshot, add/remove entries (user vs auto), add/update/remove replacement pairs.
- `DictionaryContext.swift` — frozen Sendable snapshot `{activeEntries, replacements}` that `AppState` hands to `RecordingSession.start(...)`. Captured once on the main actor and held for the session — keeps the cached-prefix section byte-stable chunk-to-chunk.
- `DictionaryHarvester.swift` — **pure function** (`harvest(transcript:context:existing:)`) that intersects the just-pasted transcript with the on-screen context the model saw at session start. No LLM round-trip, no API cost. Replaces the v1 `DictionaryExtractor` actor (ADR-016 v2).
- `TextReplacementEngine.swift` — pure function `apply(_:replacements:)`. Word-boundary regex match with auto-generated capitalized variant when `from` starts with a lowercase letter.

---

## Storage shape

Single JSON file at `~/Library/Application Support/NoType/dictionary.json`:

```jsonc
{
  "version": 1,
  "entries": [
    {"id": "...", "word": "NoType",    "source": "user", "addedAt": "..."},
    {"id": "...", "word": "Anthropic", "source": "auto", "addedAt": "..."}
  ],
  "replacements": [
    {"id": "...", "from": "то есть", "to": "т.е.", "createdAt": "..."}
  ]
}
```

- `entries` is one combined list — UI splits user / auto by `source`, prompt section concatenates user-first then auto.
- Words longer than `DictionarySnapshot.maxEntryLength` (30 chars) are rejected at every entry point — UI textfield, store mutators, harvester (`DictionaryHarvester.sanityMaxLength` mirrors the constant), and on-disk decoder. A hand-edited file can't bloat the prompt section.
- Replacements have no length cap — abbreviation expansions routinely exceed 30 chars.
- Case-insensitive dedup on both `word` (entries) and `from` (replacements). Adding the same brand in different casing collapses; promoting an existing `.auto` entry to `.user` via re-add is supported (sticky).

---

## Caps and invariants

- **Total entries cap: 100.** Trim removes oldest `.auto` first (`addedAt` ascending). User entries are sticky — never trimmed by cap logic.
- **Harvest skip rule: `userCount >= 100`.** When all 100 slots are taken by sticky user entries, the harvester can't write anything anyway, so `AppState.harvestDictionaryIfRoom` short-circuits before doing work. This is the only skip rule — short transcripts ARE processed (the old `< 30 chars` skip was a cost-saver for the LLM extractor; the algorithmic harvester is free).
- **Master toggle (`AppState.dictionaryEnabled`).** Persisted to `UserDefaults` under `notype.dictionaryEnabled`, defaults to `true` (absent key → enabled). When `false`:
  - `currentDictionaryContext()` ships `activeEntries: []` regardless of stored entries → `User dictionary:` prompt section renders `(empty)` (preserving the 8-part cache shape).
  - `harvestDictionaryIfRoom` short-circuits before tokenising the transcript — no `.auto` entries get added while the feature is off.
  - The toggle is **scoped to the entries panel only**. Replacement pairs are unaffected — `replacements` keeps flowing into `DictionaryContext` so client-side find/replace still runs at paste time.
  - The Dictionary tab stays fully editable while disabled (chips visually dimmed to 45 % opacity), so users can curate entries in advance.
- **30-char cap on entries**, enforced at the UI textfield (live), `DictionaryStore` mutators, `DictionaryHarvester` (`sanityMaxLength`), and on-disk decoder.
- **`DictionaryContext` is frozen at session start.** Edits to the Dictionary tab during a recording session do NOT reach the in-flight session. `RecordingSession` stores `replacementsFrozen` separately from `cachedContext.replacements` so a quick-release fallback to `ContextSnapshot.minimal(activeApp:)` still picks up the user's replacement pairs. The master toggle is also captured at session start through this same freeze (via `currentDictionaryContext()`'s read of `dictionaryEnabled`).

---

## Cache-prefix invariant

The `User dictionary:` section in every Gemini transcription request:

- Lives between `Category instruction:` (optional, position 2) and `Insertion target:` (position 4 in the full shape; 3 when no `User instruction:`).
- **Is always present** even when empty (body `(empty)`). Dropping it would change the prefix shape across sessions and break implicit caching for the rest of the prefix.
- **Body is monotonically newest-first within a session.** Inside one session the snapshot is frozen, so the section text is byte-stable across chunks — fully cache-friendly.
- **Cross-session: the section is NOT prefix-monotonic.** Different sessions may have different dictionary contents (because the user edited or because the harvester added words after a previous session). That's fine — cross-session sharing isn't a goal; we only need within-session caching to hit.

Pinned by `GeminiRequestBuilderTests`:
- `test_userDictionary_appearsAfterCategoryInstruction_beforeInsertionTarget`
- `test_userDictionary_emptyRendersEmptyBody_sectionStillPresent`
- `test_userDictionary_rendersCommaSeparated`
- `test_userDictionary_byteStable_betweenChunks_ofSameSession`
- `test_partOrderAndLabels_stableWithAndWithoutOCR` — the prefix array includes `"User dictionary:"` at index 3 in the full shape.

---

## Harvester algorithm (`DictionaryHarvester.harvest`)

Pure function, <10 ms on realistic sessions. **Transcript-driven** — context is only used to verify that a candidate phrase actually appears on screen, never to invent candidates or promote casing.

Pipeline:

1. **Sentence segmentation via `NLTokenizer(unit: .sentence)`.** Apple's tokenizer handles abbreviations (`т.е.`, `etc.`, `Inc.`) better than punctuation heuristics. Each sentence is then word-tokenized; the first word of each sentence is marked `isSentenceStart=true`.
2. **Word tokenization.** Maximal runs of letter / digit / `_` / `/` / `-`, optionally with internal `.` (between two letter-or-digit chars — `claude.md`, `react.dev`). A trailing period is dropped. Pure-binder runs (`___`) are discarded; pure-digit runs (`10`, `2024`) are KEPT so they can participate as **phrase boundaries** but never seed phrases on their own.
3. **Trigger detection (`isTrigger`)** — applied to TRANSCRIPT tokens (not canonical from context). A token is a trigger if it passes the shape filter:
   - **(a) Internal uppercase** — uppercase letter at position ≥ 1 (`iPhone`, `gRPC`, `iCloud`, `macOS`).
   - **(b) Contains digit AND at least one letter** (`h264`, `mp4`, `version1`). Pure-digit tokens are NOT triggers (`10`, `2024`).
   - **(c) Special binder** — `/`, `_`, `*`, `#`, `$`. Strong non-prose signal. Hyphen `-` and period `.` are NOT in this set (they're common in `что-то`, `т.е.`).
   - **(d) Dot + length ≥ 6 chars** — filename / domain-like (`claude.md`, `react.dev`).
   - **(e) First-letter cap, length ≥ `firstCapTierMinLength` (5), AND NOT sentence-start** — `Anthropic`, `Slack`, `Apple`, `Vasya`, `Microsoft`. Filters out short Russian/English chrome (`Так`, `Вот`, `Для`, `Auto`) and sentence-start words.
4. **±2 window per trigger.** For each trigger at position `i` within its sentence, the window is `[max(0, i-2)..min(n-1, i+2)]`. The harvester generates all sub-phrases `[a..b]` such that `leftWin ≤ a ≤ i ≤ b ≤ rightWin`.
5. **Sort candidates longest-first per trigger.** Try each in order, **first match wins** (matches the user's spec: "если находим, то сразу же заканчиваешь поиск и останавливаешься").
6. **Boundary filter (`hasInterestingSignal`).** Phrase first AND last tokens must look non-prose: have uppercase letter, contain a digit, contain a special binder, or be a long-dot token. This is what rejects `на Actions artifacts` (`на`/`artifacts` are prose) while keeping `iPhone 10` (`iPhone` cap + `10` digit) and `Вася Пупкин` (both first-cap).
7. **Verbatim context match** — case-insensitive, word-boundary via Unicode look-arounds (regular `\b` fails on tokens ending in `/` or `_`).
8. **Session substring dedup** — skip candidate if it's a contiguous sub-sequence of any phrase already saved this session. Stops the algorithm from descending to shorter sub-phrases of an already-covered span.
9. **Existing-dictionary dedup**:
   - Candidate is STRICTLY contained in an existing entry → skip (existing is more informative).
   - Candidate is EXACT match of an existing entry → **include** in the return list; the caller (`DictionaryStore.addAutoEntries`) refreshes the existing entry's `addedAt` timestamp so the FIFO trim treats it as fresh.
10. **Save with transcript casing.** Tokens are joined as they appear in the TRANSCRIPT. No context-driven case promotion (the user-reported `минуты → Минуты` regression came from the old design that pulled casing from context).
11. **Caps:** `maxCandidates = 5` per session; `sanityMaxLength = 30` chars; `minSingleTokenLength = 3` for 1-gram saves.

The harvester returns BOTH net-new phrases AND exact-existing matches; the caller distinguishes via membership in `existingLower` and calls add-or-refresh accordingly.

**Cross-language matrix.** The first-cap-mid-sentence tier is the part that depends on language semantics. The harvester uses Apple's `NLLanguageRecognizer` (zero-dep, built into macOS) on the transcript to detect noun-capitalizing languages and disable the tier for those automatically:

| Script family | Behaviour | Notes |
|---|---|---|
| Latin (EN/FR/IT/ES/PT/PL/…) | ✓ First-cap tier ON | `.!?` ends sentences. Spanish `¿¡` are walked through as non-boundary chars — preceded by a real sentence-ender or BOS, the next token still marks as sentence-start correctly. |
| Cyrillic (RU/UK/BG/SR/MK/…) | ✓ First-cap tier ON | Same punctuation conventions. The user-reported `Вот`/`Так`/`Для` noise rejects via the "sentence-start in both" filter. |
| Greek / Armenian / Georgian | ✓ First-cap tier ON | Latin-style punctuation. |
| **German** | ✓ First-cap tier **OFF** (auto-detected) | German capitalizes ALL nouns, not just proper nouns. `isNounCapitalizingLanguage(transcript)` returns `true` via `NLLanguageRecognizer.dominantLanguage == .german` and the tier is suppressed for that harvest call. German users get strict tier only — they lose unmarked brand names like `Anthropic`/`Slack` as auto-entries (addable manually via the textfield) but keep `iPhone`, `h264`, `Apple iPhone`, `Anthropic Inc` via internal-cap / digit / multi-word rules. |
| CJK (中文 / 日本語 / 한국어) | ✓ First-cap tier no-op | No upper/lower case at all → `isFirstCapPlainShape` always rejects the leading char. CJK tokens still flow through strict tier rules (b)/(c)/(d) — digits, binders, dot-domain. Newline + CJK fullwidth `。！？` are recognised as sentence-enders. |
| Arabic / Hebrew | ✓ First-cap tier no-op | No case. Same as CJK. |
| Hindi / Thai / Bengali / Tamil / … | ✓ First-cap tier no-op | No case. Same as CJK. |

**Why NLLanguageRecognizer over character heuristics.** Detecting German by the presence of `ß`/`ä`/`ö`/`ü` would miss the long tail: Swiss German never writes `ß`, modern post-reform Germany often skips it, and `ä`/`ö`/`ü` are shared with Swedish, Finnish, Turkish, Estonian. NLLanguageRecognizer's statistical model uses word frequency + grammatical markers (article–noun ratios, capitalization rate) and generalises across both the Latinised and umlaut-rich variants. It's also extensible: add `.luxembourgish` or `.dutch` (if a noun-cap edge case is reported) by appending to `nounCapitalizingLanguages: Set<NLLanguage>`.

**Adding a new noun-capitalizing language.** Edit `DictionaryHarvester.nounCapitalizingLanguages` (one line). The framework handles detection; no algorithm changes. Add a test in `DictionaryHarvesterTests` that the language classifies correctly + that the relevant common-noun pattern rejects under that language.

Trigger examples (applied to transcript tokens):
- `iPhone` / `gRPC` / `iCloud` / `macOS` / `MacBook` — internal upper → trigger
- `NASA` / `JSON` / `OAuth` — internal upper at index ≥ 1 → trigger
- `h264` / `mp4` / `version1` — has digit + letter → trigger
- `bin/python` / `generate_keys` / `#engineering` — special binder → trigger
- `claude.md` / `react.dev` / `app.notype` — dot + length ≥ 6 → trigger
- `Anthropic` / `Slack` / `Apple` / `Vasya` — first-cap, length ≥ 5, MUST be mid-sentence → trigger
- `Так` / `Вот` / `Для` — length < 5 → not a trigger
- `Auto` / `Tool` / `Phone` — length < 5 → not a trigger
- `Anthropic` at sentence-start → not a trigger (user pre-accepted this loss)
- `10` / `2024` / `12345` — pure digits, no letter → not a trigger (but can serve as phrase boundary)
- `что-то` / `state-of-the-art` — only hyphen, no other signal → not a trigger
- `т.е.` / `T.e` — short dot tokens → not a trigger
- `minutes` / `packages` / `framework` — lowercase prose → not a trigger (the new algorithm never promotes lowercase transcript tokens to capital canonical from context)

Multi-word save examples (transcript casing, phrase verified in context, boundaries pass `hasInterestingSignal`):
- transcript `купил iPhone 10 вчера`, context `Store: iPhone 10 Pro Max` → saves `iPhone 10` — 3-span `iPhone 10 вчера` rejected because `вчера` boundary is prose; 2-span first/last both pass and match context
- transcript `пиши Вася Пупкин завтра`, context `Recipient: Вася Пупкин` → saves `Вася Пупкин` — trigger `Пупкин` (length 6 ≥ 5, mid-sentence), 2-span match
- transcript `написал в Slack команде`, context `Tab: Slack channels` → saves `Slack` — 2-span `Slack команде` rejected (last `команде` is prose); 1-gram match
- transcript `проверить на Actions artifacts`, context `общий пул на Actions artifacts` → saves `Actions` — `на Actions artifacts` and `на Actions` rejected (`на`/`artifacts` are prose boundaries); falls back to 1-gram
- transcript `Вот купил новый`, context (whatever) → saves nothing — no trigger at all (`Вот` length 3, sentence-start)
- transcript `iPhone 10 сохраняется всё`, context same → saves `iPhone 10` — 3-span rejected (`сохраняется` prose tail); 2-span passes
- transcript `running iOS apps daily`, context `iOS market share` → saves `iOS` (transcript casing — note: if transcript said `ios` lowercase, it wouldn't be a trigger at all)
- transcript `вчера запустил Actions`, existing `["GitHub Actions"]` → saves nothing — `Actions` is strict subset of existing `GitHub Actions`, the longer entry already covers it
- transcript `вчера обсуждал Anthropic с командой`, existing `["Anthropic"]` → returns `["Anthropic"]` — exact match → caller refreshes timestamp (FIFO survives)

---

## Replacement matching contract

`TextReplacementEngine.apply(_:replacements:)`:

- **Word-boundary**: `\bfrom\b`. ICU-aware — Cyrillic, Greek, etc. work. `то есть → т.е.` does NOT match `кто есть кто`.
- **Auto-capitalized variant**: when `from` starts with a lowercase letter, an additional pair is auto-generated with the first character of both `from` AND `to` capitalized. So `то есть → т.е.` ALSO matches `То есть` and replaces it with `Т.е.`.
- **All-caps NOT auto-matched.** `ТО ЕСТЬ` stays untouched — the user must add an explicit pair if they need it.
- **No cascading within a pair.** `NSRegularExpression.stringByReplacingMatches` does one pass per pair. So `ML → machine learning` doesn't recursively match its own output for further substitutions.
- **Sequential between pairs.** Later pairs see earlier pairs' output. Documented behaviour — the user controls ordering via the order they create pairs.
- **Regex special characters in `from`** are escaped via `NSRegularExpression.escapedPattern`. Dots, brackets, etc. are treated literally.
- **Regex special characters in `to`** are escaped via `NSRegularExpression.escapedTemplate`. `$0..$9` and `\$` are NOT interpreted as capture references.

Pinned by `TextReplacementEngineTests`.

---

## Lifecycle

**Session start (`AppState.handleHotkeyPress`):**
1. `currentDictionaryContext()` snapshots `(promptEntries, replacements)` from the main-actor mirror.
2. Passed to `RecordingSession.start(apiKey:, instructions:, dictionary:)`. Session stores `replacementsFrozen` and copies `activeEntries` / `replacements` into `dictionaryEntries` parameters that go into the `contextTask`'s eventual `ContextSnapshot`.

**Session stop (`RecordingSession.stop`):**
1. After `finalizeForInsertion`, run `TextReplacementEngine.apply(finalRaw, replacements: replacementsFrozen)`.
2. Paste the post-replacement text.
3. History entry stores the post-replacement text — history is the source of truth for "what was inserted".

**Post-session harvest (`AppState.finalizeRecording` → `harvestDictionaryIfRoom`):**
1. After `StatsStore.record`, synchronously read `session.cachedContext` (`ContextSnapshot` captured at session start).
2. Skip if `userEntryCount >= 100` (no room).
3. Assemble `contextText` = AX tree formattedForPrompt + optional OCR formattedForPrompt + `insertionTarget.textBefore` + `insertionTarget.textAfter`.
4. Call `DictionaryHarvester.harvest(transcript:, context:, existing:)`.
5. Fire-and-forget `dictionaryStore.addAutoEntries(candidates)` → callback updates `applyDictionarySnapshot` (refreshes Dictionary tab in real time).

The whole harvest is client-side and synchronous on the main actor (the harvester itself is fast; only the disk write is dispatched to the store actor).

---

## UI surface

`NoType/UI/Dictionary/DictionaryView.swift`:

- Sticky header + scroll body, same layout as Instructions tab. Reuses `InstructionsPanel` for panel chrome (with its `trailing` slot now driving the dictionary panel's header controls).
- **Auto-replacement panel**: list of pair rows + add-row footer. Each row is `from → to` with an inline delete button on hover.
- **Dictionary panel**: counter `(N/100)` + add field with live 30-char cap + tag-cloud via local `FlowLayout` Layout protocol. Chips use `DSWordChip` (filled accent for `.user`, bordered neutral for `.auto`). Per-chip X-button on hover.
- **Panel header trailing controls**:
  - **Master toggle (`Toggle(.switch, controlSize: .mini)`)** flipping `appState.dictionaryEnabled`. Always visible. When off, the panel body fades to 45 % opacity but stays interactive — the user can still curate entries while the feature is paused.
  - **Two-stage `Clear all` button** (visible when `totalCount > 0`). Same label both stages. Stage 1 (auto entries exist) wipes only `.auto`; stage 2 (only `.user` left) styles the button destructively (`dangerFg` + `dangerSoft` hover fill) and wipes `.user` on click. No confirmation dialog — the destructive tint on stage 2 is the only safeguard. Hidden entirely when the dictionary is empty.
- **Full state**: when `userCount >= 100`, an in-panel hint explains the dictionary is full and auto-harvest can't add new words until the user removes some.

`DSWordChip` lives in `NoType/UI/DSComponents.swift` alongside the other DS primitives.

---

## Testing

Required tests:

- `NoTypeTests/DictionaryStoreTests.swift` — round-trip, FIFO trim over 100 with user-stickiness, case-insensitive dedup, length cap, corruption recovery, `promptEntries()` ordering.
- `NoTypeTests/TextReplacementEngineTests.swift` — word-boundary match, auto-capitalization variant, all-caps not matched, regex special chars escaped on both sides, idempotence, empty inputs.
- `NoTypeTests/DictionaryHarvesterTests.swift` — tokenization edges (trailing period vs internal period, binders, pure digits), shape filter (capital / mixed / all-caps / atypical-binder / lowercase rejection), single + multi-word matching with longest-match priority, case preservation from context, existing-dedup, single-letter rejection, sanity-length cap, empty input handling.
- `NoTypeTests/GeminiRequestBuilderTests.swift` — pins the position and labels of the `User dictionary:` section across the full-shape and minimum-shape prompt builds. **Any change here means the cache invariant changed → reviewer must bless it.**

---

## Known edge cases

- **A user who manually fills all 100 slots** never sees harvest. By design — `harvestDictionaryIfRoom` short-circuits, the UI shows the "Dictionary full" hint.
- **A replacement pair whose `to` contains another pair's `from`** will cascade (because pairs apply sequentially in creation order, not against a snapshot of the pre-pass text). Documented in `TextReplacementEngine.apply`'s doc-comment. Not considered a bug — the user controls creation order; documented predictability over "smart" non-cascading.
- **A history entry stores post-replacement text.** A user who later removes a replacement pair won't see the original (pre-replacement) version in history. History is "what was inserted", not "what Gemini produced". If we ever surface the raw Gemini output, we'd add a separate field — out of scope today.
- **Cross-session: the `User dictionary:` body changes** as the harvester adds entries. Within a session the body is frozen — implicit cache still hits chunk-to-chunk. Cross-session sharing isn't a goal.
- **Harvester false negatives on lowercase-only context**: if the on-screen context happens to show a proper noun in lowercase (rare but possible — broken AX label), the canonical form won't pass shape and the entry is silently dropped. Acceptable: the next session where context is correctly cased will pick it up.
