---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
title: Code-Review Remediation - Plan
type: fix
date: 2026-07-10
branch_reviewed: fix/release-manual-codesign-archive
head_sha: 9175cb1
---

# Code-Review Remediation - Plan

## Goal Capsule

- **Objective:** Land the verified-real findings from two external LLM reviews of NoType (`9175cb1`) as a sequence of PR-sized fixes, reconciled against a fresh code-level verification pass.
- **Authority:** @kopachev owns product decisions (OQ1–OQ4). The Product Contract is fixed; implementation choices are the implementer's within it.
- **Stop conditions:** each phase (PR) is done when its units pass their test scenarios and the Verification Contract gates. Product-behavior open questions (OQ1, OQ2, OQ3) do **not** block any unit below — the units that touch them fix only the mechanical/agreed part.
- **Execution profile:** many small, independent commits grouped into 7 PRs. Each PR branches from `origin/main` (per repo git-flow), except PR-C (release) which may branch from the current release branch.
- **Product Contract preservation:** the requirements-only finding registry was restructured into R-IDs and Implementation Units; no product scope changed. Verified false positives were removed from scope (see Scope Boundaries).

---

## Product Contract

### Summary

Two independent reviews plus a verification pass produced a de-duplicated backlog: one user-visible functional bug (text replacements), two data-loss/side-effect races in the recording path, a session-orphan that leaves the mic hot, a cluster of AX/OCR redaction gaps on the security boundary, false onboarding privacy copy, several release-pipeline defects, and doc/dead-code drift. This plan turns that backlog into implementation-ready units. No critical/high-severity defect exists; the branch's manual-codesign change is correct and unaffected.

### Problem Frame

NoType is a non-sandboxed macOS menu-bar dictation app with system-wide Accessibility, microphone, screen-capture, Keychain, and update-signing boundaries. The reviews found that (a) documented invariants and their code have drifted in a handful of load-bearing places (lite-path cardinality, cancel ordering, title scrubbing), (b) the onboarding consent copy describes a local-only architecture the app does not have, and (c) the release pipeline has ordering and supply-chain gaps. Each is individually bounded; together they are the difference between "ships" and "ships cleanly."

### Requirements

**Recording & session correctness**
- R1. A queued multi-chunk final batch must transcribe every chunk it marks as covered — the user's final words are never silently dropped.
- R2. After the cancel key during `.sending`, the transcript is never pasted and never written to history.
- R3. A cancelled session's VAD work never pollutes the shared Silero actor state used by the next session.
- R4. Revoking Accessibility mid-recording unwinds the active session (mic released, assertions dropped), not just the hotkey tap.

**Dictionary**
- R5. Replacement pairs whose `from` starts or ends with punctuation (`т.е.`, `e.g.`, `.com`, `c#`) actually replace.
- R6. The harvester saves the clean domain term, not a sentence-start chrome word as the phrase head.
- R7. Editing a replacement pair cannot create two pairs with case-insensitively equal `from`.

**Privacy & security boundary**
- R8. AX node titles and window titles pass through `SecureFieldMasker.scrubContent` before reaching Gemini.
- R9. `InsertionTarget.captureSync` enforces the same secure-field skip set as the AX walker (role, subrole, roleDescription, identifier tokens, sensitive sheet).
- R10. A secret straddling the cursor is scrubbed (the before/after halves are not scrubbed in isolation).
- R11. Standard-base64 secrets (`+ / =`) are redacted by the content-scrub backstop.
- R12. The full-screen AX walk uses no force-casts on CF/AX values: type-guarded sites align to the no-force-unwrap convention, and any genuinely unguarded site is hardened against an unexpected CFType.
- R13. Onboarding permission/key copy accurately describes cloud transcription, transient on-disk chunks, the key being sent to Google, and the open-apps AX scope.

**Release & CI**
- R14. The CI version gate accepts prerelease tags (`vX.Y.Z-rcN`) and rejects branch-ref dispatch with a clear message.
- R15. The appcast is never published before its release asset exists; tag-push failures are not swallowed.
- R16. Release supply-chain is reproducible and pinned: committed SwiftPM lockfile, SHA-pinned secrets-handling actions, checksum-verified `sign_update`, and per-version release notes.

**Runtime polish**
- R17. AAC chunk encoding does not run on the main actor.
- R18. Clipboard restore does not overwrite a copy the user made during the restore delay.
- R19. Key validation cannot advance the onboarding wizard after the user navigates Back.
- R20. `MicProbe` releases the mic even if `.onDisappear` never fires.
- R21. Confirmed low-severity robustness gaps are closed or explicitly tech-debted (stale update-cancellation, dead error state, classifier retry comment).
- R22. The first-press Screen Recording prompt is suppressed when the OCR fallback toggle is off.

**Documentation**
- R23. Root and module docs match the shipped code (Core Audio HAL, keychain migration closed, stats wiring), and dead code / stale comments are removed.

### Scope Boundaries

**In scope:** every requirement R1–R23 above.

**Dropped — verified false positives / intentional (do not re-raise):**
- Signing designated requirement (`signing/NoType.xcrequirements`) — the identifier-only DR is deliberate; pinning anchor/cert-class/Team-ID would break Debug-rebuild TCC + Keychain persistence. Review B independently confirmed the signing path is correct and safe to merge.
- TranscribingHUD "TimelineView crash" — not a crash; a `@State` write in `.onAppear` is the endorsed-safe pattern. Only the dead `dotCount` var is removed (R23).
- Settings "Check for Updates" button behind `#if DEBUG` — the button shipped deliberately with its skip surface (R23/R24 in Updates docs); the doc does not prohibit it.
- Context-deadline "indefinite overrun" — overstated; AX is bounded by `Task.isCancelled` polling, Vision non-interruptibility is documented, and the paste path is insulated. (The value-length cap in R11's unit tightens the perf envelope regardless.)

**Deferred to Follow-Up Work:** if OQ1 resolves toward guarding cross-app paste, that becomes a new unit; the remaining PLAUSIBLE-low items in R21 (`finishReason` inspection, device-swap rebuild orphan, `minimal()` part-count) land as `docs/solutions/documentation-gaps/` entries rather than code changes unless a repro appears.

### Open Questions

- OQ1 (product, deferred — non-blocking). Cross-app paste: source app is frozen at session start; ⌘V posts to whatever is frontmost after the network round-trip. Guard on `sourceApp.processIdentifier` and abort/toast on mismatch, or keep "paste where the cursor is now"? Recommended default: guard + toast. Not implemented in this plan until decided.
- OQ2 (product, deferred — non-blocking). Keep the first-press Screen Recording prompt at all? R22's unit fixes the clear bug (respect the OCR toggle) regardless; whether to prompt on first press when OCR is enabled is the open call. Recommended default: keep, gated by the toggle.
- OQ3 (product, deferred — non-blocking). `AGENTS.md` is now canonical (root `CLAUDE.md` does `@AGENTS.md`) but is untracked and its per-module `@NoType/*/AGENTS.md` links point at files that don't exist (only `CLAUDE.md` files do). Decide: commit `AGENTS.md`? Add per-module `AGENTS.md` files, or repoint its links to the `CLAUDE.md` files? R23's unit fixes the stale content; the tracking/link strategy is the open call.
- OQ4 (low, deferred). Note-vs-fix: prefer frontmost window for OCR (`SCShareableContent.windows` is z-ordered); 180 s force-cut duplicating 300 ms when seam chunks share a batch; `minimal()` fallback dropping instruction parts on a single fast utterance. All bounded; comment-vs-code reconciliation.

### Sources

- Verification pass: fresh-context sub-agents reading each cited `file:line` against the per-module `CLAUDE.md` invariants. Both source reviews were transient files, consumed here and deleted.
- Relevant learnings: `docs/solutions/runtime-errors/sender-respawn-race-2026-05-16.md` (cancel/VAD teardown, R2/R3), `docs/solutions/architecture-patterns/partial-recovery-with-markers-2026-05-16.md` (terminal-vs-recoverable, R2), `docs/solutions/runtime-errors/timelineview-mainactor-instance-method-crash-2026-05-16.md` (R23 dotCount), `docs/solutions/architecture-patterns/clipboard-cmd-v-paste-2026-05-15.md` (R18), `docs/solutions/design-patterns/full-screen-ax-tree-2026-05-15.md` (R8–R12).

---

## Planning Contract

### Key Technical Decisions

- KTD-1 (R1). Gate the lite path on encoded-chunk cardinality at the call site, not by trusting the "single-audio by construction" comment. Add a `batchChunkCount == 1` term to the pure `RecordingSession.shouldUseLitePath` so `RecordingSessionShortPathTests` pins it, rather than a bare guard at the dispatch site — keeps the discriminator testable.
- KTD-2 (R2). Set the cancellation latch synchronously as the **first** statement of `cancel()`, before `recorder.stop()` and both `await` points, and re-check `failure`/`Task.isCancelled` immediately before the paste in `stop()`. This closes the "cancel invoked while stop is suspended before its all-failed check" window. A truly-late cancel after the paste commits is unavoidable and acceptable.
- KTD-3 (R5). Reuse the harvester's Unicode look-around (`(?<![\p{L}\p{N}])…(?![\p{L}\p{N}])`, `NoType/Dictionary/DictionaryHarvester.swift:604-613`) in `TextReplacementEngine`, not a bespoke boundary — one boundary idiom across the module.
- KTD-4 (R8–R10). Centralize the secure-field skip decision: promote `SecureFieldMasker.skipReason(for:)` from `private` to `internal` and call it from `captureSync` against a `NodeMetadata` built from the focused element, so the walker and the insertion-target path share one skip set. Scrub titles in `formatLine` and window titles before `RedactedWindowDump`. Scrub the focused value once before slicing.
- KTD-5 (R11). Add a dedicated base64-blob rule (charset `A-Za-z0-9+/=`, length ≥ 40) **above** the generic catch-all in `SecureFieldMasker.scrubContent`, preserving specific→generic order so nothing shadows. The letter-AND-digit catch-all requirement stays (avoids redacting prose); the base64 rule covers the `+/=` hole.
- KTD-6 (R12). Replace each `as!` on a CF/AX value with `as?` + `guard` returning nil/skip. Most cited sites are already preceded by a `CFGetTypeID`/`AXValueGetTypeID` guard, so this is primarily no-force-unwrap convention alignment plus defense-in-depth; `AccessibilityTree.swift:469` and `CategoryResolver.swift:70` may be genuinely unguarded and are the real hardening. No behavior change on well-formed trees.
- KTD-7 (R15). Make publication transactional: create the GitHub Release with assets first, verify, then commit/push the appcast. Applies to both `.github/workflows/release.yml` and `scripts/publish_release.sh`; drop the `|| true` on the tag push.
- KTD-8 (R17). Offload encode via `try await Task.detached { try ChunkBuilder.encodeAAC(pcm) }.value`; keep only queue bookkeeping and session-state mutation on the main actor.

### Assumptions

- The test target is `NoTypeTests`; all named test files exist (verified) and follow XCTest. New tests extend the existing files rather than adding new targets.
- Security-boundary units (R8–R12) are subject to the Context module hard rule: **every change to `SecureFieldMasker.swift` / `AXNoiseFilter.swift` and any path between AX/Vision output and the prompt must add at least one new `SecureFieldMaskerTests` / `AXNoiseFilterTests` case.** This is non-negotiable and reflected in each unit's test scenarios.
- Prompt/system-instruction files are not touched by this plan; the cache-prefix contract (`GeminiRequestBuilderTests`) is unaffected. R13 changes UI copy strings only.

### Sequencing

Recommended order by value/cost: **PR-A → PR-DICT → PR-E → PR-COPY → PR-C → PR-B → PR-D.** Phases are logically independent, but two files are edited by multiple PRs and will merge-conflict in the hot path if branched simultaneously: `RecordingSession.swift` (PR-A U1/U2/U3 and PR-D U18) and `AppState.swift` (PR-A U4, PR-DICT U7, PR-D U22). Land PR-A before PR-D, and rebase the later PR onto the earlier one rather than merging both from a stale `origin/main`. Within PR-B, U8 and U9 both edit `ContextSnapshot.swift`; coordinate the merge if they land as separate commits — there is no build dependency between them (U9 owns the `skipReason` promotion itself).

### System-Wide Impact

- Security boundary (R8–R12): these widen what is scrubbed and harden the walker. Net effect is *less* data reaching Gemini and *fewer* crash surfaces — no new egress path. The type-level `RedactedAXSnapshot` / `RedactedScreenText` egress contract is unchanged.
- Recording lifecycle (R1–R4, R17): touches the cancel/stop/sender/VAD hot path — the most concurrency-sensitive code in the project. Each unit is a minimal, local change; none alters the actor topology.
- Release pipeline (R14–R16): changes affect how installed clients receive updates. R15 in particular prevents a 404 window; verify against a prerelease tag before a real cut.

---

## Implementation Units

Unit index (23 units across 7 PRs):

| U-ID | Title | Primary files | Depends on |
|---|---|---|---|
| U1 | Lite-path cardinality gate | `NoType/Recording/RecordingSession.swift` | — |
| U2 | Cancellation latch ordering | `NoType/Recording/RecordingSession.swift` | — |
| U3 | VAD drain cancellation check | `NoType/Recording/RecordingSession.swift` | — |
| U4 | AX-revoke unwinds session | `NoType/AppState.swift` | — |
| U5 | Replacement punctuation boundaries | `NoType/Dictionary/TextReplacementEngine.swift` | — |
| U6 | Harvester chrome-head guard | `NoType/Dictionary/DictionaryHarvester.swift` | — |
| U7 | Replacement update uniqueness | `NoType/Dictionary/DictionaryStore.swift`, `NoType/AppState.swift` | — |
| U8 | Scrub AX + window titles | `NoType/Context/AccessibilityTree.swift`, `ContextSnapshot.swift` | — |
| U9 | captureSync full skip-rules | `NoType/Context/SecureFieldMasker.swift`, `ContextSnapshot.swift` | — |
| U10 | Split-cursor scrub | `NoType/Context/ContextSnapshot.swift` | — |
| U11 | Base64 scrub gap | `NoType/Context/SecureFieldMasker.swift` | — |
| U12 | Force-cast hardening | `NoType/Context/ContextSnapshot.swift`, `AccessibilityTree.swift`, `NoType/Instructions/CategoryResolver.swift` | — |
| U13 | Onboarding privacy copy | `NoType/Onboarding/Steps/OnboardingPermissionsStep.swift`, `OnboardingAPIKeyStep.swift` | — |
| U14 | Version gate: rc + dispatch | `.github/workflows/release.yml` | — |
| U15 | Transactional publish | `.github/workflows/release.yml`, `scripts/publish_release.sh` | — |
| U16 | Supply-chain & reproducibility | `.github/workflows/release.yml`, `.gitignore` | — |
| U17 | Release script hygiene | `scripts/release.sh`, `.github/workflows/build.yml` | — |
| U18 | AAC encode off MainActor | `NoType/Recording/RecordingSession.swift` | — |
| U19 | Clipboard changeCount guard | `NoType/Injection/TextInjector.swift` | — |
| U20 | Onboarding Back race | `NoType/Onboarding/Steps/OnboardingAPIKeyStep.swift` | — |
| U21 | MicProbe safe teardown | `NoType/Onboarding/MicProbe.swift` | — |
| U22 | Misc robustness + toggle gate | `NoType/AppState.swift`, `NoType/Updates/UpdateUserDriver.swift`, `NoType/Gemini/GeminiClient.swift` | — |
| U23 | Docs & dead code | `AGENTS.md`, `docs/build.md`, `docs/TECHDEBT.md`, `NoType/History/CLAUDE.md`, `NoType/UI/TranscribingHUD.swift` | — |

### PR-A — Recording & session correctness

#### U1. Lite-path cardinality gate

- **Requirements:** R1
- **Files:** `NoType/Recording/RecordingSession.swift`, `NoTypeTests/RecordingSessionShortPathTests.swift`
- **Approach:** The discriminator `shouldUseLitePath` (`:63-71`) and its call site (`:857-861`) test only total sample count, not batch cardinality; the lite dispatch sends `encoded[0]` (`:904-905`) while the covered-index append records every chunk (`:930/:954`). Add a `batchChunkCount` parameter to the pure `shouldUseLitePath` and require it to be `1`; pass `encoded.count` (post-encode, after the sub-150 ms drop) at the call site. A batch of ≥2 chunks then takes the normal batched path. Note: `encoded` is produced by the encode loop (`:874-889`), which currently runs *after* the discriminator call site (`:857`); reorder so encoding happens before `shouldUseLitePath`/`snapshotForChunk`, so `encoded.count` feeds the gate.
- **Patterns to follow:** the existing pure-function-pinned-by-test shape of `shouldUseLitePath` (`nonisolated static`).
- **Test scenarios:**
  - Covers R1. Two encoded chunks, `isFinalBatch == true`, zero successful priors, total audio < 2 s → `shouldUseLitePath` returns `false` (batched path taken, both chunks sent).
  - One encoded chunk, same conditions → returns `true` (lite path, unchanged behavior).
  - Regression: existing single-utterance lite-path cases still return `true`.
- **Verification:** `RecordingSessionShortPathTests` passes; no covered index maps to an unsent audio.

#### U2. Cancellation latch ordering

- **Requirements:** R2
- **Files:** `NoType/Recording/RecordingSession.swift`, `NoTypeTests/RecordingSessionCancellationTests.swift` (new)
- **Approach:** In `cancel()` (`:500-519`), move `if failure == nil { failure = CancellationError() }` to the first statement, before `recorder.stop()` and the two `await`s. In `stop()`, re-check `failure`/`Task.isCancelled` immediately before `await TextInjector.paste(final)` (`:647`) and bail without pasting or appending history (`:663`) if set. See `docs/solutions/runtime-errors/sender-respawn-race-2026-05-16.md` for the reentrancy family.
- **Execution note:** add a failing test first that drives cancel while `stop()` is suspended, then make it pass.
- **Test scenarios:**
  - Covers R2. `cancel()` invoked while `stop()` is suspended before its all-failed check → no paste, no `history.append`.
  - Cancel after paste already committed → still no crash; late cancel is a no-op (documented acceptable).
  - Normal release with no cancel → pastes and persists as before.
- **Verification:** new test passes; `finalizeRecording` identity-guard behavior unchanged for the non-cancel path.

#### U3. VAD drain cancellation check

- **Requirements:** R3
- **Files:** `NoType/Recording/RecordingSession.swift`, `NoTypeTests/RecordingSessionCancellationTests.swift`
- **Approach:** The detached VAD consumer loop `for await frame in stream` (`:700`) only `continue`s on inference error and has no cancellation check, so a cancelled session A keeps submitting `vad.probability(...)` to the app-shared `SileroVAD` actor while session B's `vad.reset()` (`:684`) interleaves. Add `if Task.isCancelled { break }` at the top of the loop body.
- **Test scenarios:**
  - Covers R3. After `vadTask.cancel()`, the loop stops submitting to the shared actor (assert via a probe/spy that no `probability` call lands post-cancel).
  - Test expectation: integration-flavored; if the shared actor can't be spied cheaply, assert the loop exits on a cancelled task with a synthetic stream.
- **Verification:** unit-level cancellation test passes; no behavior change to the non-cancelled drain.

#### U4. AX-revoke unwinds session

- **Requirements:** R4
- **Files:** `NoType/AppState.swift`, `NoTypeTests/` (state-machine test if a seam exists; otherwise manual-smoke note)
- **Approach:** In `applyAccessibilityState()` (`:430-436`) revoke branch, before/after `uninstallHotkey()` (`:636-653`), if `recordingState != .idle` call `cancelRecording()` (`:1065-1098`) so the session, HUD, mic, and any `SleepAssertion` unwind. Today only the tap is torn down, so the release/Esc events can never arrive and the mic stays hot.
- **Test scenarios:**
  - Covers R4. Simulated AX granted→denied transition while `recordingState == .recording` → `cancelRecording()` runs (state → `.idle`, assertion released). Assert against whatever `AppState` seam is testable; otherwise document as a manual smoke (revoke AX mid-hold → mic light goes off).
- **Verification:** state returns to `.idle`; `releaseSleepAssertion()` fires exactly once (no double-release with the existing cancel path).

### PR-DICT — Dictionary correctness

#### U5. Replacement punctuation boundaries

- **Requirements:** R5
- **Files:** `NoType/Dictionary/TextReplacementEngine.swift`, `NoTypeTests/TextReplacementEngineTests.swift`
- **Approach:** Replace the `\b + escaped + \b` pattern (`:96-108`) with the Unicode look-around `(?<![\p{L}\p{N}]) + escaped + (?![\p{L}\p{N}])` (mirror `DictionaryHarvester.findInContext:604-613`). Keep `escapedPattern(for:)` on `from` and `escapedTemplate(for:)` on `to`, and keep the auto-capitalized variant.
- **Patterns to follow:** `DictionaryHarvester.findInContext` look-around.
- **Test scenarios:**
  - Covers R5. `e.g. → for example` on `"use e.g. this"` replaces; `т.е. → то есть`; `.com → dot com`; `#tag → hashtag`; `c# → c sharp`.
  - Auto-cap variant `E.g.` replaces.
  - Regression: existing word-char-bounded pairs (`от есть`) still replace and don't over-match (`e.g.` does not fire inside `beg.example`).
- **Verification:** new punctuation-bounded cases pass; existing suite green.

#### U6. Harvester chrome-head guard

- **Requirements:** R6
- **Files:** `NoType/Dictionary/DictionaryHarvester.swift`, `NoTypeTests/DictionaryHarvesterTests.swift`
- **Approach:** `hasInterestingSignal` (`:298-304`) returns true for any uppercase-containing token, so a sentence-start chrome word (`Вот`/`The`) qualifies as a phrase head and longest-first prefers the chrome-led n-gram. Apply the sentence-start check to the candidate **head** in `processCandidate` (`:213-235`), routing through the already-implemented-but-dead `shouldSave` (`:395-408`) or inlining its head check.
- **Test scenarios:**
  - Covers R6. `"Вот Anthropic работает"` with context `"Вот Anthropic"` → saves `Anthropic`, not `Вот Anthropic`.
  - Mid-sentence proper noun still captured (no over-suppression).
  - Regression: existing harvester cases unchanged.
- **Verification:** `DictionaryHarvesterTests` (incl. the `shouldSave` section at `:246`) exercises the production path.

#### U7. Replacement update uniqueness

- **Requirements:** R7
- **Files:** `NoType/Dictionary/DictionaryStore.swift`, `NoType/AppState.swift`, `NoTypeTests/DictionaryStoreTests.swift`
- **Approach:** `updateReplacement(id:from:to:)` (`:221-236`) resolves by id only and skips the case-insensitive `from` collision check that `addReplacement` does (`:203`). Add the same `firstIndex(where: { $0.from.lowercased() == cleaned.lowercased() && $0.id != id })` guard; mirror in `AppState.updateReplacement` (`:1637-1653`). Latent today (no edit-pair UI), so a reject-or-merge policy is a judgment call — reject is simplest.
- **Test scenarios:**
  - Covers R7. Two pairs A (`ml`) and B (`ai`); editing B.from to `ML` → rejected (or merged), never two rows with case-insensitive-equal `from`.
  - Editing a pair's `to` only, or `from` to a genuinely new value → succeeds.
- **Verification:** `DictionaryStoreTests` covers the collision-on-update case.

### PR-B — Privacy & AX redaction (⚠ each unit ships a new SecureFieldMaskerTests / AXNoiseFilterTests case — Context module hard rule)

#### U8. Scrub AX + window titles

- **Requirements:** R8
- **Files:** `NoType/Context/AccessibilityTree.swift`, `NoType/Context/ContextSnapshot.swift`, `NoTypeTests/SecureFieldMaskerTests.swift`, `NoTypeTests/AccessibilityTreeTests.swift`
- **Approach:** `formatLine` (`:421-429`) renders `title` with only quote-swapping while `value` goes through the masker; window titles are stored raw in `RedactedWindowDump.title` and interpolated at `ContextSnapshot.swift:59-63`. Run `SecureFieldMasker.scrubContent` on `trimmedTitle` in `formatLine` and on `window.title` before it enters `RedactedWindowDump`. Consistent with `classifyApp` already omitting titles for the same PII reason.
- **Test scenarios:**
  - Covers R8. A node title `https://user:pass@host/x` → credentials redacted in the rendered line.
  - A window title containing a token-shaped string → redacted before prompt.
  - Secure-field-skipped nodes still drop entirely (title never rendered) — no regression.
- **Verification:** new `SecureFieldMaskerTests` + `AccessibilityTreeTests` cases pass.

#### U9. captureSync full skip-rules

- **Requirements:** R9
- **Dependencies:** none. U9 owns the `skipReason` promotion. U8 and U9 both edit `ContextSnapshot.swift`; coordinate the merge if split across commits (no build dependency).
- **Files:** `NoType/Context/SecureFieldMasker.swift`, `NoType/Context/ContextSnapshot.swift`, `NoTypeTests/SecureFieldMaskerTests.swift`
- **Approach:** `captureSync` (`:252-261`) skips only role/subrole `AXSecureTextField`; the walker's `skipReason(for:)` (`:98`, currently `private`) also skips on `roleDescription` "secure", identifier tokens (`password`,`token`,…), and the sensitive-`AXSheet` heuristic. Promote `skipReason(for:)` to `internal`, build a `NodeMetadata` from the focused element in `captureSync`, and return `.empty` on any non-nil reason.
- **Test scenarios:**
  - Covers R9. Focused plain `AXTextField` with `identifier == "password"` holding `hunter2` → `captureSync` returns `.empty`.
  - `roleDescription` containing "secure" → `.empty`.
  - Ordinary text field → captured as before.
- **Verification:** `SecureFieldMaskerTests` covers the identifier/roleDescription paths via `captureSync`.

#### U10. Split-cursor scrub

- **Requirements:** R10
- **Files:** `NoType/Context/ContextSnapshot.swift`, `NoTypeTests/SecureFieldMaskerTests.swift`
- **Approach:** `slice()` scrubs `rawBefore` and `rawAfter` independently (`:463-464`), so a secret straddling the cursor evades anchored patterns and a PEM body after the cursor leaks. Scrub the full focused value once before splitting into before/after (accept minor cursor drift — the section is advisory for spacing/capitalization).
- **Test scenarios:**
  - Covers R10. A 40-char token split at the cursor → redacted (neither half alone matched).
  - A PEM block with the cursor mid-body → whole body redacted.
  - Normal text unaffected; cursor position still usable for spacing.
- **Verification:** new `SecureFieldMaskerTests` case under the OCR/insertion consumer section.

#### U11. Base64 scrub gap

- **Requirements:** R11
- **Files:** `NoType/Context/SecureFieldMasker.swift`, `NoTypeTests/SecureFieldMaskerTests.swift`
- **Approach:** Add a base64-blob rule (charset `A-Za-z0-9+/=`, length ≥ 40) above the catch-all `opaqueTokenRegex` (`:304`), preserving specific→generic order. Optionally (OQ4/R11 perf) truncate the value to `maxValueLength` before masking so a huge digit blob can't spin the polynomial card regex.
- **Test scenarios:**
  - Covers R11. `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY` (AWS secret) → redacted.
  - A GCP-style base64 blob with `+`/`=` → redacted.
  - Regression: prose and the existing opaque-token/JWT/PAT cases unchanged; no shadowing of more-specific rules.
- **Verification:** new `SecureFieldMaskerTests` cases; pattern-order regression assertions pass.

#### U12. Force-cast hardening

- **Requirements:** R12
- **Files:** `NoType/Context/ContextSnapshot.swift`, `NoType/Context/AccessibilityTree.swift`, `NoType/Instructions/CategoryResolver.swift`, `NoTypeTests/` (as reachable)
- **Approach:** Replace the 7 `as!` casts on CF/AX values (`ContextSnapshot.swift:337,394,408,477,247`; `AccessibilityTree.swift:469`; `CategoryResolver.swift:70`) with `as?` + `guard` returning nil/skip. Most sites are already preceded by a `CFGetTypeID`/`AXValueGetTypeID` guard, so the cast can't trap there today — this is convention alignment + defense-in-depth. `AccessibilityTree.swift:469` and `CategoryResolver.swift:70` may be genuinely unguarded; those are the real hardening. Satisfies the no-force-unwrap convention.
- **Test scenarios:**
  - Covers R12. A synthetic attribute value of the wrong CFType at each site → the node is skipped, no trap.
  - Well-formed trees produce identical output to before.
  - Test expectation: where a site isn't unit-reachable, assert the guard exists via the pure decision path; otherwise manual reasoning noted.
- **Verification:** builds clean; no `as!` remains in the AX walk; existing Context tests green.

### PR-COPY — Onboarding privacy copy

#### U13. Onboarding privacy copy

- **Requirements:** R13
- **Files:** `NoType/Onboarding/Steps/OnboardingPermissionsStep.swift`, `NoType/Onboarding/Steps/OnboardingAPIKeyStep.swift`
- **Approach:** Rewrite three false strings — mic (`:57-61` "processed locally … nothing written to disk"), key (`OnboardingAPIKeyStep.swift:82` "never leaves your machine"), accessibility (`:75` "the focused app"). Copy-only; no logic change. Proposed replacements: mic → "captured only while you hold the key, briefly written to a temporary file to compress it, sent to Google's Gemini API for transcription, then deleted — never kept"; key → "stored in your macOS Keychain and sent to Google only to authenticate your transcription requests — never to us"; accessibility → "reads on-screen text from your open apps to improve accuracy". **Needs @kopachev's approved wording before merge.**
- **Test scenarios:** Test expectation: none — static copy. Verification is a proofread pass against the actual data flow.
- **Verification:** each claim in the copy is literally true of the shipped architecture (cloud transcription, transient chunk file, key in `x-goog-api-key`, full-screen AX walk).

### PR-C — Release & CI

#### U14. Version gate: rc + dispatch

- **Requirements:** R14
- **Files:** `.github/workflows/release.yml`
- **Approach:** The gate (`:85-94`) compares `TAG_VERSION="${GITHUB_REF_NAME#v}"` `==` plist, so `v0.1.11-rc1` and branch dispatch (`main`) both fail. Strip the suffix: `BASE="${TAG_VERSION%%-*}"`, compare `BASE`. Add a required `version`/tag input to `workflow_dispatch` (or guard the job to `refs/tags/*`) and correct the header comment about the UI rerun path.
- **Test scenarios:** Test expectation: none (CI config). Verify by pushing `vX.Y.Z-rc1` against a scratch tag or by `act`/dry-run: the gate passes for the rc tag and gives a clear message on branch dispatch.
- **Verification:** an rc tag reaches the build step; branch dispatch fails fast with a readable error.

#### U15. Transactional publish

- **Requirements:** R15
- **Files:** `.github/workflows/release.yml`, `scripts/publish_release.sh`
- **Approach:** Today CI commits/pushes the appcast (`:162-164`) before `gh release create` (`:170`), and `publish_release.sh` pushes the appcast (`:209-213`) before creating the release (`:244-250`) and swallows the tag push (`:227` `|| true`). Reorder both: create the Release + upload/verify assets first, then patch/commit/push the appcast. Drop the `|| true`.
- **Test scenarios:** Test expectation: none (release choreography). Verify with `publish_release.sh --dry-run` and a prerelease tag: the enclosure URL resolves before the appcast advertises it.
- **Verification:** no window exists where `docs/appcast.xml` points at a 404 asset; tag-push failure aborts the run.

#### U16. Supply-chain & reproducibility

- **Requirements:** R16
- **Files:** `.github/workflows/release.yml`, `.gitignore`, `Package.resolved`
- **Approach:** (a) Commit `Package.resolved` (currently untracked; Sparkle pinned only `from: 2.6.0`, resolves 2.9.1). Caveat: the resolved lockfile lives under the xcodegen-regenerated `NoType.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`, so verify where it persists after `xcodegen generate` and that the build honors it (may need `git add -f` plus an `xcodebuild -onlyUsePackageVersionsFromResolvedFile` flag, since `release.sh` regenerates the project first). (b) Pin `apple-actions/import-codesign-certs@v7` (`:59`) and `softprops/action-gh-release@v3` (`:170`) to full commit SHAs. (c) `sha256sum -c` the `sign_update` tarball (`:45-56`) before extract, against a known-good digest committed in-repo (e.g. `tools/sparkle/SHA256SUMS`) pinned to `SPARKLE_VERSION` — never a digest re-fetched from the download URL, or the check is a no-op against the key-exfiltration path. (d) Extract the current CHANGELOG section for the release body instead of `body_path: CHANGELOG.md` (`:176`) — reuse `scripts/sparkle_appcast_item.sh`'s section logic.
- **Test scenarios:** Test expectation: none (CI/hygiene). Verify: `git ls-files` shows `Package.resolved`; the two actions are SHA-pinned; a tampered tarball fails the checksum step; the Release page shows only the current version's notes.
- **Verification:** reproducible resolve; secrets-handling actions immutable-pinned; release notes scoped.

#### U17. Release script hygiene

- **Requirements:** R16
- **Files:** `scripts/release.sh`, `.github/workflows/build.yml`
- **Approach:** Low-risk batch: `cp -R`→`ditto` for DMG staging (`release.sh:141`); guard/drop the noisy local `sign_update` (`:180-182`); derive `Sparkle.framework/Versions/Current` via `readlink` instead of hardcoded `B` (`:106`); add a gitleaks step to `build.yml`; correct the stale macOS-14 comment (`build.yml:17-21`).
- **Test scenarios:** Test expectation: none. Verify `bash -n` passes and a local `release.sh` run still produces a signed, notarizable DMG.
- **Verification:** scripts lint clean; no functional regression in the DMG/zip artifacts.

### PR-D — Runtime polish

#### U18. AAC encode off MainActor

- **Requirements:** R17
- **Files:** `NoType/Recording/RecordingSession.swift`
- **Approach:** `ChunkBuilder.encodeAAC(pcm)` (`:882`) runs inside the `@MainActor`-isolated `processBatch`/`runSender` (`:834`/`:813`), so the temp-file write+read blocks the UI per chunk. Wrap in `try await Task.detached { try ChunkBuilder.encodeAAC(pcm) }.value`; keep queue bookkeeping and `markFailure` on the main actor.
- **Test scenarios:**
  - Covers R17. Existing `ChunkBuilderTests` round-trip still passes (encode correctness unchanged).
  - Test expectation: main-thread-offload is behavioral; assert via the sender flow that a session still produces the same stitched transcript.
- **Verification:** `ChunkBuilderTests` green; no encode on the main actor.

#### U19. Clipboard changeCount guard

- **Requirements:** R18
- **Files:** `NoType/Injection/TextInjector.swift`, `NoTypeTests/TextInjectorTests.swift`
- **Approach:** After our own `setString` (`:166-181`), capture `pb.changeCount`; skip `snapshot.restore(to: pb)` if it moved during the sleep (⌘V reads only, so it doesn't bump the count; a real user copy does). Keep the cancellation behavior (`try?` swallow) so restore still runs early on cancel.
- **Test scenarios:**
  - Covers R18. Simulated user copy during the restore delay (bump `changeCount`) → restore skipped, user's copy preserved.
  - No intervening copy → restore runs as before.
- **Verification:** `TextInjectorTests` covers the changed-vs-unchanged branch via the stub pasteboard.

#### U20. Onboarding Back race

- **Requirements:** R19
- **Files:** `NoType/Onboarding/Steps/OnboardingAPIKeyStep.swift`
- **Approach:** The validation `Task { @MainActor in … }` (`:327`) is unstored; its success arm persists the key and calls `goNext()` on shared `@Environment` state regardless of navigation. Guard the success arm with `guard onboarding.currentStep == .apiKey else { return }` before `goNext()` (or bind via `.task(id:)` and cancel on disappear).
- **Test scenarios:**
  - Covers R19. Validation completes after a simulated Back navigation → wizard does not advance from the new step. Assert against the onboarding state seam if testable; otherwise manual smoke.
- **Verification:** `goNext()` only fires while still on the API-key step.

#### U21. MicProbe safe teardown

- **Requirements:** R20
- **Files:** `NoType/Onboarding/MicProbe.swift`
- **Approach:** Add a `deinit` mirroring `stop()` (`:113-128`) — cancel `deviceObservationTask`, remove the observer, `engine.stop()` — so the mic releases even if `.onDisappear` misfires. Optionally wrap the device-observation `withCheckedContinuation` (`:95-109`) in `withTaskCancellationHandler` to resume on cancel.
- **Test scenarios:** Test expectation: none (onboarding-only lifecycle) — verify by reasoning + a manual smoke (dismiss mic-check step; mic light goes off).
- **Verification:** no path leaves the engine running after the probe deallocs.

#### U22. Misc robustness + toggle gate

- **Requirements:** R21, R22
- **Files:** `NoType/AppState.swift`, `NoType/Updates/UpdateUserDriver.swift`, `NoType/Gemini/GeminiClient.swift`
- **Approach:** Commit as two: R22 (tested behavior) and R21 (cleanups), so the user-facing toggle fix is independently reviewable/revertible. (R22) Gate the first-press Screen Recording deferral (`AppState.swift:809-813`) on `screenCaptureFallbackEnabled` (`:114`) so a user who disabled OCR isn't interrupted. (R21) Clear `controller?.pendingCancellation = nil` at the top of `showUpdateFound` (`UpdateUserDriver.swift`); drop or wire up the dead `RecordingState.error`; correct the `classifyApp` retry docstring (`GeminiClient.swift:236` — or route it through the retry loop). PLAUSIBLE-low items (`finishReason` inspection, device-swap orphan, `minimal()` part-count) → `docs/solutions/documentation-gaps/` entries, not code.
- **Test scenarios:**
  - Covers R22. OCR toggle off + Screen Recording `.notDetermined` → first hotkey press starts recording, no screen-capture prompt.
  - OCR toggle on + `.notDetermined` → existing deferral behavior (OQ2 governs whether to keep it).
- **Verification:** first dictation not blocked when OCR is off; update dismiss no longer fires a stale cancellation.

### PR-E — Docs & dead code

#### U23. Docs & dead code

- **Requirements:** R23
- **Files:** `AGENTS.md`, `docs/build.md`, `docs/TECHDEBT.md`, `NoType/History/CLAUDE.md`, `NoType/Dictionary/TextReplacementEngine.swift`, `NoType/Gemini/GeminiClient.swift`, `NoType/UI/TranscribingHUD.swift`
- **Approach:** Fix drift: `AGENTS.md:23` and `:51` (AVAudioEngine → Core Audio HAL, onboarding-MicProbe-only note); `docs/build.md:145` (old `-exportArchive` → archive-unsigned + manual Developer ID codesign); `docs/TECHDEBT.md:18` (remove the shipped keychain-migration entry per the "closing an entry" process); `NoType/History/CLAUDE.md:81` (`record(entry, tokens:, model:)`); `TextReplacementEngine.swift:26` header ("no cascading" → cascades); `GeminiClient.swift` classifier docstring. (The `build.yml:17` macOS comment is owned by U17.) Delete dead `dotCount` `@State` + its `.onAppear` (`TranscribingHUD.swift:96,110`) — a Swift edit, so it goes through the Build gate. Flag OQ3 (AGENTS.md tracking + per-module `@NoType/*/AGENTS.md` broken links) — fix content here, leave the tracking/link-strategy decision to @kopachev.
- **Test scenarios:** Test expectation: none — docs + dead-code removal. Verify the `dotCount` deletion leaves the ellipsis animation visually identical (derived from `ctx.date`).
- **Verification:** each named doc line matches shipped behavior; no dead `dotCount`; TECHDEBT no longer lists the closed item.

---

## Verification Contract

| Gate | Command / check | Applies to |
|---|---|---|
| Unit tests | `xcodebuild -project NoType.xcodeproj -scheme NoType test -destination 'platform=macOS'` | All code units (U1–U12, U18–U22) |
| Build (only if Swift changed) | `xcodebuild -project NoType.xcodeproj -scheme NoType -configuration Debug build`, then delete the DerivedData `NoType.app` per `docs/build.md` hard rules | Any unit touching Swift |
| Security-boundary tests (mandatory) | New `SecureFieldMaskerTests` / `AXNoiseFilterTests` case per changed file | U8, U9, U10, U11 (and U12 where reachable) |
| Release dry-run | `scripts/publish_release.sh --dry-run` + a `vX.Y.Z-rcN` prerelease tag | U14, U15, U16, U17 |
| Script lint | `bash -n scripts/release.sh scripts/publish_release.sh` | U15, U17 |
| Doc/behavior proofread | Manual: each copy claim (U13) and doc line (U23) matches the shipped data flow | U13, U23 |

Do not run `xcodebuild build`/`test` for doc-only or CI-config-only units (U13 copy, U14–U17) — no Swift changed. U23 is docs plus one Swift deletion (`TranscribingHUD.swift` `dotCount`): build for that deletion and confirm the ellipsis animation is unchanged. Follow the `docs/build.md` "Hard rules" (delete the built `.app`, deploy dev build to `/Applications` per your workflow) after any required build.

---

## Definition of Done

- Global: each PR merged from an `origin/main`-based branch (PR-C may branch from the release branch), reviewed, tests green. No verified false positive from Scope Boundaries was "fixed" (especially the signing DR).
- Per unit: its requirement (R-ID) is satisfied, its test scenarios pass (or its `Test expectation: none` rationale holds), and its Verification line is met.
- Security units U8–U11: the mandatory new `SecureFieldMaskerTests`/`AXNoiseFilterTests` case exists — no exceptions. U12 adds a case where a site is unit-reachable; guarded sites are otherwise verified by reasoning.
- U13 (wording), U22 (OQ2), U23 (OQ3) surface their product decision to @kopachev and implement only the mechanical/agreed part. OQ1 (cross-app paste) is deferred with no owning unit in this plan.
- Cleanup: no dead-end or abandoned code left in any diff; dead `dotCount` removed; `docs/TECHDEBT.md` reflects the closed keychain item.
- The recommended landing order (PR-A → PR-DICT → PR-E → PR-COPY → PR-C → PR-B → PR-D) is a suggestion; phases are logically independent, but honor the hot-path file-overlap sequencing in the Planning Contract (land PR-A before PR-D; rebase rather than parallel-merge on `RecordingSession.swift` / `AppState.swift`).
