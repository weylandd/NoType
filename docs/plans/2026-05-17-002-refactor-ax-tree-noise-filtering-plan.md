---
title: "refactor(context): noise-filter the AX tree so On-screen context: carries signal, not scaffolding"
type: refactor
status: active
created: 2026-05-17
plan_id: 2026-05-17-002
depth: standard
---

## Summary

Tighten the content of the `On-screen context:` cache-prefix section by filtering AX-tree noise (label-less window chrome, scrollback-shaped TextAreas, repetitive image lists, gibberish OCR-as-AX). Multi-app coverage stays (per `solutions/design-patterns/full-screen-ax-tree-2026-05-15.md`); the active app is prioritized via budget allocation. The change is content-only — no cache-prefix shape change, no system-prompt edits.

---

## Problem Frame

`On-screen context:` is part 6 of the Gemini cache prefix and ships on every transcription call. Two live request bodies (Telegram session + Ghostty session) captured during representative dictation surfaced multiple noise classes that contribute no disambiguation value. The two snapshots are exemplars of a pattern, not a survey — but each noise class below is recognizable *structurally* (window chrome, viewport blobs, OCR-as-AX, repetitive lists), so the trim is defensible even on a small sample because the filters target the *shape* of noise, not specific apps:

- **Empty UI scaffolding** — Safari "Начальная страница" rendered as ~30 lines of `Button`, `Splitter`, `ScrollBar`, `IncrementArrow`, `MenuButton` with no titles or values. Same pattern across every browser/Finder/window-chrome surface.
- **Repetitive image lists** — Finder window dumps `Image "Снимок экрана 2025-06-02 в 14.27.59"` × 24. Each line passes node-level filters (it has a title), but the pack collectively carries no transcription value.
- **Terminal scrollback** — Ghostty/Terminal expose visible scrollback as one giant `TextArea` value (brew install logs, multi-KB). The same shape is already detected and short-circuited for `InsertionTarget.captureSync` via `looksLikeScrollback`; the broader tree walk doesn't apply the same heuristic.
- **OCR-as-AX garbage** — QuickTime player exposes video-frame text through `AXTextArea` nodes: `"公第〇"`, `"口副"`, `"Силлоо « ПЕГЕНДАРНОГО сойма"`. Frame-by-frame mojibake masquerading as accessibility content.
- **VPN / status-bar widgets** — ExpressVPN-style apps spam button labels for every country/server, with role values that look meaningful but bias nothing the user is dictating.

User's read: *"AX tree is a useful function, but in its current form it only clutters context — we can squeeze more value out of it."* Per PR #46's prompt-section audit (`solutions/architecture-patterns/gemini-prompt-section-audit-2026-05-17.md`), section #9 `# Using on-screen context` is currently un-measurable on the eval suite (no AX fixtures), so we cannot lean on existing fixtures to defend "this content actually helps" — empirically and from inspection, the noise is mostly inert.

Why not just tighten budgets (5000/800/depth-6)? Budget tightening cuts uniformly across signal and noise. The actual win is signal density per token, not aggregate token count.

---

## Requirements

- **R1.** Multi-app AX walk is preserved (per ADR-009 / `solutions/design-patterns/full-screen-ax-tree-2026-05-15.md`). Cross-window context — Slack sidebar names, neighbouring documents, browser tab titles — must still reach Gemini.
- **R2.** The frontmost app at session start gets a **modest** priority on the shared node budget (1000 nodes vs 700 for non-active apps — a 1.4× ratio). The bump is small enough to preserve cross-window signal (per ADR-009: Slack sidebar names, neighbor doc codenames, issue-tracker spellings typically live in non-active windows) while honouring the user's intuition that the app they're typing into deserves a slight edge. The frontmost bundle id is passed into `AccessibilityTree.snapshot(...)` as a parameter by `RecordingSession.start` (rather than re-read from `NSWorkspace.frontmostApplication` inside `snapshot`) to eliminate the app-switch race between session start and the detached AX task. Before the global 5000-cap truncation loop, `dumps` is sorted active-first so the frontmost app is never the one dropped on a busy machine.
- **R3.** Noise filtering is content-level, not app-level. No `bundleID` deny-list. Useful text in chronically-noisy apps (e.g., an editor's open document) must still survive.
- **R4.** Structural-only nodes — pure window chrome (CloseButton, MinimizeButton, FullScreenButton, ZoomButton), scrollbar mechanics (ScrollBar, IncrementArrow, DecrementArrow, IncrementPage, DecrementPage, ValueIndicator), label-less containers (SplitGroup, TabGroup, Toolbar, ScrollArea with no descendants that pass) — are dropped. They never carry spelling content.
- **R5.** `AXTextArea` / `AXStaticText` nodes that look like terminal scrollback are dropped — but **only when the parent app is a known terminal emulator**. The walker uses a new `AXNoiseFilter.isViewportScrollback(role:value:parentBundleID:)` predicate, distinct from `InsertionTarget.looksLikeScrollback`, gated on parent bundle ∈ `knownTerminalBundleIDs` (Terminal, iTerm, Ghostty, Warp, kitty, alacritty, hyper, wezterm). This preserves the open document in TextEdit / Bear / Notes / BBEdit / Pages — the cross-window signal case ADR-009 was built for. `InsertionTarget.looksLikeScrollback` (focused-field bail-out) is unchanged because its cost matrix is different: a false positive there yields `.empty` cursor context, not a dropped neighbor document.
- **R6.** Sequential packs of same-role same-stem nodes (≥6 in a row) are collapsed into a single summary line in the rendered output: `  - Image (× N items, stem "Screenshot YYYY-MM-DD")`. The stem token survives (so first-time dictation of an item like "Screenshot…" still benefits from on-screen spelling disambiguation) and the per-item repetition is gone (~10–15 tokens for the summary vs ~24 × ~15 = 360 tokens for the raw 24-item Finder pack). Templated detection runs on the title stem after stripping trailing dates/numbers/times (typical Finder "Screenshot 2026-05-16 at 17.50.07" / "Снимок экрана 2026-01-26 в 19.40.53" patterns). Same-role packs whose items have *distinct stems* (e.g., 6 Safari tabs with different titles, 6 Finder sidebar entries with different names) do NOT collapse.
- **R7.** **Short** nodes (length ≤ 8 visible characters after stripping whitespace) whose value-or-title has a non-alphabetic/non-decimal character ratio > 0.4 are dropped. Length floor matters — long content with high symbol density is more often code, JSON, or structured data the user may dictate about; mojibake fragments from OCR-as-AX are almost always short. Examples: `公第〇` (3 CJK ideographs, all `isAlphabetic == true`, ratio = 0) → KEEP. `Привет` (full Cyrillic) → KEEP. `中文文档` (full CJK) → KEEP. `123` → KEEP (`isDecimal` counts). `口》巳@` (4 chars, 2 of 4 are symbols, ratio = 0.5) → DROP. `• 0` (3 chars, mostly symbol/whitespace) → DROP. `• A G% Mon Mar 23 19:42` (long, has letters/digits) → KEEP via length escape valve.
- **R8.** `SecureFieldMasker` runs unchanged. Filters are applied AFTER masking decides keep/replace/skip; secure-field skips still take precedence. No security regression.
- **R9.** Cache-prefix shape and labels are unchanged. `On-screen context:` stays at part 6; AX block format (`=== App ===\nWindow: "..."\n  - Role = value\n`) is preserved. `GeminiRequestBuilderTests` continues to pass without modification.
- **R10.** Per-app wall-clock cap (100 ms), global *rendered-line* budget (5000), depth cap (6), per-node value truncation (2000 chars) are unchanged in numeric value. The budget continues to count **rendered lines** (not nodes visited); filtering reduces lines rendered per walked node — that is the intended efficiency gain. The nodes-walked-to-lines-rendered ratio may increase on apps with high noise, but the per-app 100 ms wall-clock cap and the `Task.isCancelled` checks in `walk` already bound CPU.
- **R11.** Adds `AccessibilityTreeTests.swift` exercising the walker through an extracted `decideForNode(...)` decision function with `MockAXNode`-style fixtures, closing TECHDEBT entry `solutions/documentation-gaps/accessibility-tree-fixture-tests-2026-05-15.md` per the entry's stated need (depth cap, budget overflow, cancellation race, truncation flag are now testable without faking `AXUIElementCopyAttributeValue`).
- **R12.** Adds one PromptEval AX fixture exercising the live-API path with non-empty AX content — establishes the behavioural baseline for section #9 (`# Using on-screen context`) which is currently "Not measurable" per `solutions/architecture-patterns/gemini-prompt-section-audit-2026-05-17.md`.

---

## Key Technical Decisions

- **Decision: Filter at the node-render decision point inside `walk()`, not at the subtree-descent level.** Nodes can fail the noise filter without pruning their children. The walker (`AccessibilityTree.walk`) still descends every child; filtering runs as a new pure step between `SecureFieldMasker.mask(...)` and `lines.append`, inside the existing per-node branch — not as a separate pass over the tree. Dropping subtrees during descent would silently lose useful descendants when a noisy parent wraps a real text node (e.g., a Toolbar containing a labelled search field). **Why:** the walker already knows when to stop (budget, depth, timeout); adding "stop on noise" risks throwing the baby out with the bathwater.

- **Decision: Modest active-app priority via dynamic per-app budget AND deterministic global-cap ordering AND parameter-passed bundle id.** Three coordinated pieces, none useful without the others:
  1. **Budget split: 1000 / 700** (active vs non-active), a 1.4× ratio. An earlier draft proposed 1200 / 500 (2.4×); review surfaced that the larger ratio inverts ADR-009's premise — typical cross-window signal (Slack sidebar names, neighbor doc codenames) lives in non-active windows, so starving them by 37.5% hurts exactly the case the multi-app walk was built for. User intent is "small but real" preference for the window they're typing into; 1.4× honours that without crippling neighbours.
  2. **Sort `dumps` active-first before the global 5000-cap loop.** Without this, the loop iterates `dumps` in task-group completion order (non-deterministic) and on a 7+ app machine could drop the active app's dump. Active-first sort makes the budget priority cosmetic-resistant.
  3. **Pass `activeBundleID` as a parameter into `snapshot(...)`** from `RecordingSession.start`, rather than re-reading `NSWorkspace.frontmostApplication` inside the detached AX task. Eliminates the app-switch race; matches the existing `InsertionTarget` rationale at `ContextSnapshot.swift:453` ("avoid round-tripping through NSWorkspace.frontmostApplication which can race with app-switch events during session start").

- **Decision: Repetitive-pack collapse emits one summary line per pack — `- Role (× N items, stem "…")`.** A run of ≥6 same-role same-stem title-only lines collapses into a single summary line that preserves the stem token (`Screenshot`, `Снимок экрана`, `Untitled Document`, …) and the item count. Per R6 above, the stem survives because the disambiguation contract is "spelling reference for proper nouns the speaker mentioned" — and a first-time dictation of "screenshot" still benefits from on-screen confirmation of the canonical spelling. The per-item repetition (which carries no additional spelling value once the stem is shown once) is gone. **Why one line, not zero:** dropping the pack entirely would lose both the stem (spelling signal) and the count (situational signal — "user is looking at a folder of N thumbnails"). One short summary preserves both at a ~25× token saving vs the raw pack.

- **Decision: Separate scrollback predicates per call site, but share `knownTerminalBundleIDs`.** `InsertionTarget.looksLikeScrollback` stays as-is for the focused-field bail-out (a false positive there only yields `.empty` cursor context — cheap). The walker uses a new `AXNoiseFilter.isViewportScrollback(role:value:parentBundleID:)` predicate gated on parent bundle ∈ `knownTerminalBundleIDs` (the existing 8-emulator set on `InsertionTarget`). `knownTerminalBundleIDs` is promoted to `internal static` so `AXNoiseFilter` can read it without duplication. **Why:** the two call sites have asymmetric cost matrices. False positive in the InsertionTarget path = empty cursor context for one session. False positive in the walker path = an open Notes / Bear / BBEdit / Pages document silently dropped from the prompt — losing exactly the cross-window signal ADR-009 was built for. The shared terminal-bundle list keeps the "what counts as a terminal?" answer in one place; the predicates themselves are different functions with different thresholds.

- **Decision: Extract a testable `decideForNode(metadata:value:parentBundleID:) -> NodeDecision` step from `walk()`.** Today `walk()` is one ~70-line function that intermixes AX attribute reads, masker call, formatter call, recursion, budget bookkeeping. Splitting out the per-node decision (mask → noise-filter → render-or-drop) into a pure function with explicit inputs lets `AccessibilityTreeTests` exercise the full per-node pipeline against synthetic `MockAXNode`-style fixtures — without faking `AXUIElementCopyAttributeValue`. **Why:** the U4 walker-integration scenarios from the original plan draft tested rendering of hand-built `RedactedWindowDump` values, which doesn't exercise the new wiring at all. The extracted `decideForNode` is the seam that makes "masker-runs-before-noise-filter" provable, makes pack-collapse interaction testable, and properly closes the `MockAXNode` TECHDEBT entry.

- **Decision: One PromptEval AX fixture lands in this PR (new U6).** The prompt-section audit explicitly warned trimming section #9 without expanding eval is risky. This plan trims at the DATA layer, not the prompt, but carries the same epistemic risk: no current eval fixture exercises non-empty `RedactedAXSnapshot`. One fixture — audio of the speaker dictating a proper noun visible in a neighbour-app AX dump, assertion the canonical spelling appears in Gemini's output — gives the noise filter a real behavioural defense. Without it, the rollback signal is "user complains weeks later." **Why:** review surfaced that the manual-smoke-test gate is non-falsifiable without the original user's exact app constellation. One real fixture is a small unit; deferring forever risks the deferral becoming permanent.

- **Decision: Gibberish-density predicate is character-class based, not language-model based.** Threshold runs on `Unicode.Scalar.Properties.isAlphabetic || isDecimal` ratio. Real CJK (`isAlphabetic == true` for Han/Hiragana/Katakana/Hangul) passes; mojibake like `口》巳@` (mix of punctuation, symbols, broken substitutions) fails. **Why:** preserves multilingual context (per ADR-009 reasoning) while killing OCR-as-AX garbage. Pure function, no dependencies, testable from fixtures.

- **Decision: No system-prompt change.** The existing `# Using on-screen context` section already describes the disambiguation contract correctly; cleaner content makes it easier to honor, not different. Per project rule `feedback-prompt-master-required.md`, any prompt edit requires `prompt-master`; this plan deliberately avoids that path by keeping changes data-only.

---

## Scope Boundaries

In scope:
- New filter predicates as pure functions inside the Context module.
- Wiring into `AccessibilityTree.walk` after `SecureFieldMasker.mask` and before `lines.append`.
- Active-app priority budget allocation in `AccessibilityTree.snapshot` / `dumpApp`.
- Unit test coverage for the new predicates + an integration-style test for the walker.
- Documentation: `NoType/Context/CLAUDE.md` invariant + hard-rule additions; close TECHDEBT entry.

### Deferred to Follow-Up Work
- **Additional PromptEval AX fixtures.** U6 lands the first (proper-noun spelling via neighbour-app AX content). Follow-up fixtures: multi-language dictation, dictionary × AX interaction, OCR sub-block × AX interaction, scrollback-shape-but-not-terminal-parent (regression net for R5). Tracked separately because each fixture requires audio + Keychain entry + behavioural baseline tuning.
- **Reconsidering global budgets** (5000/1000-active/700-non-active/depth-6) after measuring the post-filter average token spend. If filtering reduces typical content by 40–60% as projected, budgets could shrink without information loss.
- **Per-window quality gate** (drop entire windows whose post-filter line count is 0). Likely a natural consequence of R4–R7 but not a separate enforcement; revisit if we still see empty `Window:` headers in shipped requests.
- **Calibrate filter thresholds against a broader sample.** Current values (gibberish 0.4, length floor 8, pack threshold 6, budget split 1000/700) are tuned for the two source examples. A debug-build instrumentation pass over 1–2 weeks of real use would let us validate or retune. Lower priority than landing the change — current values are conservative enough that the trim is defensible immediately.

### Outside Scope (will not be done)
- App-level bundleID deny-list — explicitly rejected by user direction in Phase 0.7.
- Changing `SecureFieldMasker` behaviour or thresholds — security boundary, separate concern.
- Changing OCR fallback (`ScreenCaptureContext`) — independent module, addresses a different failure mode.
- Changing cache-prefix shape, section labels, or part ordering — load-bearing for implicit caching (per `NoType/Gemini/CLAUDE.md` hard rules).
- ML/semantic content scoring — out of complexity scope; pure character-class heuristics suffice.

---

## High-Level Technical Design

*Directional guidance for review — not implementation specification.*

```
RecordingSession.start()
   activeBundleID = NSWorkspace.frontmostApplication.bundleID  (already captured today)
   contextTask = Task.detached { AccessibilityTree.snapshot(activeBundleID:) }  (CHANGED: pass param)

AccessibilityTree.snapshot(activeBundleID:)                    (CHANGED: accept param)
   ├── candidateApps()  -> [Candidate]                          (unchanged)
   ├── withTaskGroup:
   │      for each candidate:
   │         budget = activeBundleID == c.bundleID
   │                  ? perAppNodeBudgetActive (1000)            (NEW: modest priority)
   │                  : perAppNodeBudgetNonActive (700)          (NEW)
   │         dumpApp(pid, name, bundleID, budget, activeBundleID)
   │
   ├── dumps.sort { $0.bundleID == activeBundleID }              (NEW: active-first)
   └── apply global 5000 cap                                     (unchanged in numeric)

dumpApp(... , activeBundleID)                                    (CHANGED: forward param)
   └── walkApp(... , activeBundleID)
        for each window:
           lines: [String] = []
           walk(window, ... , parentBundleID: bundleID, &lines, &budget)
           ── AXNoiseFilter.collapseRepetitivePacks(&lines)       (NEW: post-pass, in place)
           windowDumps.append(RedactedWindowDump(title, lines))

walk(node, depth, parentBundleID, ...)                           (CHANGED: forward bundle)
   role/subrole/title/identifier/rawValue = AX attrs
   metadata = NodeMetadata(...)
   decision = decideForNode(                                     (NEW: extracted seam)
                role: role, subrole: subrole,
                title: title, value: rawValue,
                metadata: metadata,
                parentBundleID: parentBundleID)
   switch decision {
     case .skipSubtree:    return                                 (masker .skip — drops subtree)
     case .dropRender:     // noise-filtered; recurse but don't append
     case .render(let line): lines.append(line); budget -= 1
   }
   recurse into children                                          (unchanged structure)

decideForNode(role:subrole:title:value:metadata:parentBundleID:)  (NEW: pure, testable)
   action = SecureFieldMasker.mask(value, metadata)               (masker FIRST — invariant R8)
   switch action {
     case .skip:               return .skipSubtree
     case .keep(v), .replace(v,_):
        if AXNoiseFilter.shouldDropNode(                          (R4, R7)
              role: role, subrole: subrole,
              title: title, value: v)               { return .dropRender }
        if AXNoiseFilter.isViewportScrollback(                    (R5: terminal-parent gated)
              role: role, value: v,
              parentBundleID: parentBundleID)       { return .dropRender }
        guard let line = formatLine(role:subrole:title:value:depth:)
                                                     else { return .dropRender }
        return .render(line)
   }
```

Key shape notes:
- `decideForNode` is a pure function — no AX live calls. Tests drive it with synthetic inputs.
- `AXNoiseFilter.shouldDropNode` handles R4 (structural chrome) and R7 (gibberish-density). R5 (terminal scrollback) is a separate function because it needs `parentBundleID`.
- R6 (pack collapse) runs as `AXNoiseFilter.collapseRepetitivePacks` post-pass on `lines` after the window walk completes. It needs to see the rendered sequence and emit a summary line.
- The summary line format from R6 (`- Image (× N items, stem "...")`) is rendered in the post-pass, not as a per-node decision.

---

## Implementation Units

### U1. Pure noise-filter predicates

**Goal:** Introduce `AXNoiseFilter` — a pure-function namespace inside the Context module — that owns the structural-noise (R4), terminal-scrollback (R5), gibberish-density (R7), and repetitive-pack-collapse (R6) predicates.

**Requirements:** R4, R5, R6, R7

**Dependencies:** none

**Files:**
- create `NoType/Context/AXNoiseFilter.swift`
- create `NoTypeTests/AXNoiseFilterTests.swift`
- modify `NoType/Context/ContextSnapshot.swift` (promote `InsertionTarget.knownTerminalBundleIDs` from `private` to `internal static` so `AXNoiseFilter.isViewportScrollback` can read it without duplication)

**Approach:**
- `enum AXNoiseFilter` with static functions only (mirrors `SecureFieldMasker` shape and `AXAttr`).
- Public entry points:
  - `static func shouldDropNode(role:subrole:title:value:) -> Bool` — R4 + R7 per-node predicate.
  - `static func isViewportScrollback(role:value:parentBundleID:) -> Bool` — R5; returns `true` only when `parentBundleID` is in `InsertionTarget.knownTerminalBundleIDs` AND value shape matches scrollback (≥5 newlines AND >1000 chars, on `AXTextArea` / `AXStaticText`).
  - `static func collapseRepetitivePacks(_ lines: inout [String])` — R6 post-pass; replaces a run of ≥6 same-role same-stem lines with a single `- Image (× N items, stem "...")` summary line. Stem comparison uses `stripTrailingTemplateTokens` to fold date/time/number suffixes.
- Internal helpers: `isStructuralChromeRole(_:_:)`, `isLabellessContainer(role:title:value:)`, `isGibberishDominant(_:)`, `stripTrailingTemplateTokens(_:)`.
- All functions `static`, `Sendable`-clean (no shared state).

**Patterns to follow:** `NoType/Context/SecureFieldMasker.swift` — same enum-of-statics shape, same "decoupled `NodeMetadata` for tests" style, same "pure + testable" discipline.

**Test scenarios** (cover every category — predicates are pure, this is the safety net):
- *Structural chrome (R4):* `role=AXButton, subrole=AXCloseButton, title=nil, value=""` → drop. Same for `AXMinimizeButton`, `AXFullScreenButton`, `AXZoomButton`, `AXIncrementArrow`, `AXDecrementArrow`, `AXIncrementPage`, `AXDecrementPage`, `AXValueIndicator`, `AXScrollBar` (with no `value` text). Each subrole as a separate parametrised case.
- *Structural chrome with content stays:* `role=AXButton, title="Continue"` → keep. `role=AXButton, value="Send"` → keep. Defends against over-aggressive role-based drops.
- *Label-less containers:* `role=AXSplitGroup, title=nil, value=""` → drop. `role=AXTabGroup, title="tab bar", value=""` → drop. `role=AXToolbar, title=nil, value=""` → drop. `role=AXScrollArea, title=nil, value=""` → drop.
- *Label-less containers with title stay:* `role=AXTabGroup, title="Project Files"` → keep.
- *Scrollback in terminal parent (R5 — keep):* `role=AXTextArea, value="<2000 chars of brew install output with 8 newlines>", parentBundleID="com.apple.Terminal"` → drop. Same for `com.mitchellh.ghostty`, `com.googlecode.iterm2`, etc.
- *Scrollback shape in NON-terminal parent (R5 — must NOT drop):* `role=AXTextArea, value="<1500 chars of 6-paragraph Notes document>", parentBundleID="com.apple.Notes"` → **KEEP**. Same for `com.apple.TextEdit`, `com.barebones.bbedit`, `net.shinyfrog.bear`. **Critical regression test** — false positive here would silently drop an open document.
- *Scrollback below threshold:* `role=AXTextArea, value="short\nthree\nlines", parentBundleID="com.apple.Terminal"` → keep (below newline/length thresholds even in a terminal).
- *Gibberish density (R7):* `value="公第〇"` (3 chars, all `isAlphabetic`) → **KEEP** (ratio = 0). `value="Привет"` → keep. `value="中文文档"` → keep. `value="123"` → keep (decimals count). `value="口》巳@"` (4 chars, 50% symbols) → drop (length ≤ 8 AND ratio > 0.4). `value="• 0"` (3 chars, mostly symbol/whitespace) → drop. `value="• A G% Mon Mar 23 19:42"` (long, has letters) → keep (escapes length floor). `value="@@@@@@@@@@"` (10 chars, all symbols) → keep (length > 8 — escape valve).
- *Edge cases:* empty title and empty value with non-chrome role → drop (no signal). Single-char emoji → drop. Whitespace-only value → drop.
- *Repetitive-pack collapse (R6 — collapse):* feed 24 lines like `- Image "Снимок экрана 2025-06-02 в 14.27.59"` differing only in trailing date/time → output contains exactly one line `- Image (× 24 items, stem "Снимок экрана …")` in place of the pack. Pack of 12 with 3 dissimilar interlopers → only the runs of ≥6 collapse, interlopers preserved. Two consecutive packs of different stems each ≥6 → both packs collapse independently into two summary lines.
- *Repetitive-pack collapse (R6 — must NOT collapse — negative cases):* 6 Safari tabs `- Button "Gmail"`, `- Button "GitHub"`, `- Button "Stack Overflow"`, `- Button "Hacker News"`, `- Button "Apple Developer"`, `- Button "Notion"` → all 6 kept (distinct stems). 6 Finder sidebar `- Image "Documents"`, `- Image "Downloads"`, `- Image "Desktop"`, `- Image "Music"`, `- Image "Pictures"`, `- Image "Movies"` → all 6 kept. 5 same-stem lines (`- Image "Snapshot 2026-05-16"` × 5) → kept (below ≥6 threshold). Versioned series `- Button "Release 1.0"`, `- Button "Release 2.0"`, ... × 6 → kept (number is the discriminator, NOT to strip; stem stripper must distinguish trailing-date pattern from inline version numbers).
- *Pack of 6 same-stem Pages docs* `- Image "Untitled Document"` × 6 (no trailing variation) → collapses to `- Image (× 6 items, stem "Untitled Document")`.
- *Stem stripping (`stripTrailingTemplateTokens`):* `"Screenshot 2026-05-16 at 17.50.07"` and `"Снимок экрана 2026-01-26 в 19.40.53"` collapse to the same logical stem (different localised words, but the date suffix is what's stripped). `"Project notes"` does not collapse with `"Meeting notes"` (different leading word). `"Release 1.0"` and `"Release 2.0"` do NOT collapse with each other under the stem rule — version numbers are not the same as trailing dates.
- *Empty input safety:* `collapseRepetitivePacks(&[])` is a no-op. Single line array is a no-op.

**Verification:**
- `xcodebuild test -only-testing:NoTypeTests/AXNoiseFilterTests` passes locally.
- No new public surface in the Context module (everything `internal`).

---

### U2. Extract `decideForNode` from `walk()` and wire AXNoiseFilter through it

**Goal:** Refactor `AccessibilityTree.walk` so the per-node decision (mask → noise-filter → render-or-drop) lives in a pure, testable `decideForNode(role:subrole:title:value:metadata:parentBundleID:) -> NodeDecision` function. Wire `AXNoiseFilter.shouldDropNode` and `AXNoiseFilter.isViewportScrollback` through `decideForNode`. Run `AXNoiseFilter.collapseRepetitivePacks` once per window after the walk completes.

**Requirements:** R4–R7, R8 (secure-mask precedence), R9 (cache-prefix shape stable), R10 (budgets unchanged)

**Dependencies:** U1

**Files:**
- modify `NoType/Context/AccessibilityTree.swift`

**Approach:**
- Add `enum NodeDecision { case skipSubtree; case dropRender; case render(String) }` at the file scope inside `AccessibilityTree`.
- Extract `static func decideForNode(role:subrole:title:value:metadata:parentBundleID:) -> NodeDecision` that:
  1. Calls `SecureFieldMasker.mask(value, metadata)` first. `.skip` → `.skipSubtree`.
  2. On `.keep(v)` / `.replace(v, _)`: calls `AXNoiseFilter.shouldDropNode(role:subrole:title:value:)`. `true` → `.dropRender`.
  3. Then calls `AXNoiseFilter.isViewportScrollback(role:value:parentBundleID:)`. `true` → `.dropRender`.
  4. Then calls `formatLine(...)`. `nil` → `.dropRender`; non-nil → `.render(line)`.
- `walk()` now consumes `decideForNode`'s output:
  - `.skipSubtree`: return (matches today's `.skip` behavior — subtree dropped).
  - `.dropRender`: do not append to `lines`, do not decrement `budget`, **still recurse into children** (R4–R7 noise is about the rendered line, not the subtree).
  - `.render(line)`: `lines.append(line); budget -= 1`.
- `walk` forwards `parentBundleID` through recursion (read once at `walkApp` entry from `app.bundleID`).
- After `walk` returns in `walkApp`, call `AXNoiseFilter.collapseRepetitivePacks(&lines)` once per window (in-place mutation). Pack collapse runs before `windowDumps.append`.
- Budget bookkeeping: dropped-render-but-recurse-children means we may visit more children than today within the same budget. This is intentional — the budget caps lines rendered, not nodes visited; the existing `if budget <= 0 { return }` short-circuits remain correct. Per-app 100 ms wall-clock cap is the real CPU bound.
- Order of operations is load-bearing and pinned by `decideForNode`'s structure: `SecureFieldMasker.mask` → `AXNoiseFilter.shouldDropNode` → `AXNoiseFilter.isViewportScrollback` → `formatLine` → pack collapse post-pass.

**Patterns to follow:** existing `walk` function structure in `AccessibilityTree.swift`; existing `formatLine`-returns-`nil`-drop pattern at lines 273-278 (kept as belt-and-braces safety net; overlaps with R4 but cheap to keep). `SecureFieldMasker.NodeMetadata` style of decoupled value type for tests.

**Test scenarios:** (live in U4 against `decideForNode` directly; U2 itself is wiring + a smoke that the refactor preserves existing behaviour.)
- *Refactor smoke:* `decideForNode` exists, has the documented signature, returns the documented enum. `walk()` calls it and behaves identically to today on a synthetic tree of all-signal nodes (no filter triggers).
- *Compile guard:* `AccessibilityTree.NodeDecision` is `internal`, file-scope-visible to `AccessibilityTreeTests`.

**Verification:**
- `xcodebuild test -only-testing:NoTypeTests/SecureFieldMaskerTests` still passes (security boundary unchanged).
- `xcodebuild test -only-testing:NoTypeTests/GeminiRequestBuilderTests` passes unmodified (cache-prefix shape unchanged).
- Manual eyeball: run the dev build, dictate one chunk into Telegram + Ghostty (the two source examples) — captured `On-screen context:` section is materially shorter and visibly free of the cataloged noise classes.

---

### U3. Modest active-app priority — budget split + active-first ordering + parameter-passed bundle id

**Goal:** Active app (frontmost at session start) receives a 1.4× per-app node cap; non-active apps get a slightly reduced cap. `dumps` is sorted active-first before the global 5000-cap loop so the active app is never truncated on busy machines. `activeBundleID` is passed into `snapshot(...)` as a parameter from `RecordingSession.start` (not re-read inside the detached task) to eliminate the app-switch race.

**Requirements:** R2, R10

**Dependencies:** none (independent of U1/U2; can land in either order but most useful after U2)

**Files:**
- modify `NoType/Context/AccessibilityTree.swift`
- modify `NoType/Recording/RecordingSession.swift` (pass `activeBundleID` into `AccessibilityTree.snapshot(...)`)

**Approach:**
- Replace the single `perAppNodeBudget = 800` constant with two file-scope constants: `perAppNodeBudgetActive = 1000` and `perAppNodeBudgetNonActive = 700`. Sum across typical 4–6 visible apps: 1000 + 5×700 = 4500 < 5000 (fits without truncation).
- Change `static func snapshot()` to `static func snapshot(activeBundleID: String?) async -> RedactedAXSnapshot`. Drop the `@MainActor` read of `frontmostApplication` from inside `snapshot()` — caller provides it.
- `RecordingSession.start` already captures `frontmost = NSWorkspace.shared.frontmostApplication` on `@MainActor`; pass `frontmost?.bundleIdentifier` into the snapshot task.
- Each `dumpApp` task receives its budget via `c.bundleID == activeBundleID ? perAppNodeBudgetActive : perAppNodeBudgetNonActive`.
- Before the existing global 5000-cap truncation loop in `snapshot()`, sort `dumps` so the entry whose `bundleID == activeBundleID` is first (stable sort — preserves task-group completion order among non-active apps). The existing budget-cap loop then truncates from the tail; the active app survives.
- Edge case: `activeBundleID == nil` (rare — screen-locked, our own app is frontmost and gets skipped) → all apps get `perAppNodeBudgetNonActive`, no sort happens (every app is non-active). Documented in `NoType/Context/CLAUDE.md`.

**Patterns to follow:** existing `dumpApp(pid:name:bundleID:)` parameter style. Existing comment in `ContextSnapshot.swift:453` for the parameter-passing rationale.

**Test scenarios:**
- *Pure budget routing:* a helper `static func budgetForApp(bundleID:active:) -> Int` is unit-tested (`active == bundleID` → 1000; else → 700; `active == nil` → 700).
- *No frontmost app:* synthetic call with `activeBundleID == nil` → every app gets non-active budget; no crash; no sort applied.
- *Active app skipped (e.g., is our own bundle):* `activeBundleID` set but never matches a candidate → all candidates get non-active budget; sort is a no-op (no candidate matches the active key).
- *Active-first sort survives global cap:* synthetic `dumps` with 9 apps (active app's task completes 5th out of 9 in mock order); after sort, active app is at index 0; global-cap loop truncates from the tail; assert `capped.first?.bundleID == activeBundleID`.
- *Global cap still wins on truly-busy machines:* 8 non-active apps × 700 = 5600 > 5000; even with active app sorted first, the loop truncates and `truncated == true` flips on.
- *Race elimination:* `RecordingSession.start` test (or new test in `RecordingSessionTests`) asserts the bundle id passed into `snapshot` is the same one stored in `ContextSnapshot.activeApp`.

**Verification:**
- Unit test for `budgetForApp` passes.
- Manual: capture a snapshot in a busy 6-app environment; logged line `ax snapshot: N apps, M nodes, truncated=...` shows the active app's section is rendered first and is the largest of the dump (within reason — it has the bigger budget but its own content may be smaller than a noisy neighbour's).

---

### U4. Test coverage: `AccessibilityTreeTests.swift` exercises `decideForNode` + rendering

**Goal:** Close the documented test gap (`solutions/documentation-gaps/accessibility-tree-fixture-tests-2026-05-15.md`) by exercising the walker through the extracted `decideForNode(...)` seam from U2 (which is the testable pure-function entry into the new wiring) plus contract-pinning on `RedactedAXSnapshot.formattedForPrompt()` rendering.

**Requirements:** R11

**Dependencies:** U1, U2, U3

**Files:**
- create `NoTypeTests/AccessibilityTreeTests.swift`

**Approach:**
- The extracted `decideForNode(role:subrole:title:value:metadata:parentBundleID:) -> NodeDecision` from U2 is the testable pipeline entry. Drive it directly with synthetic inputs (no AX live calls, no `AXUIElementCopyAttributeValue` mocking needed). This covers the masker-noise-filter-format pipeline end-to-end.
- Add `RedactedAXSnapshot.formattedForPrompt()` rendering tests against hand-built `RedactedAppDump` / `RedactedWindowDump` for the contract pins (header shape, truncated marker, empty-apps case).
- Don't try to mock `AXUIElementCopyAttributeValue` — pure-predicate coverage (U1) + `decideForNode` pipeline coverage (here) + rendering-contract pins (here) covers the new wiring end-to-end without faking AX.

**Patterns to follow:** `NoTypeTests/SecureFieldMaskerTests.swift` for the synthetic-metadata test shape; `NoTypeTests/ChunkBuilderTests.swift` for "render the output and assert on it" shape.

**Test scenarios:**
- *`decideForNode` — masker precedence (R8):* `metadata.role="AXSecureTextField", value="hunter2"` → `.skipSubtree`. Critical: assert this regardless of what `AXNoiseFilter` would say. Pinned by construction in `decideForNode`'s ordering, but the test makes the invariant observable.
- *`decideForNode` — masker keeps, noise drops it:* `metadata.role="AXButton"`, masker returns `.keep("")`, `AXNoiseFilter.shouldDropNode` returns `true` (label-less chrome) → `.dropRender`.
- *`decideForNode` — masker keeps, scrollback in terminal parent drops it:* `metadata.role="AXTextArea"`, value=long brew install dump, `parentBundleID="com.apple.Terminal"` → `.dropRender`.
- *`decideForNode` — same scrollback shape in non-terminal parent renders:* `metadata.role="AXTextArea"`, value=long but legitimate notes content, `parentBundleID="com.apple.Notes"` → `.render(line)`.
- *`decideForNode` — formatLine `nil` falls through to `.dropRender`:* `metadata.role="AXGroup", title=nil, value=""` → existing safety-net path returns `.dropRender`.
- *`decideForNode` — happy path:* `metadata.role="AXTextField", value="user@example.com"` (or some content the masker doesn't redact) → `.render(line)` with the formatted output.
- *Snapshot rendering — empty apps:* `RedactedAXSnapshot(apps: []).formattedForPrompt() == "(no on-screen context available)"`.
- *Snapshot rendering — `truncated=true`:* output includes the documented marker line.
- *Snapshot rendering — header/window/line shape:* hand-built `RedactedAppDump` with one window and 3 lines renders the `=== App (bundle) ===\nWindow: "..."\n  - line1\n  - line2\n  - line3\n` format byte-for-byte.
- *Active-first rendering order:* hand-build a snapshot with 3 apps, set `apps[1].bundleID` as "active" via the source ordering produced by U3's sort; assert it appears first in the rendered output. (U3 owns the sort logic; this test pins the rendering side respects it.)

**Execution note:** Implement test-first for the `decideForNode` ordering assertions (R8 masker-precedence in particular). The pure predicates in U1 are already test-first by construction; this unit adds the pipeline-integration layer above them.

**Verification:**
- `xcodebuild test -only-testing:NoTypeTests/AccessibilityTreeTests` passes.
- TECHDEBT index updated: `docs/TECHDEBT.md` entry "AccessibilityTree fixture-driven tests" removed from "Current entries"; the underlying solution doc's body updated to "Closed in PR #N — decideForNode seam + AXNoiseFilter predicate tests cover depth cap, budget, masker precedence, and noise classification without faking AXUIElement."

---

### U5. Documentation + close TECHDEBT entry

**Goal:** Update `NoType/Context/CLAUDE.md` with the new invariants, hard rules, and a `Noise filtering` section; update the TECHDEBT index; refresh the prompt-section audit to reflect U6's eval addition.

**Requirements:** R11

**Dependencies:** U1, U2, U3, U4, U6 (documentation reflects shipped code)

**Files:**
- modify `NoType/Context/CLAUDE.md`
- modify `docs/TECHDEBT.md`
- modify `docs/solutions/documentation-gaps/accessibility-tree-fixture-tests-2026-05-15.md`
- modify `docs/solutions/architecture-patterns/gemini-prompt-section-audit-2026-05-17.md` (update the "Eval coverage gaps" → AX section to reference U6's new fixture as the first behavioural defense for section #9)
- consider adding a short solution doc `docs/solutions/architecture-patterns/ax-tree-noise-filtering-2026-05-17.md` capturing rationale (filter-not-deny-list, why pack-collapse renders summary lines, character-class gibberish predicate with length floor, terminal-parent-gated scrollback). Per `feedback-ce-compound-on-routine-changes.md` this is Lightweight CE-compound territory; include only if reviewers ask. Default: skip — the plan + CLAUDE.md updates carry the institutional memory.

**Approach:**
- Add invariants to `NoType/Context/CLAUDE.md` matching R4–R7, R8 (secure-mask precedence), R10 (budget counts rendered lines), and the modest active-app priority rule (R2).
- Add a hard rule mirroring the SecureFieldMasker precedent exactly: *"Any change to `AXNoiseFilter.swift` must add at least one new test case to `NoTypeTests/AXNoiseFilterTests.swift`. No exceptions."* — same wording shape and same "No exceptions" anchor.
- Cross-reference `InsertionTarget.knownTerminalBundleIDs` as the shared source-of-truth for terminal-bundle classification (now `internal static`, consumed by `AXNoiseFilter.isViewportScrollback`).
- Document the budget-semantics nuance: budget counts *rendered lines*, not nodes visited; filtering increases the walked-to-rendered ratio but per-app 100 ms cap bounds CPU.
- TECHDEBT entry close per `docs/TECHDEBT.md` "Closing an entry" instructions (update body, remove line, link PR in Related).

**Patterns to follow:** existing `NoType/Context/CLAUDE.md` structure (Files / Invariants / Hard rules / Walker bounds / Bypass / Threats not in scope / Testing / Pointers). The `Noise filtering` block fits naturally between `Walker bounds` and `Bypass`.

**Test scenarios:** *none — documentation-only.*

**Verification:**
- Docs render correctly (no broken Markdown links).
- `docs/TECHDEBT.md` "Current entries" list no longer mentions the AccessibilityTree test gap.
- The closed solution doc's body reflects "Closed in PR #N" per the standard close shape.
- The audit doc's "Eval coverage gaps" section notes the new AX fixture from U6 as partial coverage of section #9.

---

### U6. PromptEval AX fixture — behavioural defense for noise filtering

**Goal:** Add one PromptEval fixture exercising the live-API path with non-empty `RedactedAXSnapshot` content, establishing the first behavioural baseline for the un-measured section #9 (`# Using on-screen context`) and giving the noise filter a concrete falsifiable defense.

**Requirements:** R12

**Dependencies:** U1, U2, U3 (filter must be shipped before the fixture can assert post-filter behaviour)

**Files:**
- create `NoTypeTests/Fixtures/PromptEval/ax_proper_noun.json` (or whatever existing naming convention `PromptEvalHarness` uses — match existing `multi_sentence_en.json` / `silence_only.json` shape)
- create `NoTypeTests/Fixtures/PromptEval/ax_proper_noun.m4a` (~3 s audio, speaker pronounces a fabricated proper noun visible in the synthetic AX context)
- modify `NoTypeTests/PromptEvalTests.swift` if a new test case binding is needed (otherwise the existing test runner picks up the new fixture automatically — verify against existing harness shape)

**Approach:**
- Read `NoTypeTests/PromptEvalHarness.swift` and one existing fixture (e.g., `multi_sentence_en`) to understand the fixture JSON schema and the `ContextSnapshot` building shape.
- The new fixture builds a synthetic `ContextSnapshot` with:
  - A non-empty `RedactedAXSnapshot` containing a neighbour-app window with a proper noun the speaker will dictate (e.g., a fabricated brand like `"BoominfoCO"` rendered as `- StaticText = BoominfoCO` in a Notes-app neighbour window).
  - Active app set to a messenger (e.g., `ru.keepcoder.Telegram`) with category `messaging` to exercise a realistic full-path session.
  - Empty `User dictionary`, empty `User instruction` (isolates the AX-context spelling effect from dictionary effects).
- Audio fixture: a short clip with the speaker saying the proper noun in a sentence (e.g., "Let me check BoominfoCO"). Acceptable to record manually; document the recording text in the JSON for reproducibility.
- Assertion: Gemini output contains the canonical spelling `"BoominfoCO"` (not `"Boomy info co"` or other phonetic variants). Use `containsSubstring` per the existing harness convention.
- Live-API gating already exists (`NOTYPE_GEMINI_KEY` env or Keychain entry `app.notype.tests.gemini`); the new fixture inherits the same skip-cleanly behaviour when neither is set.

**Patterns to follow:** existing fixture JSON shape under `NoTypeTests/Fixtures/PromptEval/` (per the audit doc's reference); existing skip-on-missing-key pattern in `PromptEvalTests.swift`.

**Test scenarios:**
- *Happy path:* Gemini transcribes the audio; output contains the canonical proper-noun spelling visible in the AX context. **Behavioural baseline for section #9.**
- *Regression net:* if a future change to `AXNoiseFilter` accidentally drops the proper noun's `StaticText` node, this fixture fails — surfacing the regression in CI rather than weeks later as a user complaint.

**Execution note:** This is the test-first defense for the noise-filter approach. Land alongside the implementation in the same PR — the fixture is the rollback signal if the filter degrades real disambiguation.

**Verification:**
- `xcodebuild test -only-testing:NoTypeTests/PromptEvalTests` passes with a configured Gemini key.
- Without a key, the new fixture skips cleanly alongside the existing ones.
- Manual: temporarily blank `AXNoiseFilter.shouldDropNode` to always return `true` (drop everything) and re-run — the fixture should now fail (proper noun no longer in context → spelling regresses). Restore. This proves the fixture is load-bearing, not vacuously passing.

---

## System-Wide Impact

- **Cache-prefix shape:** unchanged. `On-screen context:` stays at part 6 of the 6/7/8 user-message-part shape (per `NoType/Gemini/CLAUDE.md`). Content shrinks within the section; labels and ordering are byte-stable. `GeminiRequestBuilderTests` is unmodified.
- **Per-session cost:** drops on every transcription request. Order-of-magnitude expectation from the two source examples: 30–60% reduction in `On-screen context:` content tokens. Aggregate effect on full-path prompt ≈ 5–15% per-call savings (the system prompt + cache prefix is ~2 714 tokens post-PR-#46; AX content is one part of the 6/7/8 user message text parts).
- **Implicit caching — intra-session:** unaffected. The snapshot is captured once at session start (per `NoType/Context/CLAUDE.md` invariant #6) and frozen; byte-stability across chunks within one session holds.
- **Implicit caching — cross-session (accepted tradeoff):** the dynamic active-app budget (R2, 1000 vs 700) means that the *same pair of running apps* yields slightly different AX content across sessions depending on which app is frontmost at session start. This trades a small cross-session implicit-cache hit-rate for higher signal-density per session. The bet: noise-filtered content is more useful per token than larger noisier content with marginally better cache reuse. The 1.4× ratio (vs an earlier-considered 2.4×) is deliberately modest to keep the cross-session content drift small.
- **Security boundary:** `SecureFieldMasker` runs first and unchanged. The extracted `decideForNode` pins masker-first ordering structurally — `.skip` returns `.skipSubtree` before any noise-filter call. Noise filter operates only on values the masker already cleared. R4–R7 don't introduce a new way to leak sensitive content. The R8 invariant has a dedicated test (`decideForNode` masker-precedence case in U4).
- **Other modules:** `Recording` is touched (one-line change in `RecordingSession.start` to pass `activeBundleID` into `snapshot(...)`); `Gemini`, `Injection`, `Instructions`, `Dictionary`, `History`, `UI` — none touched. The filter is a Context-module-internal concern; the produced `RedactedAXSnapshot` is the same type and the same public API (`formattedForPrompt()`).
- **OCR fallback (`ScreenCaptureContext`):** unchanged. The `hasContent(for:)` discriminator that decides whether to attach an OCR sub-block (per `NoType/Context/CLAUDE.md` invariant #3) still operates correctly — if our filter empties the active app's lines entirely, `hasContent` returns `false` and OCR fallback activates as designed (with Screen Recording permission). This is a desirable secondary effect, not a regression.
- **Test surface:** adds two new code/test files (`AXNoiseFilter.swift` + tests, `AccessibilityTreeTests.swift`), one PromptEval fixture pair (JSON + audio), and modifies two existing (`AccessibilityTree.swift`, `RecordingSession.swift`). No SPM dependency changes (per `solutions/conventions/testing-spm-and-git-2026-05-15.md` allow-list).
- **Prompt eval (`PromptEvalTests.swift`):** gains its first AX-content fixture via U6. Section #9 (`# Using on-screen context`) moves from "Not measurable" (per `solutions/architecture-patterns/gemini-prompt-section-audit-2026-05-17.md`) to partially-measurable. This is the rollback signal for noise-filter regressions.
- **Project rule `feedback-prompt-master-required.md`:** does NOT apply to this plan — no LLM prompt text changes. The `On-screen context:` rendering format (`=== App ===` headers, indented role/value lines, R6 summary line) is data formatting consumed by the model; the system prompt that *describes* the section is untouched. If a future change adds a prose hint to the section (e.g., "(noise-filtered)"), `prompt-master` invocation becomes required.

---

## Risks & Mitigations

- **Risk: Over-filtering removes useful content** (e.g., a button label that IS the proper noun the user is dictating). *Mitigation:* R4 only drops nodes with **no** title and **no** value. R7 has a length floor (≤8 chars) plus a 0.4 non-alphabetic threshold, so legitimate CJK / Cyrillic / mixed-script content survives. R5 only fires under terminal parent bundles, so open editor documents are never accidentally classified as scrollback. U6 PromptEval fixture provides the behavioural regression net.
- **Risk: Repetitive-pack collapse drops a legitimate list the user is dictating about** (e.g., 20 file names in a project sidebar). *Mitigation:* threshold of ≥6 with the same template stem; the R6 summary line preserves the stem token (so first-time dictation of `"Screenshot 2026-05-16…"` still has `"Screenshot"` as a spelling reference). Distinct-stem lists (Safari tabs, Finder sidebar entries with different names, versioned releases like `"Release 1.0"`/`"Release 2.0"`) do NOT collapse — pinned by U1 negative tests.
- **Risk: Active-app priority + global cap interaction on busy machines.** *Mitigation:* (a) modest 1.4× ratio (1000/700) keeps total well under cap for typical 4–6 app machines (1000 + 5×700 = 4500); (b) `dumps` sorted active-first before the truncation loop, so even on 9+ app machines the active app is never the one truncated. Pinned by U3 test asserting active-app survives global cap.
- **Risk: Eval coverage gap for AX section #9.** *Mitigation:* U6 lands one PromptEval AX fixture in this PR — first behavioural defense for section #9 per `solutions/architecture-patterns/gemini-prompt-section-audit-2026-05-17.md`. Coverage remains thin (one fixture, one proper-noun pattern), but the deferred-forever failure mode is avoided. Additional fixtures (multi-language, dictionary interaction, OCR sub-block) tracked separately.
- **Risk: `frontmostApplication` race at session start** (user has just app-switched; AX walk sees a different active app than `RecordingSession.start` recorded). *Mitigation:* eliminated by U3's parameter-passing design — `RecordingSession.start` captures `frontmost` once on `@MainActor` and passes the bundle id into `snapshot(...)`. The AX task never re-reads `NSWorkspace.frontmostApplication`. Mirrors the existing `InsertionTarget` rationale at `ContextSnapshot.swift:453`.
- **Risk: Two-snapshot evidence base may not generalise.** *Mitigation:* filters target structural shapes (window chrome roles, terminal-parent scrollback, gibberish character density, repetitive-pack stems) that recur across apps, not specific bundle ids. Filter behaviour on unsampled apps is bounded by the same predicates exercised in U1 tests. U6 fixture is the canary if generalisation fails on a real workload.

---

## Open Questions

- **None blocking.** The Phase 0.7 synthesis resolved both initial forks (multi-app vs active-only; content-filter vs deny-list). The Phase 5.3 deeper doc review surfaced 4 design call-outs (scrollback predicate reuse, active-app priority magnitude, U4 test architecture, PromptEval fixture deferral) — all integrated above. Specific filter thresholds (gibberish ratio 0.4, length floor 8, pack-collapse threshold 6, budget split 1000/700) are starting values tuned for the two source examples plus reviewer feedback; they live in `AXNoiseFilter` / `AccessibilityTree.swift` as named constants and are trivially adjustable in follow-up commits if reviewers want different defaults.

---

## Verification Strategy

1. **Unit tests** (`AXNoiseFilterTests.swift`, `AccessibilityTreeTests.swift`) — every predicate has happy path, edge cases, integration scenarios, and **negative regression cases** (R5 in non-terminal parent, R6 distinct-stem lists, R7 length-floor escape valve) per U1/U4. `xcodebuild test -only-testing:` covers each independently.
2. **Pipeline-integration tests** — `decideForNode(...)` exercised through U4 with synthetic `NodeMetadata` fixtures, asserting R8 masker-precedence is observable at the seam (not just by code inspection).
3. **Behavioural test** — U6 PromptEval AX fixture (live API, gated by `NOTYPE_GEMINI_KEY` / Keychain) asserts a proper noun visible in neighbour-app AX content is spelled canonically in Gemini's output. **This is the rollback signal** if the noise filter accidentally drops real disambiguation content.
4. **Contract tests** — existing `SecureFieldMaskerTests` and `GeminiRequestBuilderTests` pass without modification. If either fails, that's a contract regression and the change must roll back.
5. **Manual reproduction of the source examples** — install the dev build (per project memory `feedback-deploy-dev-build-to-applications.md`: replace `/Applications/NoType.app`), dictate one short chunk into Telegram and one into Ghostty with the same window layouts captured in Problem Frame. Inspect the outgoing request body (existing dev-build logging mechanism) and confirm:
   - Telegram session: ExpressVPN scaffolding, Safari new-tab UI noise, Finder screenshot pack are absent or pack-collapsed.
   - Ghostty session: Terminal scrollback drops; QuickTime OCR-as-AX garbage drops; TextEdit content survives.
6. **No cache-shape regression** — `GeminiRequestBuilderTests` `test_partOrderAndLabels_stableWithAndWithoutOCR` continues to pass.
7. **No security regression** — `SecureFieldMaskerTests` continues to pass; the new `decideForNode` masker-precedence test in U4 pins the in-walker ordering.

---

## Rollout

- Single branch: `refactor/ax-tree-noise-filtering` (per project memory `feedback-gitflow.md` / `feedback-fetch-before-branching.md` — branch from `origin/main`).
- One PR. Implementation units land as separate commits in the order U1 → U2 → U3 → U4 → U5 for reviewability; squash on merge.
- No feature flag — the filter is always-on. If reviewers prefer staged rollout (e.g., an env-var kill-switch for one release), add `NOTYPE_AX_FILTER_DISABLE` env var in U2 reading `ProcessInfo.processInfo.environment` once at process start; default off. Plan-time fallback only.
- Per project memory `feedback-review-compound-automatic.md`: after merge, run `/ce-code-review` on the PR and `/ce-compound-refresh` without being asked.
