# Context module

**Security boundary.** The module captures on-screen context that ships to Gemini. Any code path that lets raw AX content or pixel-derived text reach the network is a bug.

## Files

- `AccessibilityTree.swift` — walks the AX trees of **all on-screen windows** (parallel `withTaskGroup`).
- `ContextSnapshot.swift` — value types: `AppInfo`, `RedactedAXSnapshot`, `RedactedScreenText`, `InsertionTarget`, `ContextSnapshot`.
- `SecureFieldMasker.swift` — **security-critical**. Skip rules + value-content scrubbing patterns.
- `ScreenCapture/ScreenCaptureController.swift` — `ScreenCaptureKit` wrapper for active-window screenshots.
- `ScreenCapture/TextRecognizer.swift` — `Vision` OCR wrapper.
- `ScreenCapture/ScreenCaptureContext.swift` — orchestrator. Permission gate → capture → OCR → per-line `SecureFieldMasker.scrubContent` → `RedactedScreenText?`.

`InsertionTarget.captureSync()` reads the focused field's value + cursor; the active-app fact is read directly from `NSWorkspace.frontmostApplication` in `RecordingSession.start()`.

## Invariants

1. **`AccessibilityTree.snapshot()` returns `RedactedAXSnapshot`, never raw text.** Type-level masking enforcement — no public API lets raw AX content reach the network.
2. **`ScreenCaptureContext.capture(...)` returns `RedactedScreenText?`** with a module-internal initializer. Same shape as `RedactedAXSnapshot` — no public path from raw `CGImage` text to the network.
3. **OCR sub-block is included only when AX returned contentless for the active app** (`tree.hasContent(for:) == false`). Otherwise the OCR result is discarded.
4. **OCR runs only when Screen Recording TCC permission is granted.** When ungranted, the OCR limb never spawns — behaviour is identical to the AX-only path.
5. **Independent per-task wall-clock caps; partial results survive.** AX 1500 ms cap, OCR 2500 ms cap. AX timeout → OCR result used with empty-tree fallback. OCR timeout → AX result used alone. No joint deadline.
6. **`InsertionTarget` is captured once at session start; cursor doesn't move during a session** (user holds the hotkey). The section ships even when `.unknown` — empty strings, but the section stays so the prefix shape is stable.
7. **`InsertionTarget.captureSync()` refuses to read `AXSecureTextField` outright.** Returns `.empty` rather than attempting to read the value.

## Hard rules

- **Any change to `SecureFieldMasker.swift` must add a new test case to `NoTypeTests/SecureFieldMaskerTests.swift`.** Security boundary. No exceptions.
- **Any change to the path between Vision output and the prompt must add a `SecureFieldMaskerTests` case under the `// MARK: - OCR fallback consumer` section.** Same reason.
- **All on-screen apps' AX trees are walked**, not just the focused window. NoType's own bundle is filtered (`selfBundleID`).
- **Skip-rule layer + content-pattern layer are both required.** Role-based skip runs first; content scrub runs after — neither is sufficient alone.
- **Pattern order in `SecureFieldMasker.scrubContent` is load-bearing.** More-specific patterns (JWT, GitHub PAT, Google API key) must hit before more-generic ones (40-char opaque token). Add new patterns above the catch-all, not below.

## Walker bounds

- Total nodes: 5000. Above this, snapshot truncates with `truncated = true`.
- Per-app nodes: 800.
- Max depth per window: 6.
- Max value length per node: 2000 chars (truncated with `…`).
- Per-app wall-clock: 100 ms — races a `Task.sleep` sentinel inside `withTaskGroup`. Both `walkApp` and `walk` poll `Task.isCancelled` at every window and recursion step.

## Bypass: how it can't happen

`AccessibilityTree.snapshot()` returns `RedactedAXSnapshot`. There is no API to extract raw text — `RedactedAXSnapshot.formattedForPrompt()` is the only readable accessor, and it has already gone through `SecureFieldMasker`. Same for `RedactedScreenText`. New code that needs the on-screen text **must** consume one of these types — anything else is a security regression.

## Threats not in scope

- Password manager auto-fill overlays with a visible password on screen (rare; managers obscure by default).
- Custom apps using `AXTextField` for password input instead of `AXSecureTextField` — identifier-based heuristics catch most; the content-pattern layer catches token-shaped values; free-form text-typed passwords that don't match any pattern can slip.
- Cloud-provider keys outside the covered set (Azure storage, GCP service-account JSON, DigitalOcean tokens, etc.) — caught by the 40-char generic opaque-token rule with a generic label. Add a specific rule + test if a provider format slips past.

## Testing

- `NoTypeTests/SecureFieldMaskerTests.swift` — both layers (skip + content) plus empty-value and idempotence paths.
- `AccessibilityTreeTests.swift` — planned (see `solutions/documentation-gaps/accessibility-tree-fixture-tests-2026-05-15.md`).
- No tests against live apps in unit tests.

## Pointers

- Why full-screen AX walk → `solutions/design-patterns/full-screen-ax-tree-2026-05-15.md`.
- Why OCR fallback (opt-in via TCC) → `solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md`.
- `Insertion target` prompt section + cache-prefix shape → `NoType/Gemini/CLAUDE.md`.
- Privacy posture (no telemetry; local-only carve-out) → `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`.
