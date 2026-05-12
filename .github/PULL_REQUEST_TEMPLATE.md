<!--
Thanks for the PR. A few quick checks before submitting:

- For non-trivial changes, you should have an issue describing the work first.
- Read CONTRIBUTING.md if you haven't.
- Conventional Commit format: feat:, fix:, refactor:, docs:, chore:, test:
-->

## What & why

<!-- What does this change, and why? Focus on the why — the diff shows the what. -->

## Linked issue

<!-- Closes #N — or "n/a" for trivial changes. -->

## Test plan

<!--
How did you verify this works? For UI changes, include screenshots or a screen recording.
For module changes, name the tests you ran.
-->

- [ ]
- [ ]

## Checklist

- [ ] Conventional Commit message (`feat: …`, `fix: …`, etc.)
- [ ] Tests added or updated for behavioral changes
- [ ] If touching `SecureFieldMasker.swift`: added a new `SecureFieldMaskerTests` case (hard rule)
- [ ] If touching `ScreenCaptureContext.swift`: added a `ScreenCaptureContextTests` case (hard rule)
- [ ] If touching the Gemini request shape: explicit acknowledgement of the cache-prefix invariant change in this PR body
- [ ] Per-module `CLAUDE.md` updated if behavior changed (or noted why none was needed)
