# Coding conventions

Living rules for NoType's code. Update this file in PRs that change conventions.

---

## Swift 6 strict concurrency

- The project builds with strict concurrency enabled (`SWIFT_STRICT_CONCURRENCY: complete` in `project.yml`). Treat every warning as an error in CI.
- `actor` for any shared mutable state. The current actors are `GeminiClient`, `HistoryStore`, `SileroVAD`; `RecordingSession`, `AppState`, `PermissionsViewModel`, `OnboardingState`, `AppearanceController`, `HUDController` are `@MainActor`.
- No `@unchecked Sendable` without a comment explaining the invariant that makes it safe. Currently used by `AudioRecorder`, `HotkeyMonitor`, `MicProbe` — each has a doc-comment explaining the lock or thread-confinement that justifies it.
- Cross-actor communication via `await`, `AsyncStream`, or `AsyncChannel`. No callbacks, no completion handlers in new code.

---

## Architecture pattern

- **MVVM with `@Observable`.** SwiftUI views observe `@Observable` view-models via `@Environment(Foo.self)` (or a `let` stored property for non-injected references); use `@Bindable` locally inside `body` when you need a `Binding` (e.g. `Picker(selection: $vm.mode)`). The current `@Observable` view-models are `AppState`, `PermissionsViewModel`, `OnboardingState`, `AppearanceController`, and the `AudioDeviceManager.shared` singleton. Do not introduce new `ObservableObject` / `@Published` view-models — they're incompatible with `@Environment(_:)` and force callers to mix patterns.
- Services (`GeminiClient`, `AudioRecorder`, `HistoryStore`) are injected into view-models via initializer, never accessed via singleton — except `AudioDeviceManager.shared` (HAL wrapper, holds no state of its own).
- **Modules own their own errors.** Each module declares `enum FooError: Error` and surfaces only its own type. Don't `throw` an `Error` across module boundaries — translate at the UI seam in `AppState.surfaceError(_:)` via the private `NoTypeErrorKind` table.
- **Dependency injection via initializer.** No property wrappers for DI, no service locators.

---

## Naming & files

- One type per file, named after the type. Exceptions: small private helpers tightly coupled to the main type.
- Folder = module = (logically) build target boundary even if we don't split into actual targets yet.
- Test file mirrors source file: `Foo.swift` → `FooTests.swift`, all under `NoTypeTests/`.

---

## Force-unwrap policy

- **No force-unwrap (`!`) in production code paths.**
- Allowed only in:
  - Tests (where a failed unwrap is a test failure, fine).
  - `precondition` / `assertionFailure` adjacent code where the unwrap documents an invariant that's already been checked.
  - Compiled-once regex literals at file scope (`try!` on a constant `NSRegularExpression` whose pattern is a string literal — a malformed pattern is a programming error, not a runtime condition).
- Prefer `guard let … else { throw … }` or `guard let … else { return }` with an `os_log` if applicable.

---

## Logging

- Use `os.Logger`. Subsystem = `app.notype`, category = module name (`hotkey`, `recording`, `gemini`, `context`, `injection`, `history`, `permissions`, `appstate`, `vad`, `audio.devices`, `secret`).
- **Never log:**
  - Raw audio bytes.
  - AX tree contents (PII).
  - The Gemini API key (or any prefix of it).
  - Transcribed text in release builds.
- **Do log:**
  - State transitions: session started/ended, chunk N sent, response received (lengths, not contents).
  - Errors with enough context to debug.
  - VAD decisions at debug level only.
- Use `.privacy(.private)` for any string that could conceivably be sensitive. The `ax capture preview` log in `InsertionTarget.captureSync` is the reference pattern.

---

## Error handling

- Recoverable errors → `throw`, caller decides.
- Programming errors → `precondition`/`assertionFailure`. Crashing in dev is fine; in release these become silent and the system tries to keep going.
- User-facing errors → translate at the UI boundary into an `ErrorPayload` via the private `NoTypeErrorKind` table in `AppState.swift`, surface through `HUDController.showErrorHUD(...)`.
- Never swallow errors silently. If you intentionally ignore one, write `_ = try? …` *and* log at `.debug`.

---

## Async style

- `async`/`await` everywhere. No `DispatchQueue` in new code (legacy callsites can stay until they're touched).
- For periodic work: `Task { while !Task.isCancelled { try await Task.sleep(...); … } }`.
- For producer/consumer: `AsyncStream` or `AsyncChannel`.
- Use `withTaskGroup` for fan-out, but in this codebase fan-out is rare — most things are serial by design. (`AccessibilityTree.snapshot()` parallelises the per-app walk; that's the load-bearing example.)
- Cancellation: every long-running task must check `Task.isCancelled` or be cancelled by deinit of its owner.

---

## Testing

- Every non-UI module should have unit tests. Coverage isn't a hard target, but each public function should have at least one happy-path test and one error-path test.
- UI uses snapshot tests where they pay off; we don't aim for full UI test coverage.
- **Hard rule:** any change to `NoType/Context/SecureFieldMasker.swift` must add a new test case to `NoTypeTests/SecureFieldMaskerTests.swift`. Security boundary.
- **Hard rule:** `NoTypeTests/GeminiRequestBuilderTests.swift` must verify the cache-friendly part ordering. If the test changes, the cache-prefix invariant changed — get explicit review.
- Use synthetic AX trees and synthetic audio buffers for tests. Don't depend on the live system in unit tests.
- Integration tests against the real Gemini API live behind env var `NOTYPE_INTEGRATION=1`; they are not part of the default `NoTypeTests` run.

---

## SPM dependencies

- Justify new dependencies in the PR description.
- Current SPM dependencies: **Sparkle 2** (`from: 2.6.0`) for auto-updates — see ADR-017. Otherwise the app builds against system frameworks only (`AVFoundation`, `CoreML`, `CoreAudio`, `AppKit`, `SwiftUI`, `Security`).
- Planned acceptable: `onnxruntime-swift` for Silero fallback if CoreML conversion fidelity becomes a problem — see `NoType/Recording/CLAUDE.md`.
- Avoid: HTTP libraries (we use `URLSession`), JSON libraries (`Codable` is enough), DI containers, reactive frameworks.

---

## Comments

- Comments explain *why*, not *what*. The code says what.
- When working around a known SDK bug, link the Apple Forums thread or rdar.
- TODOs should include an owner or a tracking issue: `// TODO(@user): replace with X once Apple fixes FB12345`.

---

## Git / PR hygiene

- Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`).
- One logical change per PR. Refactors that touch many files are fine but should be a single coherent move.
- PR description includes: what changed, why, and which `CLAUDE.md` you updated (or why none was needed).
