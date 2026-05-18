---
title: Settings Screen — Implementation Progress
plan: docs/plans/2026-05-18-001-feat-settings-screen-plan.md
branch: feat/settings-screen
status: in-progress
last_updated: 2026-05-18
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
| U2. General — Login Items / Sleep prevention / Reset onboarding | §291-338 | ⏳ Pending | — | Depends on U1 (done). P2 resolved per user: skip-revalidation-if-unchanged for Reset-onboarding invalid-Keychain-key trap |
| U3. Shortcuts — hotkey binding picker / Recording mode / Cancel shortcut | §341-396 | ⏳ Pending | — | Depends on U1 (done). Hotkey invariant 2 weakening for Hold+Space is load-bearing — secondary `.defaultTap` Space-only CGEventTap |
| U4. Microphone & Audio — Core Audio HAL rewrite (R16 reframed) | §399-458 | ⏳ Pending | — | Depends on U1 (done). ~1-2 weeks of work. Characterization-first per execution note. Requires hardware smoke on AirPods + Music for primary success criterion |
| U6. API section — Gemini key Edit + windowed token stats | §524-578 | ⏳ Pending | — | Depends on U1 (done) **and U5 (done)** — both met, ready to start |
| U7. System — Output language / Delete all / Paste delay + cache-prefix integration | §584-646 | ⏳ Pending | — | Depends on U1 (done). Cache-prefix part-count change will break ≥5 `GeminiRequestBuilderTests` — test-first per execution note |
| U8. Updates — Check button + per-version skip via X chip | §650-707 | ⏳ Pending | — | Depends on U1 (done). Manual smoke against EdDSA-signed staged release before removing `Updates/CLAUDE.md` Hard rule |

---

## Recommended next session entry point

**U6 (API section — Gemini key Edit modal + windowed token stats panel).** Lowest-friction next unit because:
- All dependencies satisfied (U1 + U5 both shipped).
- Plan is concrete: 2 new files (`GeminiKeyRow.swift`, `TokenStatsPanel.swift`), small AppState delta.
- Consumes U5's `StatsSnapshot.tokenTotals(overLastDays:)` directly.
- No load-bearing prompt / schema changes (cache-prefix part-count untouched).

**Alternatives if a different unit makes sense:**
- **U2** if user wants quick functional wins (Theme picker / Login Items / Reset onboarding) before deeper work.
- **U3** if hotkey ergonomics are a felt pain (Hold+Space mode, custom cancel shortcut).
- **U7** if cache-prefix work feels timely (test-first overhead is bounded — the part-count change is one of the more contained schema changes in the plan).
- **U4** is the largest single unit; tackle when there's a multi-day window with hardware (AirPods + Music) available for the R16-reframed smoke.

---

## Decisions made during implementation

### U1 (session 2026-05-18)

- **No `userMode` UserDefaults flag shipped.** Plan §128 / Key Technical Decisions deferred SaaS-mode gating until SaaS actually exists. API section in `SettingsTabView` carries a `// TODO: when SaaS mode lands, gate this section on userMode` comment but renders unconditionally in v1.
- **`pendingTabSelection` consume helper extracted as `MainTab.consumePendingSelection(pending:current:)`** — pure function, testable in isolation, used by `MainWindowView.consumePendingTabSelection`. Original plan §270 inline-clear-then-apply expanded into a static helper so tests can pin the atomic clear-first-apply-second invariant without standing up a `Window` scene.
- **SwiftUI render tests deferred** — no snapshot-testing infrastructure in repo. `MainTabTests` covers the testable surface (enum membership/ordering/labels/icons + the pure consume helper). Visual fidelity verified via interactive smoke (user signed off 2026-05-18).
- **`DS.Font.title()` does not exist** — used `.system(size: 18, weight: .semibold)` for the section title, mirroring `HomeView.header` pattern.

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

3. **U7 cache-prefix part count change** (carryover from plan §470-472). `GeminiRequestBuilderTests` pins the current part count (6 minimum / 8 full); adding `User languages:` at position 4 will break ≥5 tests. Plan execution note already calls this out — start U7 by updating fixtures + adding new positioning tests FIRST, then modify `buildRequestBody` / `buildLiteRequestBody`.

4. **U2 SleepAssertion ownership in AppState** (plan §304 / §314). Single-ownership of `activeSleepAssertion: SleepAssertion?` on `AppState` (not on the value-type `RecordingSession`) is load-bearing — RecordingSession copies during partial-recovery would otherwise risk double-release of the IOKit handle. Honor this when implementing U2.

5. **U3 RecordingMode `.effective(stored:hotkey:)` pure helper** (plan §370). Stored UserDefaults value is preserved across hotkey rebinds; effective mode auto-downgrades to `.hold` when stored `.holdSpacebarLock` collides with a non-modifier hotkey. AppState's `handleHotkeyPress` must use **effective**, not stored, mode. Pinned by a new `RecordingModeEffectiveTests` matrix.

---

## Tests added across sessions

| Suite | Cases | Coverage |
|---|---|---|
| `MainTabTests` | 10 | enum membership/ordering (4th = Settings); per-case label + icon; consume-pending-selection pure helper (nil flag, non-nil flag, stale clear, idempotent re-call, pending == current) |
| `TokenUsageTests` | 11 | `.zero` identity; `+` componentwise / commutative / associative; mapping from JSON-decoded `UsageMetadata` (all fields, missing cached, fully empty, nil payload); Codable round-trip |
| `StatsStoreTests` (additions) | 7 | `test_healIfPreV4_preservesV3Duration` (test-first); single-session + multi-session token accumulation; empty-bundle day-only-bucket; persistence round-trip; windowed `tokenTotals` (last7 / last30 / all / empty / 400d ancient) |
| `RecordingSessionPartialRecoveryTests` (additions) | 1 | `SessionSummary.tokens` round-trip |

**Net:** 569 / 569 pass excluding live-API `PromptEvalTests`.

---

## Build hygiene applied each session

- After every Swift-source-modifying build: `rm -rf /Applications/NoType.app && cp -R $DD /Applications/NoType.app` (deploy dev build) → DerivedData NoType.app swept (`find ... -prune -exec rm -rf`).
- `mdfind` cross-check at session end: only `/Applications/NoType.app` should remain.
- No `build/export/` cleanup needed yet (release script not run during these sessions).

---

## Open P2 / scope items still to resolve

- **U2 Reset onboarding — invalid Keychain key trap** (plan §823). User resolved 2026-05-18: option (a) skip-revalidation-if-unchanged. Implement: wizard's API-key step skips the live `validateKey` call when the user hasn't edited the pre-filled value (format-only check passes). Add the chosen behavior to AE9 acceptance criteria when implementing U2.
