# Tech debt

Known engineering improvements that are intentionally *not* shipped yet. None of these block normal use of NoType.

Tech-debt entries live as per-item files under [`docs/solutions/documentation-gaps/`](solutions/) following the compound-engineering knowledge-track shape (`Context → Guidance → Why This Matters → When to Apply → Examples → Related`). This file is the index — adding a new item means writing a new file in `docs/solutions/documentation-gaps/` and adding a one-line link below.

See `docs/solutions/README.md` for the frontmatter contract and body structure.

## Current entries

- [In-memory AAC encoding for audio chunks](solutions/documentation-gaps/in-memory-aac-encoding-2026-05-15.md) — **L**; `ChunkBuilder.encodeAAC` round-trips through a temp file.
- [SileroVAD CoreML vs ONNX reference test](solutions/documentation-gaps/silero-vad-reference-test-2026-05-15.md) — **M**; no `SileroVADTests.swift`.
- [Aggregate-device handling in the BT-input-avoidance policy](solutions/documentation-gaps/bluetooth-aggregate-device-handling-2026-05-16.md) — **M**; aggregate devices wrapping a BT mic bypass the avoidance.
- [Narrow BT-input avoidance to classic BT once LE Audio is reliably HFP-free](solutions/documentation-gaps/bt-le-audio-airpods-pro-2-narrowing-2026-05-16.md) — **M**; AirPods Pro 2 + LE Audio is in the fallback unnecessarily.
- [Positive-spelling AX fixture for prompt-eval](solutions/documentation-gaps/positive-spelling-ax-fixture-2026-05-18.md) — **S**; recorded fixture missing, test removed in PR #47.
- [Dynamic terminal-app detection via AppCategorizer](solutions/documentation-gaps/dynamic-terminal-detection-2026-05-18.md) — **M**; R5 gate bypassed for terminals outside the hardcoded 8-entry set.
- [Token usage deltas + cache-hits indicator](solutions/documentation-gaps/token-usage-deltas-and-cache-hits-2026-05-18.md) — **M**; Settings → API & Usage panel ships v1 without per-period deltas or cache-hit %.
- [Mid-session device-swap rebuild could orphan an IOProc in a narrow race](solutions/documentation-gaps/device-swap-rebuild-orphan-2026-07-10.md) — **S**; existing `stopped`-latch + queue drain cover the known windows; add a rebuild-generation token only if a repro appears.
- [ContextSnapshot.minimal drops instruction/dictionary parts on a fast utterance](solutions/documentation-gaps/context-minimal-part-count-2026-07-10.md) — **S**; the non-lite quick-release fallback ships without per-app instructions/dictionary; thread them in if it ever matters.
- [Embed a Developer ID provisioning profile to restore the data-protection keychain](solutions/documentation-gaps/developer-id-provisioning-profile-2026-07-25.md) — **M**; needs Apple Developer portal access. Until then the Gemini key sits in the legacy file keychain and the cert-rotation re-entry bug is back.
- [A hotkey press during transcription is refused silently, and no second recording may start](solutions/documentation-gaps/concurrent-recording-and-the-silent-hotkey-refusal-2026-08-13.md) — **M**; the one refusal in `handleHotkeyPress` with no log line and no on-screen signal. The feedback half is cheap and independent of the interaction half.
- [A network failure on the API-key screens still reads "Gemini error 0."](solutions/documentation-gaps/validate-key-bare-status-zero-copy-2026-08-13.md) — **S**; `validateKey`'s bare status-0 reaches `GeminiKeyRow` and `OnboardingAPIKeyStep`. The transcription path was fixed at the seam; this surface is a separate copy decision.
- [The ten-entry cap can evict a row mid-retry, and the exit reads that as a user deletion](solutions/documentation-gaps/history-cap-eviction-during-an-in-flight-retry-2026-08-13.md) — **M**; a dictation finishing beside an in-flight retry can trim the retried row, discarding its audio and anything the run recovered. Both the cap's eviction contract and concurrent sessions are deliberate scope boundaries.

## Closing an entry

When a tech-debt entry is resolved:

1. Update the body of the file in `docs/solutions/documentation-gaps/` to reflect the fix (move guidance from "leave as-is" to "done in PR #N"). The file stays — it carries the institutional memory of what was tried, what was rejected, and what shipped.
2. Remove the line from "Current entries" above.
3. Reference the closing PR in the file's `## Related` section.

## Items belong here, not in code comments

`// TODO:` strings are second-class — they don't aggregate, don't survive grep across refactors, and don't carry the "why we didn't fix it yet" rationale. Promote any `TODO` you find to a file in `docs/solutions/documentation-gaps/` and link it from the list above.
