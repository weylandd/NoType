# Contributing to NoType

Thanks for your interest. NoType is a small, opinionated project — these notes will save you (and me) time.

---

## Before you start

For non-trivial changes, **open an issue first** describing what you want to do and why. Some directions are off the table — see "Non-goals" in [CLAUDE.md](CLAUDE.md). I'd rather steer early than reject a finished PR.

For typo fixes, small bug fixes, and docs improvements: just open the PR.

---

## Development setup

See [docs/build.md](docs/build.md). TL;DR:

```bash
brew install xcodegen
xcodegen generate
open NoType.xcodeproj
```

You'll need a Gemini API key for live testing — [free tier](https://aistudio.google.com/apikey) is enough.

---

## Branching and PRs

NoType follows **GitHub Flow**:

- `main` is always shippable
- All work happens on short-lived branches: `feature/short-name`, `fix/short-name`, `docs/short-name`
- All changes land via Pull Request — even trivial ones, even mine
- CI must be green before merge
- Merge style: **squash and merge** (keeps history linear and one Conventional Commit per logical change)

Don't push directly to `main`. It's protected.

---

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/). The prefix tells readers (and changelog generators) what kind of change this is:

- `feat: …` — new user-facing feature
- `fix: …` — user-visible bug fix
- `refactor: …` — internal restructuring, no behavior change
- `docs: …` — docs only
- `chore: …` — tooling, build, deps, release plumbing
- `test: …` — test-only changes

When useful, scope the change: `feat(recording): …`, `fix(injection): …`. Module names match the folders under `NoType/`.

The commit body should explain the **why**, not the **what** (the diff is the what). Reference an issue if there is one.

---

## Code conventions

Read [docs/conventions.md](docs/conventions.md). Highlights:

- Swift 6 strict concurrency. `actor` for shared mutable state, no `@unchecked Sendable` without a doc-comment justifying it.
- MVVM + `@Observable` — no new `ObservableObject`/`@Published` view-models.
- One type per file. Tests mirror source: `Foo.swift` ↔ `FooTests.swift`.
- No force-unwrap (`!`) in production paths. See `docs/conventions.md` for the narrow exceptions.
- Use `os.Logger`, never `print`. Subsystem `app.notype`. Never log audio bytes, AX content, transcripts (in release), or the Gemini key.

---

## Security-critical files

Two files need extra care. PRs that touch them will get a closer review:

### `NoType/Context/SecureFieldMasker.swift`

Redacts sensitive content from the on-screen accessibility snapshot before it goes to Gemini. **Hard rule:** any change here must add at least one new test case to `NoTypeTests/SecureFieldMaskerTests.swift` that motivated the change.

### `NoType/Context/ScreenCapture/ScreenCaptureContext.swift`

Same security boundary, applied to OCR'd screen text. Any change to the path between Vision OCR output and the Gemini prompt must add a test under the `// MARK: - OCR fallback consumer` section of `SecureFieldMaskerTests.swift`.

### `NoTypeTests/GeminiRequestBuilderTests.swift`

Pins the cache-friendly part ordering of every Gemini request. If this test changes, the cache-prefix invariant changed — we need a deliberate decision, not an accidental one. Explain in the PR body why the order needs to move.

---

## Tests

```bash
xcodebuild -project NoType.xcodeproj -scheme NoType test -destination 'platform=macOS'
```

Every non-UI module should have unit tests. New code without tests will be asked to add them.

Integration tests against the real Gemini API live alongside unit tests but are gated behind `NOTYPE_INTEGRATION=1` — set the env var before running them, otherwise they self-skip.

---

## Areas where help is especially welcome

Pick from [`docs/TECHDEBT.md`](docs/TECHDEBT.md) — that file is curated, and items there have context on why they're not yet shipped.

Also high-value, lower-difficulty:

- Localization of UI strings (English-only currently)
- Reproducible bug reports for transcription accuracy on your accent/language
- More test cases for `SecureFieldMaskerTests` covering token/key formats we missed

---

## What NOT to PR

These are deliberate non-goals (see [CLAUDE.md](CLAUDE.md)):

- Offline mode
- Live transcript window
- Editing past transcripts in-app
- Audio retention on disk (in-memory retention of failed chunks, for the retry action, already ships)
- History longer than 10 entries
- Mac App Store distribution
- Telemetry / analytics

PRs adding any of these will be closed. Discuss in an issue first if you think the rationale should be revisited.

---

## Code of Conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

---

## Questions?

Open a [Discussion](https://github.com/weylandd/NoType/discussions) or an issue. There's no Slack/Discord — issues and PRs are the channel.
