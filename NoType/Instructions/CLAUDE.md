# Instructions module

Owns two cached-prefix sections (`User instruction:`, `Category instruction:`) plus the **app classifier** that decides which `AppCategory` an unfamiliar app falls into.

## Files

- `AppCategory.swift` — 8-case enum (`messaging`, `email`, `social`, `notes`, `docs`, `code`, `search`, `uncategorized`) with default prompts + display labels + classifier-allowed subset.
- `AppCategoryAssignment.swift` — `Codable` record: `bundleID`, `category`, `confidence`, `classifiedAt`, `source` (`.auto` / `.manual`).
- `InstructionsStore.swift` — `actor` wrapping `instructions.json` in App Support. Atomic writes; corruption recovery via `.corrupt-<ts>` rename.
- `InstructionsContext.swift` — frozen `Sendable` snapshot `{userInstruction, promptForCategory, cachedCategoryForBundle}` that `AppState` hands to each `RecordingSession.start(...)`.
- `CategoryResolver.swift` — pure function that layers the AX-only `search` override on top of a stored category. Sync read at session start.
- `AppCategorizer.swift` — `actor` that dedupes concurrent classify calls for a bundle, calls into `GeminiClient.classifyApp(...)`, writes confident results, notifies `AppState` via callback.

## Invariants

1. **`ContextSnapshot.userInstruction` / `categoryInstruction` / `category` are captured at session start and never re-read.** Re-reading mid-session would shift part count between chunks and break implicit caching. Load-bearing — don't change.
2. **Manual category assignments are sticky.** `InstructionsStore.upsertAutoAssignment` refuses to overwrite a `source: .manual` row. User must explicitly call `removeAssignment` (via the Instructions tab "Re-classify with AI" menu item) before a fresh classify can run.
3. **`search` is AX-driven, not classifier-driven.** `CategoryResolver.resolveFromAX` at session start; classifier never returns `.search` (it's not in the classifier-allowed subset).
4. **Low-confidence / `.uncategorized` classifier outputs are NOT cached.** Retry on the next session — keeps the cache honest at the cost of occasionally re-charging for the call.
5. **`AppCategorizer` dedupes concurrent classify calls per bundleID** via `inFlight: Set<String>` inside the actor. Two concurrent calls for the same bundle compress into one Gemini round-trip.
6. **Empty `userInstruction` omits the section entirely** from the Gemini request. Empty `categoryInstruction` (nil — typical for `.uncategorized`) likewise omits.

## Hard rules

- **Don't read live AX values mid-session** for any of the three frozen fields (`userInstruction`, `categoryInstruction`, `category`). They were captured into `ContextSnapshot` for a reason.
- **Classifier input deliberately excludes window titles** (v1 — PII leak risk). Don't add a window-title field without prepending `SecureFieldMasker.scrubContent` in the same change.
- **Empty / whitespace `categoryPromptOverrides` are removed**, not stored — setting an override to empty restores the default.
- **`AppCategorizer.onAssignmentChanged` is a `@Sendable` closure set post-init** by `AppState.wireAssignmentCallback()`. It resolves the construction-order catch-22 between the two actors — don't try to inject it via initializer.

## Category resolution at session start

```
stored        = instructions.cachedCategoryForBundle(bundleID) ?? .uncategorized
resolved      = CategoryResolver.resolveFromAX(stored: stored)
categoryInstr = instructions.promptForCategory(resolved)
```

`CategoryResolver.resolveFromAX` returns `.search` iff:

- `role == "AXSearchField"` or `subrole == "AXSearchField"`, OR
- `identifier` contains `search` / `address` / `url` (case-insensitive), OR
- `title` contains `search` / `address` / `url` (case-insensitive).

Otherwise returns `stored` unchanged. Documented false positive: `identifier: "researchPanel"` triggers `.search` (substring match). Pinned in `test_resolve_doesNotTrigger_onUnrelatedIdentifier` — tighten the needle list only when reported as a real issue.

## Classifier flow (`AppCategorizer.classifyIfNeeded`)

1. Sanity gate: empty bundle / empty key → skip.
2. Cache gate: `store.assignment(for: bundleID) != nil` → skip (both `.auto` and `.manual`).
3. Dedup gate: `inFlight.contains(bundleID)` → skip.
4. Call `GeminiClient.classifyApp(displayName:bundleID:apiKey:)`. Error → log + return (next session retries).
5. `confidence == .low` → log + return without caching.
6. `category == .uncategorized` → log + return without caching.
7. Persist via `store.upsertAutoAssignment(...)` + fire `onAssignmentChanged` callback so `AppState` updates its `@Observable` mirror.

## Testing

- `NoTypeTests/InstructionsStoreTests.swift` — round-trip, manual-vs-auto precedence, override clearing, corruption recovery.
- `NoTypeTests/AppCategorizerTests.swift` — JSON parsing (via `GeminiClient.parseClassifierResponse`), actor dedup of concurrent calls, low-confidence / `.uncategorized` skip paths.
- `NoTypeTests/CategoryResolverTests.swift` — search-field AX-override matrix against synthetic `FocusedFieldSnapshot` values.

## Pointers

- Why per-app categorization + instructions in the cache prefix → `solutions/architecture-patterns/per-app-categorization-instructions-2026-05-15.md`.
- Cache-prefix shape → `NoType/Gemini/CLAUDE.md`.
- `User dictionary:` lives alongside `Category instruction:` in the cache prefix → `NoType/Dictionary/CLAUDE.md`.
