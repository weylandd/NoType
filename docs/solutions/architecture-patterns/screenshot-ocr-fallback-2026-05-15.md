---
title: Optional screenshot + OCR fallback for AX-poor apps
date: 2026-05-15
category: architecture-patterns
module: Context
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - Improving context coverage on Electron / web-view apps
  - Considering Gemini multimodal (sending screenshots directly)
  - Auditing the screen-capture path for privacy regressions
tags: [accessibility-tree, ocr, vision, screencapturekit, electron, fallback, privacy, opt-in]
---

# Optional screenshot + OCR fallback for AX-poor apps

## Context

The AX walk gives Gemini cross-window context for proper-noun disambiguation — but it returns nothing usable for apps that don't expose their content via Accessibility:

- Electron (Slack, Discord, VS Code).
- Web-views (Notion, Linear web, Figma).
- Custom-NSText apps.

These are exactly the apps users dictate into most. Without a fallback, transcription quality on them is "no context at all".

## Guidance

**When the active app's AX dump is contentless, fall back to a screenshot of the active window + local Vision OCR.**

Pipeline (`NoType/Context/ScreenCapture/`):

1. **Permission gate** — `ScreenRecordingPermission.current()` must be `.granted`. If not, skip the entire limb.
2. **Capture** — `ScreenCaptureKit` (`SCScreenshotManager.captureImage` against the focused window for the session's `pid`).
3. **OCR** — `Vision` (`VNRecognizeTextRequest`, `.accurate`, auto-language).
4. **Scrub** — every recognised line through `SecureFieldMasker.scrubContent` (cards, bearer tokens, JWTs, GitHub / OpenAI / Google / Slack / Stripe / AWS keys, PEM blocks, URL creds, 40-char opaque tokens).
5. **Embed** — appended **inside** the existing `On-screen context:` Gemini prompt part as a `--- Screen text (OCR — active window) ---` sub-block. **Not** a new top-level prompt part.

The feature is **opt-in via the Screen Recording TCC permission** with **no separate Settings toggle in v1**.

## Why This Matters

- **AX is genuinely the best source when it works.** OCR-everything would inflate tokens and lose the metadata-driven `SecureFieldMasker` skip-rule layer for password fields.
- **The fallback recovers exactly the apps users live in.** Slack, Discord, Notion, web inboxes — high-leverage targets that AX leaves blank.
- **Local Vision OCR (not Gemini multimodal) keeps privacy explicit.** Pixels never reach Gemini; recognised text is scrubbed before it enters the prompt; no screenshots are persisted.
- **Embedding inside the existing `On-screen context:` part preserves the implicit-cache contract.** Pinned by `GeminiRequestBuilderTests.test_partOrderAndLabels_stableWithAndWithoutOCR`. A new top-level part would change the cached prefix shape.

## When to Apply

- Per session, automatically — the contextTask runs OCR in parallel with the AX walk; the OCR result is used **only** when the AX dump for the active app's bundle id is contentless (`tree.hasContent(for:) == false`); otherwise it's discarded.
- Reconsider when:
  - Apple ships a sandboxed equivalent that doesn't require Screen Recording permission.
  - We find an OCR-text shape the masker doesn't cover and users report leakage. Extend `SecureFieldMasker` rather than disabling the fallback.

## Examples

**Decisions inside the decision:**

- **Active window only.** Full-screen OCR would be ~2× the cost and dramatically widen the privacy surface.
- **OCR is on the critical path of the first chunk** (but masked by VAD timing). The first audio chunk can't be produced until VAD detects a ≥1 s pause OR the user releases, so for any session > 1 s the OCR latency is masked by speech time.
- **Type-level guarantee preserved.** `ScreenCaptureContext.capture(...)` returns `RedactedScreenText?` with a module-internal initializer — same shape as `RedactedAXSnapshot`. There is no public path from raw `CGImage` text to the network.
- **Independent per-task wall-clock caps.** AX 1500 ms, OCR 2500 ms — both run as siblings; partial results survive (AX timeout doesn't discard OCR; OCR timeout doesn't discard AX). The previous joint-deadline design discarded both on either overrun and was deliberately replaced after observing Mail timeouts in v1 testing.

**Trade-offs accepted:**

- Quick-release sessions (< 500 ms hotkey hold) may add up to ~2.5 s of perceived latency if OCR is slow on a dense screen. Realistic median is 100–500 ms. Acceptable: short utterances rarely benefit from OCR-context disambiguation anyway. The lite-path optimisation skips OCR entirely for the shortest sessions.
- On AX-rich apps, we run OCR in parallel and discard the result (~150 ms of CPU we paid for nothing). Acceptable — the alternative (serial: wait for AX, then conditionally start OCR) would add ~150 ms to the first chunk in the AX-poor case where the user feels the latency.
- Softens the "no screen recording" line from the no-telemetry stance to **"no screen recording by default"**. The capability exists, requires explicit user action, and never persists pixels.

**Alternatives that were rejected:**

- **Always OCR (replace AX).** Loses cross-window context AX provides on Mail / Xcode / etc.
- **Always run both, always include OCR in prompt.** Bloats the cached prefix by 2–5K tokens even when AX was sufficient.
- **Gemini multimodal (send the JPEG itself).** Cannot scrub pixels client-side, worse for privacy.

## Related

- `NoType/Context/CLAUDE.md` "Screen capture fallback (optional)" — implementation detail.
- `docs/decisions.md` ADR-014 — legacy index entry, redirects here.
- `solutions/design-patterns/full-screen-ax-tree-2026-05-15.md` — the AX walk this fallback complements.
- `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md` — the no-telemetry stance that this softens to "by default".
- `architecture.md` invariant I7 — secure-field masking, type-level guarantee.
