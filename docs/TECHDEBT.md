# Tech debt

Running list of known engineering improvements that are intentionally *not* shipped yet. None of these blocks normal use of NoType. They live here so the same observation doesn't get raised twice in audits, and so anyone with a spare hour has a curated pick list.

Add items as we spot them. Remove items as we close them — and reference the closing commit in the PR description.

## Working with this file

Treat this file as a first-class artifact, not a parking lot:

- **Found a problem you're not fixing right now?** Add an entry. Use the format below (Title / Where / What / Why it's debt / Rough size). Don't open another "todo file" — this is the one.
- **Fixing something already listed?** Remove the entry in the same commit that closes the work, and reference the commit hash in the PR description so future readers can trace it.
- **Audit / planning pass?** Read this file before brainstorming new debt — chances are the observation is already there with context.
- **Items belong here, not in code comments.** `// TODO:` strings are second-class — they don't aggregate, they don't survive grep across refactors, and they don't carry the "why we didn't fix it yet" rationale. Promote any `TODO` you find to an entry here.

Format per item:

> ### Title
> **Where:** `Module/File.swift:line` or `Module/`
> **What:** one-paragraph description of the current behaviour and what would be better.
> **Why it's debt (not a bug):** why we ship without it.
> **Rough size:** XS / S / M / L estimate of effort.

---

## Recording

### In-memory AAC encoding

**Where:** `NoType/Recording/ChunkBuilder.swift`.
**What:** `encodeAAC` round-trips PCM through an `AVAudioFile` written to a temp file, then reads the file back into `Data`. The temp file lives in `NSTemporaryDirectory()` (disk-backed on macOS) and adds ~20–50 ms of syscall overhead per chunk on Apple Silicon SSDs.
**Why it's debt:** none of Apple's high-level APIs (`AVAudioFile`, `AVAssetWriter`) support memory-only sinks; the in-memory path requires dropping to `AudioFile` + `AudioFileInitializeWithCallbacks` + a custom byte-sink callback paired with `AudioConverter`-based PCM → AAC, then a hand-built M4A container. That's ~150–200 lines of CoreAudio plumbing with its own fixture-encoded test set. The 20–50 ms penalty is real but doesn't dominate a session's wall-clock (Gemini round-trip is ~500–1500 ms).
**Rough size:** L.

### SileroVAD CoreML vs ONNX reference test

**Where:** `NoType/Recording/SileroVAD.swift`.
**What:** The Recording CLAUDE.md asks us to verify the CoreML conversion of Silero v6 unified-256 produces the same outputs as the reference ONNX model within tolerance. We have fixture-driven tests for `PauseDetector` and `ChunkBuilder` but not for `SileroVAD` itself.
**Why it's debt:** the model has been stable in production. A regression would manifest as users reporting cut-off start syllables — visible quickly. But a pinned fixture comparison would catch silent drift on a model swap.
**Rough size:** M (needs short voiced/unvoiced fixture clips plus a reference-output JSON we generate once and commit).

## Context

### AccessibilityTree fixture-driven tests

**Where:** `NoType/Context/AccessibilityTree.swift`.
**What:** No `AccessibilityTreeTests.swift` exists. The tree walker has subtle invariants (depth cap, per-app node budget, per-app cancellation, total budget, `truncated` flag) that we could lock down with a synthetic `MockAXNode` graph driving the walk via a thin protocol.
**Why it's debt:** the walker has been stable since launch; nothing has regressed it. But refactoring it (e.g. when we wire the real per-app deadline check on a tighter loop) deserves a regression net.
**Rough size:** M (mock graph type + ~10 cases).

## Context

### Settings section for screen-capture fallback

**Where:** Not yet present in the project; `NoType/UI/SettingsView.swift` would gain the new section.
**What:** The screenshot + OCR fallback (ADR-014) is currently gated purely by Screen Recording TCC permission state. Granting in onboarding (or System Settings) turns the feature on; there is no in-app way to disable it without revoking the TCC grant. Settings should expose: status badge (granted/denied/needed), an explicit "Use screen capture for context" toggle that gates the runtime independently of permission, a "Re-open onboarding step" link, and a short explanation of when the fallback fires.
**Why it's debt:** v1 ships the feature behind the simplest possible gate so we don't expand the Settings sheet during the same change. A user who wants OCR off but doesn't want to revoke permission has no recourse — acceptable in beta, not long-term.
**Rough size:** S (one new section in the existing sheet + a `UserDefaults` flag honoured by `RecordingSession.start`).

## DX

### `pre-existing` items I'll record as I find them

(Empty — add as encountered.)
