# Architecture Decision Records

> **Migration in progress.** Per the compound-engineering framework, decisions / rationale / rejected alternatives belong in **per-decision files** under `docs/solutions/<category>/`, not in this monolith. ADRs that have moved link to their new home below; the rest still live in this file and will be migrated PR-by-PR.
>
> **Adding a new decision?** Skip this file — write directly into `docs/solutions/<category>/<slug>-<YYYY-MM-DD>.md` using the knowledge-track shape (`## Context → ## Guidance → ## Why This Matters → ## When to Apply → ## Examples → ## Related`). See `docs/solutions/README.md` for the frontmatter contract and category list.

These are the load-bearing decisions for NoType. **Do not relitigate without explicit discussion.** If you think one of these is wrong, open an issue first.

Format: short, blunt, with the alternative considered.

---

## ADR-001 — macOS 15 (Sequoia) minimum

**Migrated to:** [`solutions/tooling-decisions/macos-15-deployment-target-2026-05-15.md`](solutions/tooling-decisions/macos-15-deployment-target-2026-05-15.md)

---

## ADR-002 — Silero VAD instead of Apple SpeechDetector

**Migrated to:** [`solutions/tooling-decisions/silero-vad-coreml-2026-05-15.md`](solutions/tooling-decisions/silero-vad-coreml-2026-05-15.md)

---

## ADR-003 — Gemini 3.1 Flash-Lite

**Migrated to:** [`solutions/tooling-decisions/gemini-3-1-flash-lite-2026-05-15.md`](solutions/tooling-decisions/gemini-3-1-flash-lite-2026-05-15.md)

---

## ADR-004 — Clipboard-based paste (not AX text injection)

**Migrated to:** [`solutions/architecture-patterns/clipboard-cmd-v-paste-2026-05-15.md`](solutions/architecture-patterns/clipboard-cmd-v-paste-2026-05-15.md)

---

## ADR-005 — Right Option as default hotkey, via CGEventTap

**Migrated to:** [`solutions/design-patterns/right-option-cgeventtap-2026-05-15.md`](solutions/design-patterns/right-option-cgeventtap-2026-05-15.md)

---

## ADR-006 — One Gemini request in flight at a time

**Migrated to:** [`solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md`](solutions/architecture-patterns/serial-gemini-actor-2026-05-15.md)

---

## ADR-007 — No streaming responses from Gemini in v1

**Migrated to:** [`solutions/design-patterns/no-streaming-gemini-2026-05-15.md`](solutions/design-patterns/no-streaming-gemini-2026-05-15.md)

---

## ADR-008 — Local concatenation of chunk transcripts

**Migrated to:** [`solutions/design-patterns/local-chunk-concatenation-2026-05-15.md`](solutions/design-patterns/local-chunk-concatenation-2026-05-15.md)

---

## ADR-009 — Full-screen accessibility tree, not just focused window

**Migrated to:** [`solutions/design-patterns/full-screen-ax-tree-2026-05-15.md`](solutions/design-patterns/full-screen-ax-tree-2026-05-15.md)

---

## ADR-010 — JSON file for history, no DB, last 10 only

**Migrated to:** [`solutions/architecture-patterns/json-history-store-2026-05-15.md`](solutions/architecture-patterns/json-history-store-2026-05-15.md)

---

## ADR-011 — BYOK (bring your own Gemini key), stored in Keychain

**Migrated to:** [`solutions/tooling-decisions/byok-keychain-storage-2026-05-15.md`](solutions/tooling-decisions/byok-keychain-storage-2026-05-15.md)

---

## ADR-012 — Direct download distribution, not Mac App Store

**Migrated to:** [`solutions/tooling-decisions/direct-download-distribution-2026-05-15.md`](solutions/tooling-decisions/direct-download-distribution-2026-05-15.md)

---

## ADR-013 — No telemetry in v1

**Migrated to:** [`solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`](solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md)

---

## ADR-014 — Optional screenshot + OCR fallback for AX-poor apps

**Migrated to:** [`solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md`](solutions/architecture-patterns/screenshot-ocr-fallback-2026-05-15.md)

---

## ADR-015 — Per-app categorization + user / category instructions in the cache prefix

**Migrated to:** [`solutions/architecture-patterns/per-app-categorization-instructions-2026-05-15.md`](solutions/architecture-patterns/per-app-categorization-instructions-2026-05-15.md)

---

## ADR-016 — Personal dictionary (canonical spellings + replacement pairs)

**Migrated to:** [`solutions/architecture-patterns/personal-dictionary-2026-05-15.md`](solutions/architecture-patterns/personal-dictionary-2026-05-15.md)

---

## ADR-017 — Sparkle 2 auto-updates with a custom in-app banner UI

**Migrated to:** [`solutions/tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md`](solutions/tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md)
