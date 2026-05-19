---
title: Force-unwrap, error handling, and logging conventions
date: 2026-05-15
category: conventions
module: cross-cutting
problem_type: convention
component: tooling
severity: high
applies_when:
  - Writing any new Swift code path with optionals
  - Adding a new error type or `throw` site
  - Adding a new `os.Logger` callsite
tags: [force-unwrap, error-handling, logging, os-logger, privacy, swift]
---

# Force-unwrap, error handling, and logging conventions

## Context

These three coupled conventions govern how NoType handles runtime failure surfaces — optionals, throws, and the logs we ship.

The force-unwrap policy keeps the binary from crashing on input variation. The error model keeps modules from leaking implementation detail across seams. The logging policy keeps sensitive data (audio, AX content, the user's Gemini key, transcribed text) out of `Console.app`.

## Guidance

### Force-unwrap policy

**No force-unwrap (`!`) in production code paths.**

Allowed only in:

- **Tests** — a failed unwrap is a test failure, fine.
- **`precondition` / `assertionFailure` adjacent code** where the unwrap documents an invariant that's already been checked at the call site.
- **Compiled-once regex literals at file scope** (`try!` on a constant `NSRegularExpression` whose pattern is a string literal — a malformed pattern is a programming error, not a runtime condition).

Prefer `guard let … else { throw … }` or `guard let … else { return }` with an `os_log` if applicable.

### Error handling

- **Recoverable errors** → `throw`, caller decides.
- **Programming errors** → `precondition` / `assertionFailure`. Crashing in dev is fine; in release these become silent and the system tries to keep going.
- **User-facing errors** → translate at the UI boundary into an `ErrorPayload` via the internal `NoTypeErrorKind` table in `AppState.swift`, surface through `HUDController.showErrorHUD(...)`. (The catalog is `internal` so `MissingKeyHUDRetryTests` can pin the "every payload with a `retryLabel` ships a non-`nil` `retryHandler`" regression guard via `@testable import NoType`; `surfaceError` itself stays `private`.)
- **Never swallow errors silently.** If you intentionally ignore one, write `_ = try? …` *and* log at `.debug`.

### Logging

- **Use `os.Logger`.** Subsystem = `app.notype`, category = module name (`hotkey`, `recording`, `gemini`, `context`, `injection`, `history`, `permissions`, `appstate`, `vad`, `audio.devices`, `secret`).
- **Never log:**
  - Raw audio bytes.
  - AX tree contents (PII).
  - The Gemini API key (or any prefix of it).
  - Transcribed text in release builds.
- **Do log:**
  - State transitions: session started / ended, chunk N sent, response received (lengths, not contents).
  - Errors with enough context to debug.
  - VAD decisions at debug level only.
- **Use `.privacy(.private)` for any string that could conceivably be sensitive.** The `ax capture preview` log in `InsertionTarget.captureSync` is the reference pattern.

## Why This Matters

- **Force-unwrap discipline** is the single rule that prevents "works on dev machine, crashes on user's Mac" surprises. Every `!` is a hidden assumption that should be made explicit at the unwrap site.
- **Module-owned errors** keep blast radius small (see `solutions/conventions/module-architecture-and-naming-2026-05-15.md`). The error model rule extends that — translate at one seam, not everywhere.
- **Logging policy is the privacy contract.** NoType's "no telemetry" stance (`solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md`) only holds if log files don't accidentally export the same data telemetry would have. `.privacy(.private)` redacts at the OS level even for files captured by `log collect`.

## When to Apply

- Default for every new code path.
- Reviewer's job to flag force-unwraps and unannotated string interpolations in PRs.

## Examples

**Allowed force-unwrap** (file-scope compiled regex — `SecureFieldMasker.swift`):

```swift
private static let creditCardRegex = try! NSRegularExpression(
    pattern: #"\b(?:\d[ -]*?){13,19}\b"#
)
```

**Disallowed force-unwrap** (in a hot path):

```swift
// BAD — `event.flags.rawValue` is fine, but the cast isn't.
let flags = (event as! CGEvent).flags

// GOOD
guard let cg = event as? CGEvent else {
    log.debug("event was not a CGEvent")
    return
}
```

**Logging with privacy annotation** (from `InsertionTarget.captureSync`):

```swift
log.debug("ax capture preview: \(preview, privacy: .private)")
```

## Related

- `solutions/conventions/no-telemetry-with-statsstore-carveout-2026-05-15.md` — the privacy contract logging policy upholds.
- `solutions/conventions/module-architecture-and-naming-2026-05-15.md` — module-owned errors convention.
- `docs/conventions.md` — legacy index, redirects here.
