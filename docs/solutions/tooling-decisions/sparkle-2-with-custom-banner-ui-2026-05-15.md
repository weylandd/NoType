---
title: Sparkle 2 auto-updates with a custom in-app banner UI
date: 2026-05-15
category: tooling-decisions
module: Updates
problem_type: tooling_decision
component: tooling
severity: high
applies_when:
  - Adopting or upgrading the auto-update mechanism
  - Considering a fork to Sparkle 1.x or a custom updater
  - Designing the user-facing surface for an available update
tags: [sparkle, auto-updates, eddsa, github-pages, lsuielement, custom-userdriver]
---

# Sparkle 2 auto-updates with a custom in-app banner UI

## Context

NoType is distributed as a notarized .dmg outside the Mac App Store (see `solutions/tooling-decisions/direct-download-distribution-2026-05-15.md`). That means we own the update path — users won't get updates automatically unless we wire up an updater.

The pieces that need to fit together:

- An auto-update mechanism that handles download, signature verification, atomic in-place replacement, and relaunch.
- An appcast feed somewhere stable.
- Release artifacts somewhere durable (.dmg for first install, signed .zip for Sparkle).
- A user-facing UI shape that fits a menu-bar utility (no modal alert windows stealing focus).

## Guidance

**Distribute updates via Sparkle 2** (SPM dep, `from: 2.6.0`).

- **Appcast** at `https://weylandd.github.io/NoType/appcast.xml`, served by GitHub Pages from `/docs` of `weylandd/NoType`.
- **Release binaries** (`.dmg` + `.zip`) on GitHub Releases of the same repo. The `.zip` is the Sparkle artefact, signed with **EdDSA** (`sign_update`); the `.dmg` is the first-time-install artefact the README links to.
- **Update UI** is custom: a small "Update to X.Y.Z" pill in the main-window sidebar (`NoType/UI/UpdateBanner.swift`), driven by `NoType/Updates/UpdateController.swift` wrapping `SPUUpdater` with a custom `SPUUserDriver` (`NoType/Updates/UpdateUserDriver.swift`). **Sparkle's standard modal alert window is bypassed entirely.**

Click the banner → Sparkle downloads → verifies the EdDSA signature against `SUPublicEDKey` in `Info.plist` → relaunches on the new build. No manual "Check for updates" button, no auto-check toggle in v1; daily scheduled checks are always on.

## Why This Matters

- **Sparkle 2 over Sparkle 1.x.** Sparkle 1 is on a frozen branch since 2022, doesn't ship strict-concurrency-friendly APIs, and has known XPC quirks on macOS 26. Sparkle 2.6+ adopts MainActor + Sendable, has a clean `SPUUserDriver` protocol for custom UIs, and is the actively maintained line.
- **Sparkle 2 over rolling our own.** Auto-updating macOS apps correctly is hard — EdDSA signature verification, atomic in-place replacement (Sparkle uses a relauncher process so the app can replace itself), TCC preservation across the rebrand, ACL-aware Keychain access. Sparkle solves all of these; reproducing them would be 1000+ lines of finicky code we'd then need to maintain.
- **Custom user driver over `SPUStandardUserDriver`.** NoType is `LSUIElement = true`, a menu-bar utility. Sparkle's standard alert window steals focus and looks out of place. A compact in-sidebar pill matches the rest of the UI shape and how peers like Claude Desktop surface updates.
- **GitHub Pages from `docs/`, same repo.** Stable CDN-cached URL (no rate-limit issues `raw.githubusercontent.com` has), zero cross-repo plumbing (no deploy keys / PATs to wire up), one repo to grant secrets to.
- **EdDSA over DSA.** Sparkle 2 deprecates DSA. EdDSA keys are 32 bytes (vs DSA's 1 KB+), signing is fast, verification is constant-time. The private key lives in the developer's Keychain (and a password-manager backup); the public key is embedded in `Info.plist`. Losing the private key permanently kills the update path — every installed copy rejects releases signed with a new public key — so it gets the same "back it up" treatment as a TLS root CA.

## When to Apply

- Default for all releases. Tag a commit `vX.Y.Z`, push; the GitHub Actions workflow runs xcodegen → archive → notarize → sign → publish.
- Reconsider when:
  - Users start asking for a "Check for Updates…" menu — add a manual trigger to Settings, but keep the banner as the primary surface.
  - We adopt delta updates (`generate_appcast --maximum-deltas N`) — small change to `scripts/release.sh` (sign the deltas too) + the appcast item generator.

## Examples

**Decisions inside the decision:**

- **`.zip` for Sparkle, `.dmg` for first-time install.** The .zip path is faster (no `hdiutil attach`), cleaner to `sign_update`, and Sparkle's documented recommendation. The .dmg is what the README's "Download" link points to and what a fresh user installs by dragging.
- **Auto-check always on, no user toggle, no manual trigger in Settings.** Same call as the no-telemetry stance: minimal v1, no controls that demand UX design we haven't earned. Background check, banner only when something's there. **This was silently untrue until 2026-07-25:** `UpdateController.start()` hung off a `.task` on the main `Window`, which an `LSUIElement` app does not present at launch for a returning user — so menu-bar-only users got no checks at all. `start()` now runs from `applicationDidFinishLaunching(_:)`; see [`architecture-patterns/scene-task-is-not-a-launch-hook-2026-07-25.md`](../architecture-patterns/scene-task-is-not-a-launch-hook-2026-07-25.md).
- **Banner inside the sidebar, not a floating HUD.** HUDs are reserved for transient action-driven states (recording, transcribing, errors). An available update is a persistent state of the app that the user might ignore for hours; embedding it in the sidebar gives it the same visual weight as the nav items without pulling focus away from the main pane.
- **Auto-install on `showReady(toInstallAndRelaunch:)`.** When Sparkle finishes downloading and asks "ready to install + relaunch?", the custom driver replies `.install` without a second prompt — the user already clicked the banner once, asking again is friction.
- **GitHub Actions release on `push: tags: ['v*']`.** Tag → workflow → published in ~12–18 min. Local fallback (`scripts/release.sh` + `scripts/publish_release.sh`) is preserved.

**Trade-offs accepted:**

- **`Package.resolved` is gitignored.** A future Sparkle 2.x bump could ship a regression we don't catch until the next CI release run. Mitigated by `from: 2.6.0` minimum + xcodebuild's lock-on-first-build.
- **The banner has no "Skip this version" affordance in v1.** Users who dismiss will see the banner again on the next scheduled check.

**Alternatives that were rejected:**

- **Mac App Store auto-update.** NoType needs Accessibility + `CGEventTap`, both of which fight MAS sandboxing.
- **GitHub Releases polling without Sparkle.** We'd have to ship our own download/verify/replace/relaunch flow, plus TCC preservation, plus delta updates if we ever want them. Sparkle's the right level of abstraction.
- **Hosted appcast on `notype.app` once domain lands.** Reasonable migration target. Out of scope today; when the domain is set up, change `SUFeedURL` AND publish a `<sparkle:newSUFeedURL>` element in the old appcast for one release cycle.

## Related

- `NoType/Updates/CLAUDE.md` — implementation detail (Info.plist contract, threading, phase state machine).
- `docs/decisions.md` ADR-017 — legacy index entry, redirects here.
- `solutions/tooling-decisions/direct-download-distribution-2026-05-15.md` — the distribution channel this updater serves.
- `docs/build.md` "Cutting a release" — operational recipe.
