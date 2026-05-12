# Changelog

All notable changes to NoType are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Until v1.0.0, breaking changes may land on minor (`0.x`) bumps.

---

## [Unreleased]

---

## [0.1.2-rc1] — 2026-05-12

First release through the new auto-update pipeline. Functionally
equivalent to 0.1.1; the goal of this RC is to validate end-to-end
that GitHub Actions builds + notarizes + Sparkle-signs the artefact
and that an installed 0.1.1 picks up the new version via the in-app
banner.

### Added
- Sparkle 2 auto-updates. A small "Update to X.Y.Z" banner appears
  in the main window sidebar when a new version is published; click
  to download, verify EdDSA signature, and relaunch on the new build.
- Daily background check via the Sparkle scheduler (no UI to disable
  in this release — auto-only by design for v1).
- CI release pipeline (`.github/workflows/release.yml`): tag `v*`
  triggers build → notarize → sign → publish GitHub Release + patch
  `docs/appcast.xml` on `main`.

---

## [0.1.1] — 2026-05-11

Internal pre-public release.

[Unreleased]: https://github.com/weylandd/NoType/compare/v0.1.2-rc1...HEAD
[0.1.2-rc1]: https://github.com/weylandd/NoType/releases/tag/v0.1.2-rc1
[0.1.1]: https://github.com/weylandd/NoType/releases/tag/v0.1.1
