---
title: Settings Screen — Implementation Progress
plan: docs/plans/2026-05-18-001-feat-settings-screen-plan.md
branch: feat/settings-screen
status: in-progress
last_updated: 2026-05-18 (U7 shipped)
---

# Settings Screen — Implementation Progress

Companion to [`2026-05-18-001-feat-settings-screen-plan.md`](2026-05-18-001-feat-settings-screen-plan.md). Tracks what's shipped, what's still pending, decisions made during implementation, and "implementation-time unknowns" each session discovered. The plan itself stays untouched (ce-work convention — plan is a decision artifact, not an execution log).

Entry-point convention for follow-up sessions: pick the next pending unit in dependency order (see plan §218-240), read this file's "Decisions during implementation" + "Implementation-time unknowns" for context, then `/ce-work` against the plan file again.

---

## Status matrix

| Unit | Plan §  | Status | Commit | Notes |
|---|---|---|---|---|
| U1. Settings UI scaffold + sidebar tab + DS section primitives | §246-289 | ✅ Shipped | `511b941` | 4th sidebar tab, 5 empty section blocks, `DSSettingsSection` / `DSSettingsRow` primitives, popover gear restored, `pendingTabSelection` cross-window flag, dead `SettingsView.swift` deleted, 10 `MainTabTests` |
| U5. StatsStore v3→v4 + TokenUsage + per-session token recording | §462-520 | ✅ Shipped | `8610f8a` | Path (a) — new `*WithUsage` overloads alongside existing `transcribe*`. `healIfPreV4` purely additive (no field zeroing). 18 new tests (11 `TokenUsageTests` + 7 `StatsStoreTests` extensions). Carve-out doc extended for tokens |
| U2. General — Login Items / Sleep prevention / Reset onboarding | §291-338 | ✅ Shipped | _next commit_ | Theme picker / Open at login (SMAppService) / Prevent sleep (IOPMAssertion-RAII via `SleepAssertion`, AppState-owned) / Reset onboarding (confirmationDialog → `OnboardingState.resetWizard`). 12 new tests (4 SleepAssertion, 4 LoginItemController, 4 OnboardingState). P2 trap closed — existing resume-card path in `OnboardingAPIKeyStep` already skips `validateKey` when the pre-filled value is unchanged |
| U3. Shortcuts — hotkey binding picker / Recording mode / Cancel shortcut | §341-396 | ⏳ Pending | — | Depends on U1 (done). Hotkey invariant 2 weakening for Hold+Space is load-bearing — secondary `.defaultTap` Space-only CGEventTap |
| U4. Microphone & Audio — Core Audio HAL rewrite (R16 reframed) | §399-458 | ⏳ Pending | — | Depends on U1 (done). ~1-2 weeks of work. Characterization-first per execution note. Requires hardware smoke on AirPods + Music for primary success criterion |
| U6. API section — Gemini key Edit + windowed token stats | §524-578 | ✅ Shipped | _next commit_ | `GeminiKeyRow` (masked `AIzaSy••••••••` + Edit sheet → validate-then-save reusing existing `validateGeminiKey` + `updateAPIKey`) / `TokenStatsPanel` (Today/7d/30d/All × Input/Output/Cached/Cache hit rate, divide-by-zero → `—`). Section unconditional in v1; `// TODO: when SaaS mode lands…` comment retained. 18 new tests (9 `GeminiKeyRowTests` + 9 `TokenStatsPanelTests`). Body-leak invariant pinned by `test_errorBody_doesNotLeakIntoUILabel` |
| U7. System — Output language / Delete all + cache-prefix integration | §584-646 | ✅ Shipped | _next commit_ | New always-present cache-prefix section `User languages:` at position 4 (frozen at session start from `AppState.outputLanguages`, mirrors `User dictionary:` shape). Curated ~100-entry BCP-47 list bundled as `Settings/SupportedLanguages.json`. Sheet-based picker (search + multi-select + DSWordChip strip). `HistoryStore.deleteAll()` empties history only; stats untouched (cross-store test pins the carve-out). **Paste restore delay slider deliberately omitted from UI** — too technical; stays in `PasteSettings` with 150 ms default. System prompt enumerations extended in both full + lite paths; new `# User languages` subsections added with minimal prompt-master rubric (audio-wins, never-content-pool). 32 new tests (7 `GeminiRequestBuilderTests` userLanguages cases + extended fixtures, 11 `SupportedLanguagesTests`, 6 `OutputLanguagePickerTests`, 8 `HistoryStoreTests` cases) |
| U8. Updates — Check button + per-version skip via X chip | §650-707 | ⏳ Pending | — | Depends on U1 (done). Manual smoke against EdDSA-signed staged release before removing `Updates/CLAUDE.md` Hard rule |

---

## Recommended next session entry point

**U8 (Updates — Check button + per-version skip via X chip).** Recommended next because:
- Smallest remaining unit — Sparkle "Check now" button + per-version skip chip wired through the existing `UpdateController` / `UpdateUserDriver`.
- No hardware dependency; manual smoke against an EdDSA-signed staged release is the only gate before lifting the `Updates/CLAUDE.md` Hard rule.
- Same dependency profile as U6/U7 (just U1 — done).

**Alternatives if a different unit makes sense:**
- **U3** if hotkey ergonomics are a felt pain (Hold+Space mode, custom cancel shortcut). Recording-mode `.effective(stored:hotkey:)` helper from carryover item #5 lands here.
- **U4** is the largest single unit; tackle when there's a multi-day window with hardware (AirPods + Music) available for the R16-reframed smoke.

---

## Decisions made during implementation

### U1 (session 2026-05-18)

- **No `userMode` UserDefaults flag shipped.** Plan §128 / Key Technical Decisions deferred SaaS-mode gating until SaaS actually exists. API section in `SettingsTabView` carries a `// TODO: when SaaS mode lands, gate this section on userMode` comment but renders unconditionally in v1.
- **`pendingTabSelection` consume helper extracted as `MainTab.consumePendingSelection(pending:current:)`** — pure function, testable in isolation, used by `MainWindowView.consumePendingTabSelection`. Original plan §270 inline-clear-then-apply expanded into a static helper so tests can pin the atomic clear-first-apply-second invariant without standing up a `Window` scene.
- **SwiftUI render tests deferred** — no snapshot-testing infrastructure in repo. `MainTabTests` covers the testable surface (enum membership/ordering/labels/icons + the pure consume helper). Visual fidelity verified via interactive smoke (user signed off 2026-05-18).
- **`DS.Font.title()` does not exist** — used `.system(size: 18, weight: .semibold)` for the section title, mirroring `HomeView.header` pattern.

### U2 (session 2026-05-18)

- **`SleepAssertion` ownership lives on `AppState`, not `RecordingSession`.** `acquireSleepAssertionIfNeeded()` is called from `AppState.handleHotkeyPress` after a successful `session.start()` (not from `RecordingSession.start()` itself). Cleaner — keeps the IOKit handle on `@MainActor`, decouples RecordingSession from AppState, and there's no risk of double-release from session value-copies during partial-recovery flows. `releaseSleepAssertion()` is wired into the three end paths in AppState: `finalizeRecording` success arm, `finalizeRecording` catch-error arm, and `cancelRecording`. The CancellationError catch arm intentionally doesn't release because `cancelRecording` already did so synchronously when the user hit Esc.
- **P2 resolution required no new code in `OnboardingAPIKeyStep`.** The existing resume-card path at `OnboardingAPIKeyStep.continueTapped` (lines 311-315) already calls `onboarding.goNext()` without invoking `validateKey` when `!isEditing && savedKey != nil`. So the user clicks "Reset" → wizard reopens at welcome → walks to API-key step → sees the resume card (key pre-filled) → Continue → no live validation call → step advances. Trap from §823 was already closed by U1's keychain UX work; just confirmed by code reading.
- **`LoginItemController.refresh()` called from `SettingsTabView.onAppear`.** `SMAppService` has no KVO/publisher surface so we re-read on every Settings-tab appearance. Belt and braces: the controller also refreshes immediately after every `register`/`unregister` call inside `setEnabled(_:)`.
- **`SystemSettingsPane` not extended for Login Items.** Login Items uses a different deep-link scheme (`x-apple.systempreferences:com.apple.LoginItems-Settings.extension`, not `com.apple.preference.security?Privacy_*`). Pulling it into the existing enum would either bloat the case body (per-case base URL) or weaken the type signal ("this enum covers Privacy panes"). Inline string + `nonisolated static let` on `LoginItemController` is the smaller change, and the string is test-pinned in `LoginItemControllerTests`.
- **`SMAppService.Status.notFound` collapsed into `.notRegistered`** in the display-side `LoginItemStatus` enum. Both render as "Off" — the SDK distinction is internal classification only.

### U6 (session 2026-05-18)

- **Sheet attached to row body, not row trailing closure.** Plan execution note flagged a macOS `.sheet(...)`-inside-`ScrollView` quirk. `GeminiKeyRow.body` attaches the sheet to its own outermost view (the `DSSettingsRow` it wraps) — *not* inside the row's trailing closure where the Edit button lives. Verified visually: sheet opens cleanly without flicker / self-dismiss.
- **Pure-helper test surface.** Both new files expose the testable logic as `static` methods (`GeminiKeyRow.maskedDisplay`, `GeminiKeyRow.errorMessage`, `TokenStatsPanel.formatCacheHitRate`, `TokenStatsPanel.formatCount`, `TokenStatsRange.days`). The 18 new test cases run without standing up a SwiftUI render harness. Matches the U1 precedent (`MainTab.consumePendingSelection`).
- **Error translation reuses `GeminiError.errorDescription` as fallback** — that property already redacts the `body` field for every case (verified `GeminiClient.swift:30-42`), so `error.localizedDescription` is body-safe by construction. Only `.missingKey` and `.http(401|403)` get UI-specific overrides; everything else falls through to the body-redacted localised message.
- **`TokenStatsRange` chose Today/7d/30d/All over HomeRange's 7D/30D/90D/All.** Token usage moves fast — "today" is the most useful at-a-glance window, and "90D" is rarely interesting relative to "All". The `.days` mapping (`1 / 7 / 30 / nil`) and ordering are pinned by `TokenStatsPanelTests.test_allCases_orderingIsTodayLast7Last30All`.
- **No new AppState methods.** `validateGeminiKey` + `updateAPIKey` + `currentAPIKey` + `statsSummary` were all already on AppState from earlier units (U2 keychain UX work / U5 stats wiring); U6 is a pure UI consumer.

### U7 (session 2026-05-18)

- **Cache-prefix part-count change shipped clean.** `GeminiRequestBuilderTests` had 5 part-count assertions to update (minimum 6→7, full 8→9, lite minimum 4→5, lite full 6→7, JSON-encoding 9→10). Test-first per execution note: extended `ctx`/`fullCtx` fixtures with `userLanguages: [String] = []` parameter, rewrote part-count assertions, added 7 new positioning tests, all failed → then modified `buildRequestBody` + `buildLiteRequestBody` to insert `User languages:` part at position 4 → all 635 tests pass.
- **`userLanguages` sourcing does NOT route through `InstructionsContext`.** Mirrors the plan §612 decision: `InstructionsContext` is scoped to Instructions-module concerns. Instead `RecordingSession.start(...)` gained a `userLanguages: [String]` parameter that AppState reads from `appState.outputLanguages` as a frozen local constant right before calling `start`. Same sourcing pattern as `DictionaryContext.replacements`. Stored on the session as `userLanguagesFrozen` so the lite-path `buildLiteSnapshot` can synchronously assemble a context.
- **SupportedLanguages bundled as a plain JSON resource.** `NoType/Settings/SupportedLanguages.json` — 102 curated BCP-47 entries (Gemini-supported common subset) with `{code, name (native), englishName}`. `xcodebuild` auto-classified it as a bundle resource via the existing `path: NoType` sources globbing — no `project.yml` edit needed. Verified at `Contents/Resources/SupportedLanguages.json` (7.2 KB) post-build.
- **Sheet-based picker over inline ScrollView.** Plan §608 suggested "ScrollView containing TextField + filtered LazyVStack". Building inline would nest a second ScrollView inside the SettingsTabView's outer one — vertical drag gestures fight. Sheet gives the language list its own scroll surface. Selected chips render in two places (collapsed row under "Output language" in the section + at the top of the sheet) so the user always sees their selection.
- **Saved-but-not-in-bundle codes survive.** `OutputLanguagePicker.displayChips(for:)` falls back to rendering the bare BCP-47 code when `SupportedLanguages.lookup` misses — covers future trims of `SupportedLanguages.json` so saved codes don't silently vanish from the user's selection. Pinned by `OutputLanguagePickerTests.test_displayChips_unknownCodeFallsBackToBareCode` + subtitle counterpart.
- **`HistoryStore.deleteAll` always writes** (even when in-memory state is already empty) so the on-disk file reflects the wipe. Avoids the "user clicks Delete all on an empty history → next launch shows yesterday's transcripts because a crash dropped them between memory and disk" failure mode.
- **Stats-cross-store test added.** `test_deleteAll_doesNotTouchStatsFile` writes a raw `stats.json` sentinel next to `history.json` and asserts byte-equality after `deleteAll`. Pins the AE7 carve-out at the store-layer boundary without dragging `StatsStore` into the test setup.
- **Confirmation dialog wording names `token usage` explicitly.** Per plan §618 — users who inspect `stats.json` post-deletion shouldn't be surprised that per-day token aggregates remain.
- **System prompt enumerations + `# User languages` subsections added** (full + lite). Minimal prompt-master rubric applied inline: enumeration extension (universal "never echo context" rule covers the new section), short subsection (audio-wins, "(empty)" → ignore). `test_systemPrompts_pinAntiCompletionClause` still passes — anchor phrases unchanged.
- **No new `AppState` API surface for `outputLanguages`.** Same `var outputLanguages: [String] { didSet { UserDefaults… } }` pattern as `preventSleepDuringRecording` (U2 precedent). UserDefaults backing uses plist `[String]` directly via `array(forKey:) as? [String] ?? []`. The picker binds straight through `@Bindable var appState = appState`.
- **Paste restore delay deliberately omitted from the System section UI.** Plan §584 / §641-642 specified exposing it as a 50–500 ms slider, but on visual review the slider read as too technical for the typical user (Slack/Discord/Terminal all work fine on the 150 ms default). The `PasteSettings.restoreDelayMs` getter/setter stays in code — `TextInjector` still reads it on every paste — so a support recipe of "bump UserDefaults key `notype.pasteRestoreDelayMs` to 200–250 ms" remains available for the rare "wrong text pasted" report. R25 closes without the slider; `TextInjector` behaviour is unchanged.

### U5 (session 2026-05-18)

- **Path (a) chosen** (plan §473 recommended). Existing `transcribe / transcribeBatch / transcribeShort` keep `String` returns as backwards-compat shims; new `*WithUsage` overloads return `(text, tokens)` tuples. Private `sendRequest` / `performOnce` return types changed once, shared by both surfaces. PromptEvalHarness untouched (reads `lastUsage` separately — still populated).
- **`SessionSummary.tokens` over `ChunkResponse.tokens`** — Gemini bills per-response, and a batched response's `usageMetadata` doesn't split cleanly across chunks. Carrying tokens at session-summary granularity matches the billing model exactly and removes the synthesise-per-chunk guesswork the alternative would require.
- **Failed (recoverable) Gemini calls contribute `.zero` to `sessionTokens` by construction** — the `*WithUsage` overload only returns on the success path; recoverable failures hit the `catch` block that appends a `text: nil` `ChunkResponse` and never touches `sessionTokens`. Net: retried-then-succeeded calls contribute only the final successful attempt's usage; failed-then-given-up chunks contribute nothing.
- **`healIfPreV4` purely additive** (plan §491). Pinned by test-first `test_healIfPreV4_preservesV3Duration` BEFORE bumping `currentVersion = 4`. Existing `test_summary_healsAsymmetricV2DurationOnFirstRead` updated to expect v4 post-heal.

---

## Implementation-time unknowns (carry forward)

Items the implementation surfaced that need attention in the relevant follow-up unit:

1. **GeminiClient mock infrastructure** (deferred from U5). The plan's §483 `GeminiClientTokenAggregationTests` (sum across batched-call chunks + retries within one chunk) and `RecordingSessionTokenTests` (session-level aggregation in partial-recovery scenarios — failed chunks contribute 0) require a mock `URLSession` (GeminiClient is an actor, no DI for the network layer) and a way to drive `RecordingSession` without a real `AudioRecorder` + `SileroVAD`. **Precedent set by existing `RecordingSessionPartialRecoveryTests`** which explicitly defers higher-level scenarios for the same reason. **Action:** plan a small test-infrastructure pass (mock `URLProtocol` for GeminiClient; lightweight `RecordingSession` test harness) before any unit that needs hard-mocked transcribe behavior. Not blocking U6/U7/U8.

2. **PromptEvalTests flakiness** (observed during U5 full test run). `test_longMonologueEN_full` + `test_silenceOnly_full` failed against Gemini 3.1 Flash-Lite — model output variance (numeric formatting, silence-only hallucination). **Not caused by U5** (no prompt content modified; verified by full test run with `-skip-testing:NoTypeTests/PromptEvalTests` → 569 / 569 pass). Flakiness is pre-existing. **Action:** revisit if it gets worse or if Gemini behavior shifts; consider adding `XCTSkip` semantics or moving these out of the default `xcodebuild test` invocation.

3. ~~**U7 cache-prefix part count change** (carryover from plan §470-472).~~ **Closed by U7 (this session).** Cache prefix is now 7 minimum / 9 full (full path) and 5 minimum / 7 full (lite path). `User languages:` lives at position 4 with body `(empty)` when no languages picked.

4. ~~**U2 SleepAssertion ownership in AppState** (plan §304 / §314).~~ **Closed by U2 (this session).** `AppState.activeSleepAssertion` is `@MainActor`-isolated single-owner; acquire/release wired into the three session-end paths. No partial-recovery double-release risk.

5. **U3 RecordingMode `.effective(stored:hotkey:)` pure helper** (plan §370). Stored UserDefaults value is preserved across hotkey rebinds; effective mode auto-downgrades to `.hold` when stored `.holdSpacebarLock` collides with a non-modifier hotkey. AppState's `handleHotkeyPress` must use **effective**, not stored, mode. Pinned by a new `RecordingModeEffectiveTests` matrix.

---

## Tests added across sessions

| Suite | Cases | Coverage |
|---|---|---|
| `MainTabTests` | 10 | enum membership/ordering (4th = Settings); per-case label + icon; consume-pending-selection pure helper (nil flag, non-nil flag, stale clear, idempotent re-call, pending == current) |
| `TokenUsageTests` | 11 | `.zero` identity; `+` componentwise / commutative / associative; mapping from JSON-decoded `UsageMetadata` (all fields, missing cached, fully empty, nil payload); Codable round-trip |
| `StatsStoreTests` (additions) | 7 | `test_healIfPreV4_preservesV3Duration` (test-first); single-session + multi-session token accumulation; empty-bundle day-only-bucket; persistence round-trip; windowed `tokenTotals` (last7 / last30 / all / empty / 400d ancient) |
| `RecordingSessionPartialRecoveryTests` (additions) | 1 | `SessionSummary.tokens` round-trip |
| `SleepAssertionTests` | 4 | init acquires non-zero IOPMAssertion handle; `release()` flips `isReleased` flag; `release()` idempotent; `deinit` safety net works for callers who forget |
| `LoginItemControllerTests` | 4 | `SMAppService.Status` → `LoginItemStatus` mapping (incl. `.notFound` → `.notRegistered` collapse); `isEnabled` / `requiresApproval` predicates; deep-link URL string pinned |
| `OnboardingStateTests` | 4 | `resetWizard` clears all three onboarding keys; preserves hotkey binding + selected mic UID; idempotent on cleared defaults; instance `currentStep` returns to `.welcome` |
| `GeminiKeyRowTests` | 9 | Mask format (long key `AIzaSy` prefix + 8 dots, short key tolerated, empty key dot-only); error translation table (`.missingKey` → "Invalid key — check format"; `.http(401)` / `.http(403)` → "Authentication failed (\(s))"; other `.http` falls back to body-redacted `errorDescription`; `URLError.notConnectedToInternet` / `.timedOut` → friendly copy; generic `LocalizedError` → its own description); body-leak invariant pinned with `secret-project-id-12345` sentinel never appearing in the rendered string |
| `TokenStatsPanelTests` | 9 | Range → days mapping (today=1 / last7=7 / last30=30 / all=nil); `allCases` ordering pinned (Today/7d/30d/All); cache hit rate format (divide-by-zero → "—", 300/1300 → "23%", 0/500 → "100%", 500/0 → "0%", 1/1 → "50%"); end-to-end against synthetic `StatsSnapshot` (today bucket vs 3-days-ago; 400-days-ago contributes to `.all` lifetime) |
| `GeminiRequestBuilderTests` (additions) | 7 | New `User languages:` cache-prefix section pinned: appears at position 4 (after Category instruction, before User dictionary); empty body renders as `(empty)`, section never dropped; single code emits no trailing comma; multi-language renders comma-separated; CJK + Thai BCP-47 codes round-trip via UTF-8; byte-stable across chunks of one session; appears in lite path at the same position |
| `SupportedLanguagesTests` | 11 | Bundle decode succeeds with ≥80 entries; common lookups (`en`/`ru`/`zh`/`ja`) resolve to expected English names; codes are unique; `byCode` index covers `all`; `filter` empty / whitespace query returns all; case-insensitive english-name + code match; native-script needle ("Русский") matches; non-existent needle returns empty |
| `OutputLanguagePickerTests` | 6 | `subtitle(for:)` empty / non-empty / unknown-code paths; `displayChips(for:)` resolves known codes to native names, preserves order, falls back to bare code for unknown codes (covers future SupportedLanguages.json trims) |
| `HistoryStoreTests` (new file) | 8 | Round-trip across instances; FIFO eviction at the 10-entry boundary; `remove(id:)` drops target / no-ops for missing id; `deleteAll` empties + persists across instances + is idempotent; cross-store contract pinned — `deleteAll` does not touch a sibling `stats.json` (AE7 carve-out boundary) |

**Net:** 635 / 635 pass excluding live-API `PromptEvalTests`.

---

## Build hygiene applied each session

- After every Swift-source-modifying build: `rm -rf /Applications/NoType.app && cp -R $DD /Applications/NoType.app` (deploy dev build) → DerivedData NoType.app swept (`find ... -prune -exec rm -rf`).
- `mdfind` cross-check at session end: only `/Applications/NoType.app` should remain.
- No `build/export/` cleanup needed yet (release script not run during these sessions).

---

## Open P2 / scope items still to resolve

_(All P2 items from the original review walkthrough are now closed — see status matrix above for what shipped.)_
