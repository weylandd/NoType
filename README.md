# NoType

A macOS menu-bar app that turns push-to-talk voice into text and pastes it where the cursor is.

Hold **Right Option** anywhere in macOS, talk, release. NoType transcribes via Gemini 3.1 Flash-Lite using on-screen context (accessibility tree of the focused app) for higher accuracy, then pastes at the cursor.

Inspired by [Wispr Flow](https://wisprflow.ai) and [Monologue](https://monologue.to). Built as a transparent, BYOK-Gemini alternative.

---

## Status

Early beta. The core push-to-talk → transcribe → paste loop works end-to-end. Distribution is via direct .dmg download (no Mac App Store). NoType keeps itself up to date in the background via Sparkle 2 — once installed, you'll see a small "Update available" banner in the main window's sidebar when a new release ships.

---

## Known issues

**On macOS 26, clicking inside NoType can crash it — and it can block setup.** Reported so far only on macOS 26.2 (build 25C56), and not on every Mac.

- **Setting up can be impossible.** The onboarding wizard is driven by ordinary buttons, so if the crash hits you, you may not be able to finish setup at all.
- **If you're already set up, dictation still works.** Push-to-talk doesn't go through the code path that crashes — hold the hotkey, talk, release, and the transcript still pastes. Only clicking inside NoType's own windows is affected.

**This is our bug, not macOS's.** An earlier version of this note blamed the macOS build and suggested updating macOS. That was wrong: NoType raises an internal error that macOS quietly absorbs, which leaves the app in a broken state until it falls over a moment later at some unrelated click. We've now reproduced that mechanism and know what to look for. Updating macOS is not expected to fix it, and we don't have a workaround to offer yet — we'd rather say that than send you chasing one. A fix is in progress; we won't put a date on it.

**If it's hitting you, one thing genuinely helps.** Run this in Terminal, reproduce the crash, and attach the new crash report to [issue #82](https://github.com/weylandd/NoType/issues/82) along with your macOS build:

```bash
defaults write app.notype NSApplicationCrashOnExceptions -bool YES
```

That makes NoType crash *at* the underlying error instead of hiding it, so the report names the real culprit. Undo it any time with `defaults delete app.notype NSApplicationCrashOnExceptions`. NoType has no telemetry, so reports like this are the only way we see the problem at all.

**And this second command helps even if you never crash.** NoType now writes a line to the macOS system log every time it hits one of these internal errors — including the ones macOS absorbs silently. Run this after using the app for a bit:

```bash
/usr/bin/log show --last 30m --predicate 'subsystem == "app.notype" AND category == "exception"' --style compact
```

You should always see one `EXC BREADCRUMB armed` line — that just confirms the watcher is running. Any `OBJC THROW` line after it is the thing we're hunting; it names the error and where it came from. **Both outcomes are useful to us**, including "armed line only, nothing else" — that result is what tells us we're looking in the wrong place, and it's just as hard to get without you.

Please read the output before you post it. It's filtered for anything that looks like a key or a password, but it is written by macOS, not by us, so we can't promise it never contains something you'd rather not publish — and [issue #82](https://github.com/weylandd/NoType/issues/82) is a public, search-indexed page. If a line looks personal, email it to **kopachevmail@gmail.com** instead and just say on the issue that you've sent one.

---

## Requirements

- macOS 15 (Sequoia) or later
- A Gemini API key — [create one for free at Google AI Studio](https://aistudio.google.com/apikey)

NoType uses your Gemini key directly from your machine. There is no NoType-operated proxy or account system. Your audio and on-screen context go from your Mac to Google's Gemini API and nowhere else.

---

## Install

**Option A — pre-built release:**

1. [Download the latest NoType.dmg](https://github.com/weylandd/NoType/releases/latest) (or grab a specific version from the [Releases page](https://github.com/weylandd/NoType/releases)).
2. Open the DMG, drag NoType.app to `/Applications`.
3. Launch — the onboarding wizard walks you through entering your Gemini key and granting permissions.

Future updates arrive automatically via Sparkle — a sidebar banner in the main window will offer to install when a new release is published.

**Option B — build from source** (see [docs/build.md](docs/build.md)):

```bash
brew install xcodegen
xcodegen generate
open NoType.xcodeproj
# Build & run from Xcode
```

---

## Permissions

NoType asks for two permissions and one optional one. The onboarding wizard handles all three:

| Permission | Required? | Why |
|---|---|---|
| **Microphone** | Required | Audio capture |
| **Accessibility** | Required | (1) Global hotkey via `CGEventTap`, (2) reading on-screen text for transcription context |
| **Screen Recording** | Optional | Fallback context source for apps that don't expose text via Accessibility (Electron apps like Slack/Discord, web-views like Notion). When granted, NoType screenshots the active window and OCR's it locally via Vision; pixels never reach Gemini, only OCR'd-and-scrubbed text |

NoType does **not** use Apple's Speech Recognition framework — VAD runs locally via Silero (CoreML).

For the full permission story, see [docs/permissions.md](docs/permissions.md).

---

## How it works

```
Hold Right Option → mic captures → Silero VAD detects pauses
                  → chunks ship to Gemini with on-screen context
                  → release → final chunk → stitched & pasted at cursor
```

Cache-friendly request structure means follow-up chunks within a session get a ~90% discount on prefix tokens. A free-tier Gemini key is enough for personal use.

For the full architecture, see [docs/architecture.md](docs/architecture.md). For the why-not-X decisions, [docs/decisions.md](docs/decisions.md).

---

## Privacy

- **No audio retention.** Audio exists in memory only during a session; it's discarded the moment the transcript is pasted.
- **Last 10 transcripts only.** History is capped at 10 entries, plain text, in `~/Library/Application Support/NoType/`.
- **Secure-field masking.** Anything from the Accessibility tree that looks like a password field, API key, JWT, credit card, etc. is redacted before it leaves your machine. See [`SecureFieldMasker.swift`](NoType/Context/SecureFieldMasker.swift) and [`docs/decisions.md`](docs/decisions.md) ADR-009/014.
- **No telemetry, no analytics, no crash reporting.** Open source — read the code.
- **Your Gemini key is stored in macOS Keychain.** Never logged, never sent anywhere except Google's API.

---

## Documentation

- [`CLAUDE.md`](CLAUDE.md) — top-level project map
- [`docs/architecture.md`](docs/architecture.md) — runtime data flow + invariants
- [`docs/decisions.md`](docs/decisions.md) — architecture decision records (ADRs)
- [`docs/conventions.md`](docs/conventions.md) — Swift 6 concurrency rules, error model, testing conventions
- [`docs/permissions.md`](docs/permissions.md) — required macOS permissions
- [`docs/build.md`](docs/build.md) — build, test, notarize, release
- [`docs/TECHDEBT.md`](docs/TECHDEBT.md) — known improvements not yet shipped

Per-module guides live in `NoType/<Module>/CLAUDE.md` (Recording, Context, Gemini, Hotkey, etc.).

---

## Contributing

PRs welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening one — it covers the Conventional Commits convention, the security-critical files (`SecureFieldMasker`, `GeminiRequestBuilder`) that need extra care, and how to run the test suite.

By contributing you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).

---

## License

MIT — see [LICENSE](LICENSE).
