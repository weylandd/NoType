# NoType

A macOS menu-bar app that turns push-to-talk voice into text and pastes it where the cursor is. Uses **Gemini 3.1 Flash-Lite** for transcription, with on-screen context (accessibility tree of the focused app) for higher accuracy.

Reference products: Wispr Flow, Monologue.

---

## How it works (one paragraph)

User holds **Right Option** anywhere in macOS → NoType starts recording from the mic and shows a stopwatch + mic indicator in the menu bar. **Silero VAD** detects natural pauses (≥1s); each completed phrase is shipped as an audio chunk to **Gemini 3.1 Flash-Lite** along with the user's accessibility-tree context — optionally augmented by a Vision-OCR'd screenshot of the active window when AX returned nothing useful (Electron / web-views; see ADR-014). Chunks are processed serially (one in-flight at a time). User releases Right Option → final chunk goes out with `is_final=true`; the stitched transcript runs through user-defined word replacements (Dictionary tab, see ADR-016) and is pasted at the cursor via clipboard + ⌘V. The last 10 transcripts are kept in a popover, accessible by clicking the menu-bar icon.

---

## Tech stack

| Layer | Choice |
|---|---|
| Min macOS | **15 (Sequoia)** |
| Language | Swift 6, strict concurrency |
| UI | SwiftUI (`MenuBarExtra` + `Popover`) |
| Architecture | MVVM with `@Observable`; `actor` for shared state |
| Audio capture | `AVAudioEngine` + `AVAudioConverter` |
| VAD | **Silero VAD** via CoreML (unified-256 ms model) |
| Hotkey | `CGEventTap` on `flagsChanged` |
| Text injection | Pasteboard + `CGEvent` ⌘V |
| History storage | JSON in `~/Library/Application Support/NoType/history.json` |
| Secrets | macOS Keychain (via `SecretStore` → `KeychainStore`; ADR-011) |
| Distribution | Direct download, notarized .dmg (Sparkle planned for v0.1.0 RC) |

External SPM dependencies: **none yet**. Sparkle is planned for v0.1.0 RC; `onnxruntime-swift` is a fallback if CoreML conversion fidelity ever becomes a problem — see `NoType/Recording/CLAUDE.md`.

---

## Documentation map

Read these in order when onboarding:

- **@docs/architecture.md** — data flow diagram, sequence of one push-to-talk session, the cache-hit invariant.
- **@docs/decisions.md** — architecture decisions and *why* (do not relitigate without discussion).
- **@docs/conventions.md** — Swift 6 concurrency rules, logging policy, error model, testing conventions.
- **@docs/permissions.md** — required macOS permissions and onboarding flow.
- **@docs/build.md** — build, run, test, notarize.
- **@docs/TECHDEBT.md** — running list of known improvements that aren't shipped yet. Pick from here when you have spare cycles.

Per-module guides (Claude Code auto-loads the relevant one when working in that folder):

- **@NoType/Hotkey/CLAUDE.md** — CGEventTap, Right Option detection, runloop quirks.
- **@NoType/Recording/CLAUDE.md** — `AVAudioEngine`, Silero VAD (unified-256 ms), PCM buffer + pre-roll, chunking strategy. **Most complex part of the project.**
- **@NoType/Context/CLAUDE.md** — full-screen accessibility tree, secure-field masking. **Security boundary — extra care.**
- **@NoType/Instructions/CLAUDE.md** — per-app `AppCategory`, user/category instruction storage, `CategoryResolver` AX search-override, the Gemini-driven `AppCategorizer`. Drives the `User instruction:` / `Category instruction:` cache-prefix sections (ADR-015).
- **@NoType/Dictionary/CLAUDE.md** — personal dictionary (canonical spellings shipped in `User dictionary:` cache-prefix section) and user-defined auto-replacement pairs applied at paste time. Post-session `DictionaryHarvester` (pure client-side function) intersects the transcript with the on-screen context to add auto-entries (ADR-016 v2).
- **@NoType/Gemini/CLAUDE.md** — request shape, cache-friendly part ordering (load-bearing!), prompt templates, retries.
- **@NoType/Injection/CLAUDE.md** — clipboard save/restore, paste delay, edge cases.
- **@NoType/History/CLAUDE.md** — JSON store, last-10 cap, schema.
- **@NoType/UI/CLAUDE.md** — menu-bar icon states, history popover, settings sheet, Instructions tab.
- **@NoType/Permissions/CLAUDE.md** — request flow, status surfacing.
- **@NoType/Keychain/CLAUDE.md** — Gemini API key storage (`SecretStore`).
- **@NoType/Updates/CLAUDE.md** — Sparkle 2 auto-updates with a custom `SPUUserDriver` that surfaces the "Update available" pill in the main-window sidebar instead of Sparkle's modal alert (ADR-017).
- **@NoType/Onboarding/** — first-run wizard (steps in `NoType/Onboarding/Steps/`; no dedicated CLAUDE.md yet).

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
- ❌ No audio retention — only the resulting text in history.
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
