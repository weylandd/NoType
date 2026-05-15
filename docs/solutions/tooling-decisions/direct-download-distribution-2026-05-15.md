---
title: Direct download distribution (not Mac App Store)
date: 2026-05-15
category: tooling-decisions
module: Updates
problem_type: tooling_decision
component: tooling
severity: high
applies_when:
  - Considering Mac App Store as a distribution channel
  - Auditing entitlement requirements
  - Planning a paid tier with discoverability needs
tags: [distribution, mac-app-store, sandboxing, accessibility, cgeventtap, sparkle]
---

# Direct download distribution (not Mac App Store)

## Context

Two distribution paths for a macOS app:

1. **Mac App Store** — discovery, automatic updates, payment infrastructure built in. Sandboxed by default.
2. **Direct download** — a notarized .dmg from our own GitHub Releases, with Sparkle 2 for auto-updates.

NoType needs Accessibility permission and `CGEventTap` (push-to-talk hotkey detection — see `solutions/design-patterns/right-option-cgeventtap-2026-05-15.md`).

## Guidance

**Ship as a notarized .dmg with Sparkle 2 for updates.** Not on the Mac App Store.

## Why This Matters

- **Accessibility + `CGEventTap` fight MAS sandboxing.** Both technically work in MAS-sandboxed apps, but with extra entitlement reviews and edge-case bugs. For a free OSS app, the MAS overhead — review cycles, entitlement justifications, sandbox debugging — isn't worth it.
- **Sparkle gives us update infrastructure for free.** EdDSA signature verification, atomic in-place replacement, TCC preservation, ACL-aware Keychain access. See `solutions/tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md`.
- **Discovery is not a v1 priority.** Users find NoType through the README / blog / mouth, not through Mac App Store search. A free OSS app that depends on a power-user permission (Accessibility) self-selects an audience that doesn't browse MAS.

## When to Apply

- Default for v1 distribution.
- Reconsider when: the project goes paid-tier and wants MAS discovery. Then evaluate the entitlement-review cost against the addressable-audience win.

## Examples

**The shipping pipeline** (`scripts/release.sh` + `scripts/publish_release.sh`):

1. `xcodegen generate` → `xcodebuild archive` → notarize → staple.
2. Build .dmg, sign + notarize + staple.
3. Build .zip (Sparkle artefact), sign with EdDSA via `sign_update`.
4. `gh release create` with both attached, appcast item committed.

## Related

- `docs/decisions.md` ADR-012 — legacy index entry, redirects here.
- `solutions/tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md` — the auto-update mechanism this distribution choice unlocks.
- `solutions/design-patterns/right-option-cgeventtap-2026-05-15.md` — the `CGEventTap` requirement that drives the MAS-incompatibility.
- `docs/build.md` — full release recipe.
