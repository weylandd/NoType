# NoType

A macOS menu-bar app that turns push-to-talk voice into text and pastes it where the cursor is. Uses **Gemini 3.1 Flash-Lite** for transcription, with on-screen context (accessibility tree of the focused app) for higher accuracy.

Reference products: Wispr Flow, Monologue.

---

## How it works (one paragraph)

User holds **Right Option** anywhere in macOS → NoType starts recording from the mic and shows a stopwatch + mic indicator in the menu bar. **Silero VAD** detects natural pauses (≥1s); each completed phrase is shipped as an audio chunk to **Gemini 3.1 Flash-Lite** along with the user's accessibility-tree context — optionally augmented by a Vision-OCR'd screenshot of the active window when AX returned nothing useful (Electron / web-views; see ADR-014). Chunks are processed serially (one in-flight at a time). User releases Right Option → final chunk goes out with `is_final=true`; the stitched transcript runs through user-defined word replacements (Dictionary tab, see ADR-016) and is pasted at the cursor via clipboard + ⌘V — **but only into the process the user was frontmost in when they stopped recording.** If they moved on during transcription the paste is withheld and a notice offers to copy it instead, because a late paste into a foreign window edits a document nobody aimed at. The last 10 transcripts are kept in a popover, accessible by clicking the menu-bar icon; each is stored as an ordered sequence of response segments (raw model text, or a **gap** where a chunk was lost) rather than as one flat string, so a lost chunk's *position* survives and a retry writes back into it.

---

## Tech stack

| Layer | Choice |
|---|---|
| Min macOS | **15 (Sequoia)** |
| Language | Swift 6, strict concurrency |
| UI | SwiftUI (`MenuBarExtra` + `Popover`) |
| Architecture | MVVM with `@Observable`; `actor` for shared state |
| Audio capture | Core Audio HAL (`AudioDeviceCreateIOProcIDWithBlock`) + `AVAudioConverter` |
| VAD | **Silero VAD** via CoreML (unified-256 ms model) |
| Hotkey | `CGEventTap` on `flagsChanged` |
| Text injection | Pasteboard + `CGEvent` ⌘V |
| History storage | JSON in `~/Library/Application Support/NoType/history.json` |
| Secrets | macOS Keychain (via `SecretStore` → `KeychainStore`; ADR-011) |
| Distribution | Direct download, notarized .dmg + Sparkle 2 auto-updates (ADR-017) |

External SPM dependencies: **Sparkle 2** (auto-updates, see ADR-017 and `NoType/Updates/CLAUDE.md`). `onnxruntime-swift` is a planned fallback if Silero CoreML conversion fidelity ever becomes a problem — see `NoType/Recording/CLAUDE.md`.

---

## Documentation map

Read these in order when onboarding:

- **@CONCEPTS.md** — shared domain vocabulary (recording session, chunk, gap marker, network class) plus the ambiguous words to qualify; read it first so the other docs' nouns mean what they say.
- **@docs/architecture/overview.md** — current-state snapshot (Mermaid data flow, module table, external integrations, threading model, invariants). Regenerate when drift appears, don't hand-edit for accuracy.
- **@docs/architecture.md** — short index pointing at `architecture/overview.md` and the solutions store.
- **@docs/decisions.md** — index of architecture decisions → per-decision files in `docs/solutions/`.
- **@docs/conventions.md** — index of coding conventions → per-topic files in `docs/solutions/conventions/`.
- **@docs/permissions.md** — required macOS permissions and onboarding flow.
- **@docs/build.md** — build, run, test, notarize.
- **@docs/TECHDEBT.md** — index of known improvements → per-item files in `docs/solutions/documentation-gaps/`.
- **@docs/solutions/** — per-decision / per-learning store (compound-engineering knowledge & bug tracks). See `docs/solutions/README.md`.

Per-module guides (Claude Code auto-loads the relevant one when working in that folder):

- **@NoType/Hotkey/CLAUDE.md** — CGEventTap, Right Option detection, runloop quirks.
- **@NoType/Recording/CLAUDE.md** — Core Audio HAL capture (`AudioDeviceCreateIOProcIDWithBlock`; bypasses `AVAudioEngine` deliberately), Silero VAD (unified-256 ms), PCM buffer + pre-roll, chunking strategy. **Most complex part of the project.**
- **@NoType/Context/CLAUDE.md** — full-screen accessibility tree, secure-field masking. **Security boundary — extra care.**
- **@NoType/Instructions/CLAUDE.md** — per-app `AppCategory`, user/category instruction storage, `CategoryResolver` AX search-override, the Gemini-driven `AppCategorizer`. Drives the `User instruction:` / `Category instruction:` cache-prefix sections (ADR-015).
- **@NoType/Dictionary/CLAUDE.md** — personal dictionary (canonical spellings shipped in `User dictionary:` cache-prefix section) and user-defined auto-replacement pairs applied twice over: once on the paste path, and again at render time over a history row's assembled text, so editing a pair changes how rows already on disk read. Post-session `DictionaryHarvester` (pure client-side function) intersects the transcript with the on-screen context to add auto-entries (ADR-016 v2).
- **@NoType/Gemini/CLAUDE.md** — request shape, cache-friendly part ordering (load-bearing!), prompt templates, retries.
- **@NoType/Injection/CLAUDE.md** — clipboard save/restore, paste delay, edge cases.
- **@NoType/History/CLAUDE.md** — JSON store, last-10 cap, schema.
- **@NoType/Storage/CLAUDE.md** — `JSONFileStorage` shared file-IO plumbing (atomic write, corruption recovery) used by the four actor stores.
- **@NoType/UI/CLAUDE.md** — menu-bar icon states, history popover, settings sheet, Instructions tab.
- **@NoType/Permissions/CLAUDE.md** — request flow, status surfacing.
- **@NoType/Keychain/CLAUDE.md** — Gemini API key storage (`SecretStore`).
- **@NoType/Updates/CLAUDE.md** — Sparkle 2 auto-updates with a custom `SPUUserDriver` that surfaces the "Update available" pill in the main-window sidebar instead of Sparkle's modal alert (ADR-017).
- **@NoType/Onboarding/** — first-run wizard (steps in `NoType/Onboarding/Steps/`; no dedicated CLAUDE.md yet). Onboarding's `MicProbe` (mic-check step) is the app's *only* `AVAudioEngine` user — the recording path itself uses Core Audio HAL.
- **@NoType/Diagnostics/** — the permanent `objc_setExceptionPreprocessor` breadcrumb (no dedicated CLAUDE.md yet). Installed as the first statement of `NoTypeApp.init()`; logs every Objective-C exception raised in the process at `.fault`, including the ones AppKit swallows. Its contract lives in the `ExceptionBreadcrumb.swift` doc-comment — chaining outward to the preprocessor it replaced is **load-bearing**, not ceremony. See `docs/solutions/runtime-errors/macos-26-executor-identity-check-family-2026-07-25.md`.

---

## Build, release, tech-debt workflow

- Building from an agent / CLI, and the release script (`scripts/release.sh`) — see `@docs/build.md`.
- Adding or closing tech-debt entries — see `@docs/TECHDEBT.md`.
- **Don't run `xcodebuild build` / `test` unless Swift source actually changed.** Prompt edits, comment fixes, doc edits don't need a build. Every build registers the DerivedData `NoType.app` with LaunchServices and the user ends up with two NoType entries in Launchpad — see the "Hard rules" block at the top of `@docs/build.md` for the cleanup recipe (`lsregister -u`).

---

## Non-goals (explicitly)

- ❌ No offline mode. Internet is required; show "no internet" toast if unavailable.
- ❌ No live transcript window during recording.
- ❌ No editing of past transcripts inside the app.
- ❌ No audio retention **on disk** — only the resulting text is persisted. In-memory carve-out: audio of chunks that failed to transcribe is held for the lifetime of the process so a broken history row can be retried. It is never serialized, and process exit is what ends it — see `NoType/History/CLAUDE.md` invariant 4.
- ❌ No screen recording **by default** — opt-in fallback only (ADR-014). When the Screen Recording permission is granted, NoType OCR's a screenshot of the active window to fill the on-screen-context section when AX surfaces nothing useful; otherwise that limb is silent. No raw screenshots are ever stored or sent — only `SecureFieldMasker.scrubContent`-filtered text.
- ❌ No account system, no telemetry (in the OSS version).
- ❌ No history > 10 entries (FIFO).
- ❌ No Mac App Store distribution (sandboxing complicates Accessibility + CGEventTap).

These are deliberate. Do not add features in this list without explicit product approval.

---

## Open questions / TODO before v1

- [ ] Behavior when cursor is not in a text field at release time — paste anyway, document in README.
- [ ] Localization of UI strings (English-only in v1; Russian as fast follow).
- [ ] Onboarding polish — beta is engineer-grade.
- [ ] Verify Silero VAD CoreML conversion quality vs ONNX runtime — see `NoType/Recording/CLAUDE.md`.

---

## License

MIT — see [LICENSE](LICENSE). Project may later evolve into a paid SaaS tier for users who don't want to manage their own Gemini API key. The OSS app must always work standalone with a user-supplied key.

---

*Last updated: keep this date in PRs that materially change scope or top-level architecture.*
