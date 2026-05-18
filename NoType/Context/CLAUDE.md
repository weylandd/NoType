# Context module

**Security boundary.** The module captures on-screen context that ships to Gemini. Any code path that lets raw AX content or pixel-derived text reach the network is a bug.

## Files

- `AccessibilityTree.swift` — walks the AX trees of **all on-screen windows** (parallel `withTaskGroup`). Exposes the pure `decideForNode(...) -> NodeDecision` seam (per-node pipeline: masker → noise filter → format) and `applyGlobalCap(dumps:activeBundleID:)` (active-first sort + 5000-line truncation).
- `AXNoiseFilter.swift` — pure-function namespace for content noise (R4 chrome, R5 terminal scrollback, R6 repetitive packs, R7 short gibberish). Runs **after** `SecureFieldMasker` inside `decideForNode`; never overrides secure-field skips. Owns `knownTerminalBundleIDs` (shared with `InsertionTarget.captureSync`).
- `ContextSnapshot.swift` — value types: `AppInfo`, `RedactedAXSnapshot`, `RedactedScreenText`, `InsertionTarget`, `ContextSnapshot`.
- `SecureFieldMasker.swift` — **security-critical**. Skip rules + value-content scrubbing patterns.
- `ScreenCapture/ScreenCaptureController.swift` — `ScreenCaptureKit` wrapper for active-window screenshots.
- `ScreenCapture/TextRecognizer.swift` — `Vision` OCR wrapper.
- `ScreenCapture/ScreenCaptureContext.swift` — orchestrator. Permission gate → capture → OCR → per-line `SecureFieldMasker.scrubContent` → `RedactedScreenText?`.

`InsertionTarget.captureSync()` reads the focused field's value + cursor; the active-app fact is read directly from `NSWorkspace.frontmostApplication` in `RecordingSession.start()`.

## Invariants

1. **`AccessibilityTree.snapshot(activeBundleID:)` returns `RedactedAXSnapshot`, never raw text.** Type-level masking enforcement — no public API lets raw AX content reach the network.
2. **`ScreenCaptureContext.capture(...)` returns `RedactedScreenText?`** with a module-internal initializer. Same shape as `RedactedAXSnapshot` — no public path from raw `CGImage` text to the network.
3. **OCR sub-block is included only when AX returned contentless for the active app** (`tree.hasContent(for:) == false`). Otherwise the OCR result is discarded.
4. **OCR runs only when Screen Recording TCC permission is granted.** When ungranted, the OCR limb never spawns — behaviour is identical to the AX-only path.
5. **Independent per-task wall-clock caps; partial results survive.** AX 1500 ms cap, OCR 2500 ms cap. AX timeout → OCR result used with empty-tree fallback. OCR timeout → AX result used alone. No joint deadline.
6. **`InsertionTarget` is captured once at session start; cursor doesn't move during a session** (user holds the hotkey). The section ships even when `.unknown` — empty strings, but the section stays so the prefix shape is stable.
7. **`InsertionTarget.captureSync()` refuses to read `AXSecureTextField` outright.** Returns `.empty` rather than attempting to read the value.
8. **`SecureFieldMasker` runs first in `decideForNode`.** `.skip` short-circuits to `.skipSubtree` *before* `AXNoiseFilter` is consulted — secure-field skips can never be overridden by the noise filter. Pinned by `AccessibilityTreeTests` (`test_decide_secureFieldSkipsBeforeNoiseFilter` + sensitive-sheet-parent variant).
9. **Global budget counts rendered lines, not nodes visited.** Filtering may walk more children per rendered line (a label-less Toolbar parent is filtered out but its labelled children render). Noise-filter `.dropRender` parents still recurse into children **without charging budget**, so for chrome-heavy trees (Electron, deep label-less container hierarchies) the per-app **100 ms wall-clock cap — NOT the rendered-lines budget — is the binding CPU constraint**. That's intentional: the wall-clock cap is the right controller for CPU; the rendered-lines budget is for output-size. `Task.isCancelled` checks in `walk` make the wall-clock cap reachable mid-recursion.
10. **`activeBundleID` is passed in by the caller, never re-read inside `snapshot()`.** Guardrail against re-introducing an `NSWorkspace.frontmostApplication` read inside the detached AX task — that would race with app-switch events between session start (`RecordingSession.start` captures `frontmost?.bundleIdentifier` on `@MainActor`) and the AX walk firing. Mirrors the existing `InsertionTarget` rationale at `ContextSnapshot.swift:453` ("avoid round-tripping through `NSWorkspace.frontmostApplication` which can race with app-switch events during session start").

## Hard rules

- **Any change to `SecureFieldMasker.swift` must add at least one new test case to `NoTypeTests/SecureFieldMaskerTests.swift`. No exceptions.** Security boundary.
- **Any change to `AXNoiseFilter.swift` must add at least one new test case to `NoTypeTests/AXNoiseFilterTests.swift`. No exceptions.** Same discipline — adjacent to the security boundary, and the noise filter is what decides whether content survives to render.
- **Any change to the path between Vision output and the prompt must add a `SecureFieldMaskerTests` case under the `// MARK: - OCR fallback consumer` section.** Same security reason.
- **All on-screen apps' AX trees are walked**, not just the focused window. NoType's own bundle is filtered (`selfBundleID`).
- **Skip-rule layer + content-pattern layer are both required.** Role-based skip runs first; content scrub runs after — neither is sufficient alone.
- **Pattern order in `SecureFieldMasker.scrubContent` is load-bearing.** More-specific patterns (JWT, GitHub PAT, Google API key) must hit before more-generic ones (40-char opaque token). Add new patterns above the catch-all, not below.
- **`decideForNode` pipeline order is load-bearing.** Masker → AXNoiseFilter.shouldDropNode → AXNoiseFilter.isViewportScrollback → formatLine. Reordering any of these breaks R8 or the noise-filter contract — `AccessibilityTreeTests` pins it.

## Walker bounds

- Total rendered lines: 5000 (`totalNodeBudget`). Above this, `applyGlobalCap` truncates from the tail with `truncated = true` — the active app survives because it's moved to the front first.
- Per-app rendered lines: **1000 for the active app, 700 for non-active** (R2 modest priority, ~1.4× ratio). Active is moved to the front before truncation so it's never the one dropped on a busy machine.
- Max depth per window: 6.
- Max value length per node: 2000 chars (truncated with `…`).
- Per-app wall-clock: 100 ms — races a `Task.sleep` sentinel inside `withTaskGroup`. Both `walkApp` and `walk` poll `Task.isCancelled` at every window and recursion step.

## Noise filtering

After `SecureFieldMasker` clears a node, `AXNoiseFilter` (run inside `decideForNode`) classifies the rendered LINE as signal or noise. Four independent filters; secure-field skips always win.

- **R4 structural chrome.** Pure-mechanic roles (`AXScrollBar`, `AXValueIndicator`) drop unconditionally — their `kAXValueAttribute` is a numeric position string, never content. Chrome subroles (`AXCloseButton`, `AXMinimizeButton`, `AXFullScreenButton`, `AXZoomButton`, `AXIncrementArrow/DecrementArrow/IncrementPage/DecrementPage`) and label-less container roles (`AXSplitGroup`, `AXTabGroup`, `AXToolbar`, `AXScrollArea`, `AXLayoutArea`, `AXLayoutItem`) drop *only when they carry no title or value of their own* — a labelled CloseButton still renders.
- **R5 terminal scrollback.** `AXTextArea` / `AXStaticText` with ≥5 newlines AND >1000 chars drops **only when the containing app is in `AXNoiseFilter.knownTerminalBundleIDs`** (Terminal, iTerm, Ghostty, Warp, kitty, alacritty, hyper, wezterm). Open Notes / Bear / TextEdit / BBEdit / Pages documents survive — regression-pinned by `AXNoiseFilterTests`.
- **R6 repetitive-pack collapse.** Runs of ≥6 same-role same-stem title-only lines collapse into one summary `- Image (× N items, stem "Screenshot YYYY-MM-DD")`. Stem-strip removes `YYYY-[./-]MM-DD` date suffixes; inline version numbers (`Release 1.0` / `Release 2.0`) are NOT stripped — distinct stems don't collapse.
- **R7 short gibberish.** Drops nodes whose value-or-title is ≤8 non-whitespace chars AND has non-alphabetic/non-decimal ratio > 0.4. CJK ideographs are alphabetic (`公第〇` → keep). Length floor escape valve means long mixed content (code, JSON, scrollback fragments) always passes.

When a noise filter fires (returns `.dropRender`), the walker does NOT append a line and does NOT charge against the budget — but **does** recurse into children. A noisy parent (label-less Toolbar) may wrap real content (labelled Search field). Subtree drops (full prune) come from `.skipSubtree` only, which is the masker's call.

## Bypass: how it can't happen

`AccessibilityTree.snapshot(activeBundleID:)` returns `RedactedAXSnapshot`. There is no API to extract raw text — `RedactedAXSnapshot.formattedForPrompt()` is the only readable accessor, and it has already gone through `SecureFieldMasker`. Same for `RedactedScreenText`. New code that needs the on-screen text **must** consume one of these types — anything else is a security regression.

## Threats not in scope

- Password manager auto-fill overlays with a visible password on screen (rare; managers obscure by default).
- Custom apps using `AXTextField` for password input instead of `AXSecureTextField` — identifier-based heuristics catch most; the content-pattern layer catches token-shaped values; free-form text-typed passwords that don't match any pattern can slip.
- Cloud-provider keys outside the covered set (Azure storage, GCP service-account JSON, DigitalOcean tokens, etc.) — caught by the 40-char generic opaque-token rule with a generic label. Add a specific rule + test if a provider format slips past.
- Terminal emulators outside the hardcoded `AXNoiseFilter.knownTerminalBundleIDs` set (Tabby, Termius, Rio, Cool Retro Term, BlackBox, …). Their `AXTextArea` scrollback ships into `On-screen context:` unredacted; `SecureFieldMasker.scrubContent` only catches token-shaped secrets, not free-form content like `echo $DB_PASSWORD` left in scrollback. Extend the set when a new emulator becomes common — see `solutions/documentation-gaps/dynamic-terminal-detection-2026-05-18.md` for the long-term `AppCategorizer` path.

## Testing

- `NoTypeTests/SecureFieldMaskerTests.swift` — both layers (skip + content) plus empty-value and idempotence paths.
- `NoTypeTests/AXNoiseFilterTests.swift` — 59 cases pinning every noise predicate (R4 chrome (full inventory-lock), R5 terminal-parent gate, R6 pack-collapse with negative cases incl. meeting-with-participant-suffix regression, R7 length floor + CJK).
- `NoTypeTests/AccessibilityTreeTests.swift` — 25 cases pinning `decideForNode` pipeline ordering (R8 masker precedence), `budgetForApp` routing, `applyGlobalCap` active-first sort + truncation, and the `formattedForPrompt` rendering contract.
- `NoTypeTests/PromptEvalTests.swift` — live-API anti-leak test (AX-only token must not appear in transcript). Positive-spelling complement is tracked at `solutions/documentation-gaps/positive-spelling-ax-fixture-2026-05-18.md` (pending audio recording).
- No tests against live apps in unit tests.

## Pointers

- Why full-screen AX walk → `solutions/design-patterns/full-screen-ax-tree-2026-05-15.md`.
- Why OCR fallback (opt-in via TCC) → `solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md`.
- `Insertion target` prompt section + cache-prefix shape → `NoType/Gemini/CLAUDE.md`.
- Privacy posture (no telemetry; local-only carve-out) → `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`.
- Noise-filtering rationale + plan → `docs/plans/2026-05-17-002-refactor-ax-tree-noise-filtering-plan.md`.
