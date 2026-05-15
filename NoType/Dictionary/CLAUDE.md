# Dictionary module

Two independent features behind the Dictionary tab:

1. **`User dictionary:` cache-prefix section** — comma-separated canonical spellings shipped to Gemini on every transcription request (biases transcription).
2. **Auto-replacement pass** — user-defined `from → to` pairs applied to the final stitched transcript between `TextInjector.finalizeForInsertion` and `TextInjector.paste`. Pure client-side; never sent to Gemini.

## Files

- `DictionaryEntry.swift` — value types: `DictionaryEntry { id, word, source: .user|.auto, addedAt }`, `DictionaryReplacement { id, from, to, createdAt }`, `DictionarySnapshot { entries, replacements }`. Snapshot exposes `promptEntries()` (user → auto, newest-first per bucket).
- `DictionaryStore.swift` — `actor` wrapping `dictionary.json` in App Support. Atomic writes; corruption recovery via `.corrupt-<ts>` rename.
- `DictionaryContext.swift` — frozen `Sendable` snapshot `{activeEntries, replacements}` that `AppState` hands to `RecordingSession.start(...)`.
- `DictionaryHarvester.swift` — **pure function** `harvest(transcript:context:existing:)`. Replaces the v1 LLM extractor.
- `TextReplacementEngine.swift` — pure function `apply(_:replacements:)`.

## Invariants

1. **`User dictionary:` section is always present in the cache prefix** — body `(empty)` when no entries. Dropping → prefix-shape change → cache miss.
2. **Total entries cap = 100.** Trim removes oldest `.auto` first. User entries are sticky — never trimmed by cap logic.
3. **Harvest skip rule:** `userEntryCount >= 100`. This is the ONLY skip rule — short transcripts ARE processed.
4. **30-char cap on entries** enforced at every entry point — UI textfield, `DictionaryStore` mutators, `DictionaryHarvester.sanityMaxLength`, on-disk decoder.
5. **Case-insensitive dedup** on both `word` (entries) and `from` (replacements). Adding the same brand in different casing collapses.
6. **`DictionaryContext` is frozen at session start.** Edits during a recording session don't reach the in-flight session. `RecordingSession` stores `replacementsFrozen` separately from `cachedContext.replacements` so the quick-release fallback to `ContextSnapshot.minimal(activeApp:)` still applies pairs.
7. **Master toggle `appState.dictionaryEnabled`** (UserDefaults `notype.dictionaryEnabled`, default `true`). When `false`: prompt section renders `(empty)`; harvester short-circuits; replacement pairs still flow.
8. **Replacement length is NOT capped.** Only entries are (they ship in the cache prefix; replacements run client-side).

## Hard rules

- **Pinned by `GeminiRequestBuilderTests`:**
  - `test_userDictionary_appearsAfterCategoryInstruction_beforeInsertionTarget`
  - `test_userDictionary_emptyRendersEmptyBody_sectionStillPresent`
  - `test_userDictionary_rendersCommaSeparated`
  - `test_userDictionary_byteStable_betweenChunks_ofSameSession`
  - `test_partOrderAndLabels_stableWithAndWithoutOCR` — `User dictionary:` at index 3 in the full shape.
- **Harvester saves TRANSCRIPT casing, not context casing.** Don't change without addressing the `минуты → Минуты` regression class (proper nouns wrongly capitalized from context).
- **Replacement pairs cascade sequentially** in creation order (later pairs see earlier output). Documented; user controls ordering.
- **History stores post-replacement text.** Removing a replacement pair won't show the pre-replacement version in history.

## Harvester algorithm — quick reference

Pure function, <10 ms typical. Transcript-driven; context only verifies the candidate phrase appears on screen.

1. Sentence segmentation via `NLTokenizer(unit: .sentence)`.
2. Word tokenization — runs of letter / digit / `_` / `/` / `-`, with internal `.` allowed. Trailing period dropped.
3. Trigger detection: **(a)** internal uppercase, **(b)** digit AND letter, **(c)** special binder (`/`, `_`, `*`, `#`, `$`), **(d)** dot + length ≥ 6, **(e)** first-cap mid-sentence with length ≥ 5.
4. ±2 window per trigger; generate sub-phrases; **longest-first per trigger**, first match wins.
5. Boundary filter `hasInterestingSignal` — first AND last token must look non-prose.
6. Verbatim context match — case-insensitive, Unicode word-boundary.
7. Session substring dedup + existing-dictionary dedup.
8. Save with transcript casing. **Caps:** 5 candidates / session, 30 chars / entry, 1-gram needs length ≥ 3.

### Cross-language matrix

The first-cap mid-sentence tier (rule **(e)**) auto-disables for noun-capitalising languages via `NLLanguageRecognizer`:

| Script family | First-cap tier | Notes |
|---|---|---|
| Latin (EN/FR/IT/ES/PT/PL/…) | ✓ ON | `.!?` ends sentences. |
| Cyrillic (RU/UK/BG/SR/MK/…) | ✓ ON | Same punctuation conventions. |
| Greek / Armenian / Georgian | ✓ ON | Latin-style punctuation. |
| **German** | **OFF (auto)** | All nouns capitalised; tier suppressed via `nounCapitalizingLanguages`. |
| CJK / Arabic / Hebrew / Hindi / Thai / Bengali / Tamil | no-op | No case at all. Rules (b)/(c)/(d) still apply. |

**Adding a noun-capitalising language:** add to `DictionaryHarvester.nounCapitalizingLanguages` (one line) + a test that the language classifies correctly + that the relevant noun pattern rejects under it.

## Replacement matching contract

- **Word-boundary `\bfrom\b`** — ICU-aware so Cyrillic / Greek / etc. work.
- **Auto-capitalised variant** when `from` starts lowercase. All-caps NOT auto-matched.
- **Regex special chars in `from`** escaped via `NSRegularExpression.escapedPattern`. **In `to`** escaped via `escapedTemplate` (so `$0..$9` and `\$` are NOT interpreted as capture refs).

## Testing

- `NoTypeTests/DictionaryStoreTests.swift` — round-trip, FIFO trim with user-stickiness, case-insensitive dedup, length cap, corruption recovery, `promptEntries()` ordering.
- `NoTypeTests/TextReplacementEngineTests.swift` — word-boundary, auto-cap variant, all-caps not matched, regex escaping on both sides, idempotence, empty inputs.
- `NoTypeTests/DictionaryHarvesterTests.swift` — tokenisation edges, shape filter, longest-match priority, case preservation, existing-dedup, language-recognizer matrix.
- `NoTypeTests/GeminiRequestBuilderTests.swift` — pins the `User dictionary:` cache-prefix position + labels.

## Pointers

- Why dictionary (v1 LLM extractor → v2 algorithmic intersector) → `solutions/architecture-patterns/personal-dictionary-2026-05-15.md`.
- Cache-prefix shape → `NoType/Gemini/CLAUDE.md`.
- Harvester reads from AX + OCR context → `NoType/Context/CLAUDE.md`.
