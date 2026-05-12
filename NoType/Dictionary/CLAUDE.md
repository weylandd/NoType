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
- **30-char cap on entries**, enforced at the UI textfield (live), `DictionaryStore` mutators, `DictionaryHarvester` (`sanityMaxLength`), and on-disk decoder.
- **`DictionaryContext` is frozen at session start.** Edits to the Dictionary tab during a recording session do NOT reach the in-flight session. `RecordingSession` stores `replacementsFrozen` separately from `cachedContext.replacements` so a quick-release fallback to `ContextSnapshot.minimal(activeApp:)` still picks up the user's replacement pairs.

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

Pure function, ~150 LOC, <10 ms on realistic sessions. Pipeline:

1. **Tokenize transcript.** Maximal runs of letter / digit / `_` / `/` / `-`, optionally with internal `.` (period between two letter-or-digit chars — for `claude.md`, `react.dev`). A trailing period is dropped (sentence end). Tokens that contain no letter are discarded (pure-digit, pure-binder).
2. **For each token position**, try increasingly long multi-word spans (3 → 2 → 1).
3. **For each span**, search the context string (case-insensitive, word-boundary via look-around — `\b` doesn't work for tokens ending in `/` or `_`). If found, capture the **context's casing** as canonical.
4. **Shape filter on canonical form** (not on transcript form): keep when canonical starts with uppercase, has any internal uppercase, or contains an atypical-text binder (`.`, `_`, `/`, `-`). This is what lets a lowercase transcript token `anthropic` save as canonical `Anthropic` from the on-screen text.
5. **Longest-match wins.** If 3-span matches, consume 3 positions; don't double-save the 1-spans inside it.
6. **Dedup case-insensitive** against `existing` (current dictionary entries) and against candidates already saved this session.
7. **Caps:** `maxCandidates = 5` per session; `sanityMaxLength = 30` chars per entry.

Shape filter examples:
- `Anthropic` (capital first) → pass
- `iOS` / `gRPC` (mixed case) → pass
- `NASA` (all caps) → pass
- `claude.md` / `bin/python` / `_priv` / `state-of-the-art` (atypical binders) → pass
- `hello` / `send` / `inbox` (lowercase plain word) → reject (this is what filters out UI chrome)
- `12345` (pure digits) → reject (no letters)

Multi-word matching examples:
- transcript `пиши вася пупкин завтра`, context `Recipient: Вася Пупкин` → saves `Вася Пупкин`
- transcript `check GitHub releases page`, context `Tab: GitHub releases` → saves `GitHub releases`
- transcript `browsing GitHub features today`, context `Window: GitHub home` → 2-span `GitHub features` not in context, falls back to 1-span `GitHub`
- transcript `shipping to anthropic`, context `Slack: Anthropic Inc` → 1-span match, saves `Anthropic` (case from context)

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

- Sticky header + scroll body, same layout as Instructions tab. Reuses `InstructionsPanel` for panel chrome.
- **Auto-replacement panel**: list of pair rows + add-row footer. Each row is `from → to` with an inline delete button on hover.
- **Dictionary panel**: counter `(N/100)` + add field with live 30-char cap + tag-cloud via local `FlowLayout` Layout protocol. Chips use `DSWordChip` (filled accent for `.user`, bordered neutral for `.auto`). Per-chip X-button on hover.
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
