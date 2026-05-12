# Instructions module

Owns the data and logic behind two cached-prefix sections in every Gemini transcription request: **`User instruction:`** (global, user-edited textarea on the Instructions tab) and **`Category instruction:`** (per-`AppCategory`, with developer defaults and per-category user overrides). Also owns the **app classifier** that decides which `AppCategory` an unfamiliar app falls into.

See ADR-015 in `docs/decisions.md` for the rationale.

Files:
- `AppCategory.swift` — the 8-case enum (`messaging`, `email`, `social`, `notes`, `docs`, `code`, `search`, `uncategorized`) with default prompts, display labels, and the classifier-allowed subset.
- `AppCategoryAssignment.swift` — `Codable` record: `bundleID`, `category`, `confidence`, `classifiedAt`, `source` (`.auto` from the classifier, `.manual` from the UI move-to-category menu).
- `InstructionsStore.swift` — actor wrapping `instructions.json` in App Support. Atomic writes, corruption recovery via `.corrupt-…` rename. Mirrors the `HistoryStore` operational shape.
- `InstructionsContext.swift` — frozen Sendable snapshot of `{userInstruction, promptForCategory, cachedCategoryForBundle}` that `AppState` hands to each `RecordingSession.start(...)`. Captured once and immutable for the session's lifetime — that's what keeps the cached-prefix sections byte-stable chunk-to-chunk.
- `CategoryResolver.swift` — pure function that layers the AX-only `search` override on top of a stored category. Reads the system-wide focused element synchronously at session start.
- `AppCategorizer.swift` — actor that dedupes concurrent classify calls for the same bundle, calls into `GeminiClient.classifyApp(...)`, writes confident results to the store, and notifies AppState via a callback.

---

## Storage shape

Single JSON file at `~/Library/Application Support/NoType/instructions.json`:

```jsonc
{
  "version": 1,
  "userInstruction": "always sign off with 'Best,'",
  "categoryPromptOverrides": {
    "email": "...custom prompt the user typed in the Instructions tab..."
  },
  "categoryAssignments": {
    "com.apple.mail": {
      "bundleID": "com.apple.mail",
      "category": "email",
      "confidence": "high",
      "classifiedAt": "2026-05-11T10:23:00Z",
      "source": "auto"
    },
    "com.tinyspeck.slackmacgap": {
      "bundleID": "com.tinyspeck.slackmacgap",
      "category": "code",
      "confidence": "high",
      "classifiedAt": "2026-05-11T10:24:00Z",
      "source": "manual"
    }
  }
}
```

- `userInstruction` is trimmed on write; the empty string means "no instruction" and the prompt section is omitted entirely from the Gemini request.
- `categoryPromptOverrides` only carries categories the user has actually customized — every other category falls back to `AppCategory.defaultPrompt`. Setting an override to empty/whitespace removes it.
- `categoryAssignments` is the cache. Auto-classifications are subject to overwrite by later auto-classifications, but **manual** records are sticky — `upsertAutoAssignment` refuses to overwrite a `source: .manual` row. The user has to delete the row via the Instructions tab (which sends `removeAssignment`) before the categorizer can run for that bundle again.
- Categories are stored as their `rawValue` strings (`messaging`, `email`, …). Unknown keys in a forward-version file are silently dropped on decode rather than failing the whole document.
- ISO8601 date encoding drops sub-second precision. Tests that compare assignment records by value use whole-second `Date`s.

---

## Cache-prefix invariant

The two prompt sections live in the user-message `parts` of every Gemini transcription request. See `NoType/Gemini/CLAUDE.md` for the full 7-part shape.

Within one `RecordingSession`:

- `ContextSnapshot.userInstruction` is captured at session start from `InstructionsContext.userInstruction` and never re-read.
- `ContextSnapshot.categoryInstruction` is captured at session start from `InstructionsContext.promptForCategory(resolvedCategory)` and never re-read.
- `ContextSnapshot.category` is captured at session start (cached lookup + the AX `search` override) and never re-read.

This is **load-bearing for caching**. If a future change ever re-reads these mid-session (e.g. to pick up an edit the user made between chunks), the part count would shift between chunks of the same session and the implicit-cache discount would break. Don't do it.

---

## Category resolution at session start

Inside `RecordingSession.start`'s `contextTask`, after `InsertionTarget.capture()` returns:

```
stored        = instructions.cachedCategoryForBundle(bundleID) ?? .uncategorized
resolved      = CategoryResolver.resolveFromAX(stored: stored)
categoryInstr = instructions.promptForCategory(resolved)
```

`CategoryResolver.resolveFromAX`:
1. Reads `kAXFocusedUIElementAttribute` off `AXUIElementCreateSystemWide()`. No actor hops — runs inside the existing detached `contextTask`.
2. Pulls `role`, `subrole`, `identifier`, `title` into a `FocusedFieldSnapshot` (the testable, Sendable value type).
3. Returns `.search` iff any of:
   - `role == "AXSearchField"` or `subrole == "AXSearchField"`
   - `identifier` contains `search` / `address` / `url` (case-insensitive)
   - `title` contains `search` / `address` / `url` (case-insensitive)
4. Otherwise returns `stored` unchanged.

Tested in `NoTypeTests/CategoryResolverTests.swift` with synthetic `FocusedFieldSnapshot` values; the live AX read is not unit-tested.

A documented false positive: `identifier: "researchPanel"` triggers `.search` because the substring `search` matches. Pinned in `test_resolve_doesNotTrigger_onUnrelatedIdentifier` so the next contributor sees it and decides whether to tighten the needle list.

---

## Classifier flow

When `AppState.handleHotkeyPress` sees a bundle id with no cached assignment, it fires `AppCategorizer.classifyIfNeeded(bundleID:, displayName:, apiKey:)` as a fire-and-forget task. The current session uses `.uncategorized` (no `Category instruction:` part) for its transcription; the next session in the same app picks up the new category from the cache.

Inside the actor:

1. Sanity gate: empty bundle / empty key → skip.
2. Cache gate: `store.assignment(for: bundleID) != nil` → skip. Includes both `.auto` and `.manual` records.
3. Dedup gate: `inFlight.contains(bundleID)` → skip. The actor's serial queue plus the `inFlight: Set<String>` mean two concurrent calls for the same bundle compress into one Gemini round-trip.
4. Call `GeminiClient.classifyApp(displayName:bundleID:apiKey:)`. On error: log and return — next session retries.
5. `confidence == .low` → log and return without caching. Categorizer was honest; we retry.
6. `category == .uncategorized` → log and return without caching. Same reasoning.
7. Persist via `store.upsertAutoAssignment(...)` and fire the `onAssignmentChanged` callback so `AppState` updates its `@Observable` mirror.

The actor's `onAssignmentChanged` is a `@Sendable` closure set post-init by `AppState.wireAssignmentCallback()` — resolves the construction-order catch-22 between the two actors.

---

## UI surface

The Instructions tab (added to `MainTab`) lives in `NoType/UI/Instructions/`:

- `InstructionsView` — sticky header + global user-instruction textarea + categories list.
- `CategoryDetailView` — drill-in; editable category prompt with reset-to-default, apps list with a per-row menu (Move to category / Re-classify with AI / Remove from cache).
- `CategoryIconTile` — 32×32 tinted square + DS line glyph, used in both the list and detail header.
- `DSTextEditor` — multi-line editor wrapper that matches the DS surface (recessed `bgInset` fill, hairline border).

State management notes:

- All edits go through `AppState` methods (`updateUserInstruction`, `updateCategoryPrompt`, `resetCategoryPrompt`, `moveAppToCategory`, `removeAssignment`, `refreshAssignment`). The methods update the `@Observable` main-actor mirror optimistically and fire-and-forget a `Task` that persists via `InstructionsStore`.
- Drill-in uses local `@State selectedCategory: AppCategory?` rather than `NavigationStack` to match how the main window already structures itself (no Navigation in `MainWindowView` today).
- The `search` category's detail view shows an info card instead of an apps list — that category is AX-detected, never cached against a bundle.

---

## Testing

- `InstructionsStoreTests.swift` — round-trip, manual-vs-auto precedence, override clearing, corruption recovery.
- `AppCategorizerTests.swift` — JSON parsing (via `GeminiClient.parseClassifierResponse`), actor dedup of concurrent calls, low-confidence / uncategorized skip paths.
- `CategoryResolverTests.swift` — search-field AX-override matrix against synthetic `FocusedFieldSnapshot` values.

No UI tests yet — keep the smoke checks listed in the ADR-015 implementation plan.
