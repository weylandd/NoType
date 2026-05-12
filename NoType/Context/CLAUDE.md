# Context module

**This is a security boundary.** Read fully before touching anything here.

This module captures on-screen context that's sent to Gemini for transcription accuracy. It walks the **full-screen accessibility tree** and produces a redacted snapshot. Any code that sends raw AX content to the network is a bug.

Files:
- `AccessibilityTree.swift` — walks AX trees of all on-screen windows.
- `ContextSnapshot.swift` — value types: `AppInfo`, `RedactedAXSnapshot`, `RedactedScreenText`, `InsertionTarget`, `ContextSnapshot`. The snapshot also carries the session's resolved `AppCategory`, the frozen user instruction, and the resolved category instruction — see `NoType/Instructions/CLAUDE.md`. `InsertionTarget.captureSync()` is the focused-field capture; the active-app fact is read directly from `NSWorkspace.frontmostApplication` in `RecordingSession.start()` (no dedicated `ActiveAppDetector.swift`).
- `SecureFieldMasker.swift` — replaces sensitive content. **Security-critical file in the project.**
- `ScreenCapture/ScreenCaptureController.swift` — `ScreenCaptureKit` wrapper that grabs a `CGImage` of the active window for a given pid (~10–30 ms on Apple Silicon).
- `ScreenCapture/TextRecognizer.swift` — `Vision` wrapper, `VNRecognizeTextRequest` at `.accurate` level with auto-language (~100–300 ms per window).
- `ScreenCapture/ScreenCaptureContext.swift` — orchestrator. Permission gate → capture → OCR → per-line `SecureFieldMasker.scrubContent` → `RedactedScreenText?`. **Security-relevant — see the section below.**

---

## Why full-screen, not just the focused window

See ADR-009 in `docs/decisions.md`. Short version: richer context (sidebar names, adjacent docs, neighbor windows) meaningfully improves transcription of proper nouns and jargon. The cost is larger payload + stricter masking requirements; we accept both.

---

## Insertion target — focused field + cursor position

Captured **in addition to** the on-screen tree, on session start. Sent as a separate, fixed-label section in the Gemini prompt so the model knows the exact strings on either side of the cursor — driving capitalization, whitespace, and terminal-punctuation choices for the dictated text.

The section appears in the request between the optional `Category instruction:` part (or `App: ... / Category:` when both `User instruction:` and `Category instruction:` are omitted) and `On-screen context:`. The label `Insertion target:` and the sub-labels `Text before cursor:` / `Text after cursor:` are referenced verbatim by the system instruction — do not rephrase them. See `NoType/Gemini/CLAUDE.md` for the full request shape.

### Capture (real shape — see `ContextSnapshot.swift`)

```swift
struct InsertionTarget: Sendable, Equatable {
    let textBefore: String   // up to maxSideLength chars before cursor (scrubbed)
    let textAfter: String    // up to maxSideLength chars after cursor (scrubbed)

    static let empty = InsertionTarget(textBefore: "", textAfter: "")
    static let maxSideLength = 500

    static func capture() async -> InsertionTarget { /* runs captureSync() off-actor */ }
    static func captureSync() -> InsertionTarget    { /* AX walk, see below */ }
}
```

`captureSync()`:

1. Get the system-wide focused element via `AXUIElementCreateSystemWide()` + `kAXFocusedUIElementAttribute`.
2. **Refuse** to read password fields outright — if `kAXRoleAttribute` or `kAXSubroleAttribute` is `"AXSecureTextField"`, return `.empty`. The focused-field path must never be a way around `SecureFieldMasker`'s skip rules.
3. Read `kAXValueAttribute` (the field's text). If missing — common for Electron/web-view text fields — return `.empty`.
4. Resolve the cursor position. Prefer `kAXSelectedTextRangeAttribute`; fall back to `kAXInsertionPointLineNumberAttribute` + `kAXRangeForLineParameterizedAttribute`; worst case, assume cursor at end of value. macOS counts AX ranges in UTF-16 code units, so we slice on UTF-16 boundaries.
5. Trim each side to `maxSideLength = 500` chars.
6. Run `SecureFieldMasker.scrubContent` over **both** sides — bearer tokens / card numbers / API keys at the cursor must be scrubbed before they enter the prompt. (Skip-rule enforcement is upstream in step 2; this is the value-content layer.)

### Edge cases — all collapse to `.empty`, the section is NEVER dropped

- No focused element (`AXUIElementCopyAttributeValue` fails or returns `nil`).
- Element is `AXSecureTextField` (role or subrole).
- Element has no `kAXValueAttribute` (read-only views, terminals, custom NSText, many Electron/web-views).
- All cursor-resolution paths fail (we silently default to end-of-value).
- Composite Unicode / emoji at the boundary: UTF-16 slicing matches macOS's own range semantics, so we don't split codepoints macOS itself wouldn't split. If a slice still lands on a surrogate pair, we fall back to a lossy decode (U+FFFD) rather than dropping the side.

When any of these happen, `textBefore = ""` and `textAfter = ""`. The section still goes into the prompt with empty values — dropping it would change the prefix shape and break implicit caching across sessions.

### Why captured once, not refreshed

During a recording session, the user is holding the hotkey and not typing. The cursor cannot move. So this section is stable for the whole session and lives in the cached prefix alongside the AX snapshot.

If the user releases and presses again (a new session), `capture()` runs again — by then they may have moved to a different field.

### Privacy

The focused field can contain sensitive content (a half-typed message, a URL with a token in the query string, an email draft). The `maxSideLength = 500` cap is a soft mitigation — we don't ship the entire textarea. Stronger controls are out of scope for v1; revisit if a high-trust deployment surfaces complaints.

---

## What we walk

1. Get all running apps with windows: `NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }`, minus `com.apple.systemuiserver`, `com.apple.dock`, and our own bundle ID.
2. For each app, in parallel via `withTaskGroup`, get its AX element: `AXUIElementCreateApplication(pid)`.
3. Get the app's windows via `kAXWindowsAttribute`.
4. For each non-minimized window, recursively walk children up to `perWindowDepth = 6`.
5. Collect from each node: role, subrole, role description, title, value (subject to masking).

Bounds:
- **Total node budget: 5000.** If we hit this across all apps, stop and ship what we have (`truncated = true`).
- **Per-app node budget: 800.** Prevents a single chatty app (e.g. browser with many tabs) from eating the whole budget.
- **Max depth per window: 6.** AX trees can be very deep, especially in browsers; deeper nodes are usually not informative.
- **Max value length: 2000 chars per node.** Truncated with `…`.
- **Per-app wall-clock: 100 ms.** A wedged app stalls when you ask for its AX tree; we move on without it. `dumpApp` races the synchronous `walkApp` against a `Task.sleep` in a `withTaskGroup` and `cancelAll`s on the winner. Both `walkApp` and `walk` poll `Task.isCancelled` at every window and at every recursion step, so after the deadline fires the background walk actually short-circuits within at most one AX attribute fetch. Latency *and* CPU are bounded.

We **do** include our own app (NoType) in the candidate list as a safety net, but skip it explicitly via `selfBundleID` — our own UI shouldn't appear in our own prompt, and we have no visible window during recording anyway.

---

## Output format

The snapshot serializes to text that's pasted into the Gemini prompt. Format:

```
=== Mail (com.apple.mail) ===
Window: "Inbox — me@example.com"
  - Toolbar "Toolbar"
    - Button "New Message"
    - Button "Reply"
  - List "Mailbox list"
    - StaticText "Inbox" = 12
    - StaticText "Sent"
  - StaticText "Hi team, I'd like to schedule the Q3 review for next Tuesday..."

=== Slack (com.tinyspeck.slackmacgap) ===
Window: "engineering — Acme Corp"
  ...
```

Plain text, no XML, no JSON. Compact and readable for the model. `(context truncated — node budget exceeded)` is appended when the global cap fires.

---

## Secure-field masking — MANDATORY

`SecureFieldMasker` runs on every collected value before it joins the snapshot. It returns a `MaskAction`:

- `.skip(reason:)` — drop the whole node, do not descend into children.
- `.replace(scrubbed, reason:)` — keep the node, swap its value for the scrubbed text.
- `.keep(raw)` — keep the node and the value as-is.

### Skip rules (entire node, value never collected)

A node is skipped if **any** of:

1. `AXRole == "AXSecureTextField"`.
2. `AXSubrole == "AXSecureTextField"`.
3. `AXRoleDescription` contains `"secure"` (case-insensitive).
4. `AXIdentifier` contains any of: `password`, `passcode`, `pin`, `secret`, `token`, `apikey`, `credential` (case-insensitive substring).
5. The node's parent has `AXRole == "AXSheet"` and the sheet's title matches `/password|secret|sign\s*in|sign\s*on|two[-\s]?factor|authentication/i`.

### Value-content masking (node kept, value scrubbed)

Even when a node is not skipped, its value runs through these patterns in order (more specific first):

Patterns run in this order (more specific → catch-all). The order is load-bearing: a JWT must hit the JWT rule (informative label) before the generic 40-char opaque-token rule eats it with a vaguer label.

| Pattern | Action |
|---|---|
| Credit card: `\b(?:\d[ -]*?){13,19}\b` with Luhn check | Replace with `[REDACTED — likely card number]` |
| Bearer/Basic auth: `(?i)(bearer\|basic)\s+[A-Za-z0-9._\-+/=]{20,}` | Replace with `[REDACTED — likely auth header]` |
| PEM private key block: `-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----(?:[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----)?` (END marker optional — covers AX truncation at 2000 chars) | Replace with `[REDACTED — private key]` |
| JWT: `\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b` (anchored on `eyJ` = base64 of `{"`) | Replace with `[REDACTED — likely JWT]` |
| GitHub tokens: `\b(?:gh[pousr]_[A-Za-z0-9]{30,}\|github_pat_[A-Za-z0-9_]{40,})\b` | Replace with `[REDACTED — likely GitHub token]` |
| Google API keys: `\bAIza[0-9A-Za-z_\-]{35}\b` (39 chars — under the generic opaque-token threshold; load-bearing for the user's own Gemini key) | Replace with `[REDACTED — likely Google API key]` |
| OpenAI / Anthropic: `(?i)\bsk-(?:ant-)?[A-Za-z0-9_\-]{20,}\b` (hyphen separator — distinct from Stripe's `sk_test_…`) | Replace with `[REDACTED — likely API key]` |
| Slack tokens: `\bxox[a-z]-[A-Za-z0-9-]{10,}\b` | Replace with `[REDACTED — likely Slack token]` |
| Stripe keys: `(?i)\b(sk\|pk\|rk)_(test\|live)_[A-Za-z0-9]{16,}\b` | Replace with `[REDACTED — likely API key]` |
| AWS keys: `\bAKIA[0-9A-Z]{16}\b` | Replace with `[REDACTED — AWS key]` |
| URL creds: `://[^/\s:@]+:[^/\s@]+@` | Replace match with `://[REDACTED — url creds]@` (scheme and host preserved) |
| Long opaque token: `\b[A-Za-z0-9_\-]{40,}\b` (with letter+digit gate) | Replace with `[REDACTED — likely token]` |

**False-positive ceiling.** The generic opaque-token rule deliberately stays at 40 chars to avoid redacting short alphanumeric strings the AX context routinely contains: version numbers (`v0.1.0`), model names (`iPhone15`, `MacBook4`), build / artefact tags, OS labels (`macOS26`, `Xcode26`), issue numbers (`issue1234`). Lowering the threshold trades AX-context fidelity (the whole reason we walk the screen) for marginal extra redaction, and the explicit prefix-anchored rules above already cover the high-value targets. `SecureFieldMaskerTests.test_keep_shortAlphanumericProductTokens` pins this decision.

The masker is a pure function: `(value, NodeMetadata) -> MaskAction`. Easy to unit-test.

### Type-level guarantee

`AccessibilityTree.snapshot()` returns `RedactedAXSnapshot`, **not** `String`. There is no public API that returns raw AX text from this module. To get the network-shippable text, call `RedactedAXSnapshot.formattedForPrompt()`. This makes it impossible to accidentally bypass masking.

```swift
public struct RedactedAXSnapshot: Sendable, Equatable {
    let apps: [RedactedAppDump]
    let truncated: Bool
    public func formattedForPrompt() -> String { ... }
}
```

---

## Refresh strategy

- Snapshot is taken **once** when `RecordingSession.start()` runs.
- If the user switches frontmost app mid-recording (rare — the user is holding the hotkey), we **do not** rebuild the snapshot. The captured `activeApp` reflects the app at press time; the paste target reflects whatever has focus at release time (whoever receives ⌘V).
- Snapshot is held by the session, dropped on session end. Not persisted, not logged.

---

## Performance

Walking 5–10 apps with several windows can take **50–200 ms**. This is on the critical path between hotkey press and "ready to record" — though audio capture begins immediately, so we don't lose phonemes.

Optimizations:
- Walk apps in parallel via `withTaskGroup`.
- Each app's walk has a 100 ms wall-clock cap (see the caveat in "What we walk" above re: cancellation).
- Cache nothing across sessions — AX state changes constantly.

**The first chunk waits for the snapshot.** Audio capture starts immediately on hotkey press (we fill the PCM buffer), and the sender awaits `contextTask.value` before issuing the first Gemini call. A doc-promised explicit `VAD-gate + 250 ms hard timeout` is tracked as a code improvement; today the gate is implicit (the sender's `await` on the context task).

---

## Screen capture fallback (optional)

See ADR-014. When the AX walk returns no usable content for the active app's bundle id (the typical Electron / web-view / custom-NSText failure mode), we screenshot the active window, run local Vision OCR, scrub the result, and append it to the existing `On-screen context:` prompt part. This is **opt-in via Screen Recording TCC permission** — when the permission is not granted, none of this runs and behaviour is identical to the AX-only path.

### When the OCR sub-block enters the prompt

Computed once in `RecordingSession.start`'s `contextTask` after both AX and OCR settle. The OCR sub-block is included iff **all** of:

1. `ScreenRecordingPermission.current() == .granted` at session start.
2. The screenshot + OCR pipeline succeeded (the `RedactedScreenText?` returned is non-nil).
3. `RedactedAXSnapshot.hasContent(for: activeApp.bundleID) == false` — the trigger predicate. True when the active app's `RedactedAppDump` is missing, has no windows, or every window has an empty `lines` array.

The decision is logged once: `ocr=on (ax-empty-for-active-app)` or `ocr=off (reason)`. The full list of `ocr=off` reasons:
- `no-permission` — Screen Recording was not granted at session start (no OCR limb spawned).
- `ax-has-content` — AX returned usable content for the active app; OCR ran in parallel but result was dropped.
- `capture-failed-or-empty` — OCR was permitted but `ScreenCaptureContext.capture` returned nil (no on-screen window, capture/OCR throw, deadline cancellation).

### Type-level guarantee

`ScreenCaptureContext.capture(activeApp:pid:)` returns a `RedactedScreenText?` whose initializer is module-internal. The only way to get text into a `RedactedScreenText` from this module is through `SecureFieldMasker.scrubContent` per line. There is no public accessor for unscrubbed lines — mirrors the `RedactedAXSnapshot` pattern. **No code path ships raw pixel-recognised text to the network.**

### Pipeline detail

1. **Permission gate.** `ScreenRecordingPermission.current()` — cheapest stage. Most common no-result reason in production.
2. **Capture.** `ScreenCaptureController.captureActiveWindow(pid:)` uses `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)` to enumerate windows, filters to `owningApplication.processID == pid && windowLayer == 0`, picks the largest by area (= the focused window), and grabs it via `SCScreenshotManager.captureImage(contentFilter:configuration:)` at 2× the window's logical frame for OCR fidelity. `showsCursor = false` so the cursor doesn't pollute recognition.
3. **OCR.** `TextRecognizer.recognize(_:)` runs a single `VNRecognizeTextRequest` with `recognitionLevel = .accurate`, `usesLanguageCorrection = true`, `automaticallyDetectsLanguage = true`. Returns one string per observation in reading order; empty strings dropped.
4. **Scrub.** Each line goes through `SecureFieldMasker.scrubContent`. The same pattern table that protects AX content — cards (Luhn), bearer / basic headers, JWTs, GitHub / Google / OpenAI / Slack / Stripe / AWS keys, PEM private-key blocks, URL creds, 40-char opaque tokens. The skip-rule layer (role-based) doesn't apply to pixels but `scrubContent` is the right defence; new tests under `// MARK: - OCR fallback consumer` in `SecureFieldMaskerTests` pin the OCR-shaped inputs we expect Vision to surface.
5. **Budget.** `ScreenCaptureContext.maxLines = 200` and `maxTotalChars = 8_000`. Above either threshold we stop and set `truncated = true` — surfaced in the prompt so the model knows it has partial coverage.

### Deadline contract — independent per-task caps

Inside `RecordingSession.start`'s `contextTask` each subtask gets its **own** wall-clock cap; there is no joint deadline that can discard a successful result because a sibling overran:

| Subtask | Cap | Notes |
|---|---|---|
| `AccessibilityTree.snapshot()` | **1500 ms** safety cap | Internal walker is already bounded (100 ms / app, 5000-node total budget). Typical 50–200 ms. Cap only fires on pathological AX wedges. |
| `InsertionTarget.capture()` | uncapped | Synchronous AX read on the focused element; typical <50 ms. |
| `ScreenCaptureContext.capture(...)` | **2500 ms** safety cap | Vision OCR typical 100–500 ms. Cap protects against dense-screen / wedged-Vision pathological cases. |

Each cap is implemented via `RecordingSession.withDeadline(ms:_:)` — races the subtask against a `Task.sleep` sentinel inside a local `withTaskGroup`; cancels the loser. Cancellation is cooperative: AX polls `Task.isCancelled`, Vision pipelines can't be interrupted mid-pass but typically complete well under cap.

**Why no joint deadline.** The sender's `await contextTask.value` before the first Gemini call serialises chunk dispatch. The first audio chunk can't arrive until VAD detects a ≥1 s pause OR the user releases the hotkey. So for any session longer than ~1 s, the OCR latency is masked by speech time — the user never feels it. Quick-release sessions (<500 ms hotkey hold) are the only case where caps matter for perceived latency; we accept up to ~2.5 s of paste delay in that edge case.

**Partial results survive.** If AX times out, we fall back to an empty `RedactedAXSnapshot` and the trigger predicate (`hasContent(for:) == false`) will fire — OCR result, if available, is included. If OCR times out, AX result is used alone. The previous joint-deadline design discarded both on either overrun; v1 testing in Mail showed this throwing away ~30 % of OCR-eligible sessions, which motivated the redesign.

### Hard rule (mirrors the SecureFieldMasker rule)

- Any change to `ScreenCaptureContext.swift` must add a `ScreenCaptureContextTests` case (predicate / formatter / permission gate).
- Any change to the path between Vision output and the prompt must add a `SecureFieldMaskerTests` case under the `// MARK: - OCR fallback consumer` section.

No exceptions.

---

## Threats not in scope

- **Password manager auto-fill at the moment of recording.** If 1Password's overlay is on screen with a visible password (rare; they obscure by default), masking heuristics may miss it — applies to both AX and OCR. Acceptable risk for v1; revisit if reports arrive.
- **Custom apps that use `AXTextField` for password input** instead of `AXSecureTextField`. We can't detect this. Mitigation: identifier-based heuristics catch most of them on the AX path; on the OCR path the content-pattern scrubber catches token-shaped values but not free-form text-typed passwords that don't match any pattern.
- **Cloud-provider keys outside the covered set.** Azure storage keys, GCP service-account JSON blobs, DigitalOcean tokens, etc. are not pattern-matched today. Most still get caught by the 40-char opaque-token catch-all (with a generic `likely token` label); add a dedicated rule + test if a specific provider's format slips past it.

---

## Testing

`SecureFieldMaskerTests.swift` is required reading for changes here. The pattern:

```swift
func testMasksAXSecureTextField() {
    let result = SecureFieldMasker.mask(
        value: "hunter2",
        metadata: .init(role: "AXSecureTextField")
    )
    XCTAssertEqual(result, .skip(reason: "secure role"))
}

func testMasksCreditCard() {
    let result = SecureFieldMasker.mask(
        value: "4111 1111 1111 1111",
        metadata: .init(role: "AXTextField")
    )
    XCTAssertEqual(result, .replace("[REDACTED — likely card number]", reason: "content"))
}
```

**Hard rule:** any change to `SecureFieldMasker.swift` must add at least one new test case to `NoTypeTests/SecureFieldMaskerTests.swift` that motivated the change. No exceptions.

`SecureFieldMaskerTests.swift` covers both layers (skip rules + content patterns) plus the empty-value and idempotence paths. `AccessibilityTreeTests.swift` would use synthetic AX trees (a `MockAXNode` graph) to verify walking, depth limits, and snapshot serialization — still planned.

We do **not** test against live apps in unit tests.
