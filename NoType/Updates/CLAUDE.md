# Updates module

Auto-update path for NoType, built on **Sparkle 2** (SPM dependency, `from: 2.6.0`). See `docs/build.md` for the release-cutting workflow and `docs/decisions.md` ADR-012 for the "non-MAS direct distribution" rationale.

Files:
- `UpdateController.swift` — `@MainActor @Observable` SwiftUI-facing controller. Wraps `SPUUpdater`, exposes `phase`, drives the sidebar banner.
- `UpdateUserDriver.swift` — custom `SPUUserDriver`. Routes every Sparkle UI event into `UpdateController.phase` instead of showing Sparkle's modal alert window. Captures Sparkle's reply callbacks so the banner's click can dispatch `.install` / `.dismiss` back into Sparkle's state machine.

The UI surface lives in `NoType/UI/UpdateBanner.swift` (rendered at the bottom of the main-window sidebar via `MainWindowView.sidebar`).

---

## Why a custom user driver

Sparkle 2 ships `SPUStandardUserDriver` which shows its own modal alert windows for "update available", "downloading", and "ready to install". That's the wrong shape for a menu-bar utility with `LSUIElement = true` — modal Sparkle windows steal focus and look out of place next to NoType's compact in-app UI.

`SPUUserDriver` is a first-class protocol in Sparkle 2 specifically for embedding the update prompt inside your own UI. We adopt it directly. Every protocol method captures the relevant reply callback on `UpdateController` and updates `phase`; the banner reads `phase` and the button action invokes the stashed callback.

---

## Info.plist contract

Four keys, all in `NoType/Info.plist`:

| Key                          | Value                                                       | Why                                                                                            |
|---|---|---|
| `SUFeedURL`                  | `https://weylandd.github.io/NoType/appcast.xml`             | GitHub Pages from `docs/` of this repo. Stable, CDN-cached, no rate limits.                    |
| `SUPublicEDKey`              | base64 EdDSA public key (from `generate_keys`)              | Sparkle verifies every downloaded .zip against this. Private counterpart lives in CI secrets. |
| `SUEnableAutomaticChecks`    | `<true/>`                                                   | Daily background check.                                                                        |
| `SUScheduledCheckInterval`   | `86400`                                                     | 24 hours, in seconds.                                                                          |

We do **not** set `SUEnableInstallerLauncherService` — NoType is non-sandboxed (ADR-012), so Sparkle 2 installs the .zip into `/Applications` directly without the XPC installer-launcher service.

Forgetting `SUPublicEDKey` or pointing it at the wrong key is silent at build time but every update will be rejected at runtime with a signature mismatch. The release workflow signs with the private counterpart via `sign_update`; the two must match.

---

## Threading & strict concurrency

The protocol `SPUUserDriver` is `@MainActor` in Sparkle 2.6+, so `UpdateUserDriver` is `@MainActor final class NSObject, SPUUserDriver`. Both files do `@preconcurrency import Sparkle` to absorb the few callback closures Sparkle hasn't yet annotated as `Sendable`. Treat that as a precaution — when Sparkle ships full Swift 6 concurrency support we can drop the attribute.

`UpdateController.start()` must be called from a SwiftUI scene's `.task` (or otherwise after `NSApplication.shared` is alive), **not** from `init()`. `NoTypeApp.body` attaches the call via `.task { updates.start() }` on the main `Window`. The call is idempotent — `didStart` guards against SwiftUI re-firing `.task` on window re-presentation.

---

## Phase state machine

```
                 ┌─────┐
                 │ idle│◀─────────────────────────────────────────┐
                 └──┬──┘                                          │
        background  │ (Sparkle scheduler)                         │ Sparkle
        check       ▼                                             │ dismiss
                 ┌──────────┐  appcast says nothing new           │
                 │ checking │─────────────────────────────────────┤
                 └────┬─────┘                                     │
                      │ showUpdateFound(...)                      │
                      ▼                                           │
              ┌────────────┐  user clicks Dismiss / banner closed │
              │ available  │──────────────────────────────────────┤
              └─────┬──────┘                                      │
                    │ user clicks banner → installNow()           │
                    ▼                                             │
              ┌─────────────┐                                     │
              │ downloading │                                     │
              └─────┬───────┘                                     │
                    │ download finished                           │
                    ▼                                             │
              ┌────────────┐                                      │
              │ extracting │                                      │
              └─────┬──────┘                                      │
                    │ extraction done; driver auto-replies .install
                    ▼                                             │
              ┌────────────┐                                      │
              │ installing │── app terminates & relaunches ───────┘
              └────────────┘     (process replaced — no return path)
```

`.failed(message)` is a side branch reachable from any phase via `showUpdaterError`. The driver auto-bounces back to `.idle` after 5 s so the banner doesn't stay stuck on a transient error.

---

## Why no "Check for Updates" button (yet)

The product call (2026-05-12): for v1, automatic daily checks are the only update path. No manual trigger surface in `SettingsView`, no toggle to disable auto-checks. The banner is the only thing the user ever sees; if they ignore it, the next daily check will surface it again. This keeps the UX minimal — like Claude Desktop's update pill — and avoids cluttering Settings with options the v1 audience doesn't need.

If you need to force-trigger a check during QA, add a temporary `#if DEBUG` wrapper around an `updater.checkForUpdates()` call inside `UpdateController`; don't commit it. Don't ship a non-debug entry point without a product discussion — it would also require a "skip this version" surface, which we don't have.

---

## Testing

- **Local sanity:** rebuild after touching this module; xcodebuild must stay warning-free under `SWIFT_STRICT_CONCURRENCY: complete`. Sparkle's bridged Obj-C API will sometimes warn — when it does, prefer `@preconcurrency` over `nonisolated(unsafe)`.
- **End-to-end:** install a build of version N, then publish version N+1 via the release workflow. Set a low `SUScheduledCheckInterval` (e.g. `60`) in a local debug Info.plist override, wait, see the banner. Click → download → relaunch.
- **EdDSA tamper:** corrupt the `sparkle:edSignature` in `docs/appcast.xml` for a test release. Sparkle should refuse to install and the banner should clear (visible briefly as `.failed` then back to idle).
- **No unit tests yet** — the Sparkle SDK isn't easily mockable; integration via the live release pipeline is the source of truth.
