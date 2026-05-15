# Tech debt

Known engineering improvements that are intentionally *not* shipped yet. None of these block normal use of NoType.

Tech-debt entries live as per-item files under [`docs/solutions/documentation-gaps/`](solutions/) following the compound-engineering knowledge-track shape (`Context → Guidance → Why This Matters → When to Apply → Examples → Related`). This file is the index — adding a new item means writing a new file in `docs/solutions/documentation-gaps/` and adding a one-line link below.

See `docs/solutions/README.md` for the frontmatter contract and body structure.

## Current entries

- [In-memory AAC encoding for audio chunks](solutions/documentation-gaps/in-memory-aac-encoding-2026-05-15.md) — **L**; `ChunkBuilder.encodeAAC` round-trips through a temp file.
- [SileroVAD CoreML vs ONNX reference test](solutions/documentation-gaps/silero-vad-reference-test-2026-05-15.md) — **M**; no `SileroVADTests.swift`.
- [AccessibilityTree fixture-driven tests](solutions/documentation-gaps/accessibility-tree-fixture-tests-2026-05-15.md) — **M**; walker has subtle invariants without a regression net.
- [Settings section for screen-capture fallback](solutions/documentation-gaps/screen-capture-settings-section-2026-05-15.md) — **S**; no in-app way to disable OCR without revoking TCC.

## Closing an entry

When a tech-debt entry is resolved:

1. Update the body of the file in `docs/solutions/documentation-gaps/` to reflect the fix (move guidance from "leave as-is" to "done in PR #N"). The file stays — it carries the institutional memory of what was tried, what was rejected, and what shipped.
2. Remove the line from "Current entries" above.
3. Reference the closing PR in the file's `## Related` section.

## Items belong here, not in code comments

`// TODO:` strings are second-class — they don't aggregate, don't survive grep across refactors, and don't carry the "why we didn't fix it yet" rationale. Promote any `TODO` you find to a file in `docs/solutions/documentation-gaps/` and link it from the list above.
