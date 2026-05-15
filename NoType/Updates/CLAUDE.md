# Updates module

Auto-update path for NoType, built on **Sparkle 2** (SPM dependency, `from: 2.6.0`).

## Files

- `UpdateController.swift` — `@MainActor @Observable` SwiftUI-facing controller. Wraps `SPUUpdater`, exposes `phase`, drives the sidebar banner.
- `UpdateUserDriver.swift` — custom `SPUUserDriver`. Routes every Sparkle UI event into `UpdateController.phase` instead of showing Sparkle's modal alert. Captures Sparkle's reply callbacks so the banner's click can dispatch `.install` / `.dismiss` back into Sparkle's state machine.

UI surface: `NoType/UI/UpdateBanner.swift` (rendered at the bottom of the main-window sidebar via `MainWindowView.sidebar`).

## Invariants

1. **Sparkle's standard modal alert is bypassed entirely.** All UI runs through `UpdateController.phase` + `UpdateBanner`.
2. **`Info.plist` contract:**
   - `SUFeedURL` = `https://weylandd.github.io/NoType/appcast.xml`.
   - `SUPublicEDKey` = base64 EdDSA public key. Sparkle verifies every downloaded `.zip` against this.
   - `SUEnableAutomaticChecks` = `true`.
   - `SUScheduledCheckInterval` = `86400` (24 hours).
   - `SUEnableInstallerLauncherService` deliberately NOT set — NoType is non-sandboxed; Sparkle 2 installs the `.zip` directly without the XPC installer-launcher service.
3. **`@preconcurrency import Sparkle`** in both files — absorbs the few callback closures Sparkle hasn't yet annotated as `Sendable`. Drop when Sparkle ships full Swift 6 concurrency support.
4. **`UpdateController.start()` is called from a SwiftUI scene's `.task`**, not from `init()`. Sparkle wants a live `NSApplication` to attach to. `NoTypeApp.body` attaches via `.task { updates.start() }` on the main `Window`.
5. **`start()` is idempotent** via `didStart` flag — SwiftUI's `.task` can fire multiple times across window re-presentations.
6. **`.failed(message)` auto-bounces back to `.idle` after 5 s** so the banner doesn't stay stuck on a transient error.

## Hard rules

- **Forgetting `SUPublicEDKey` or pointing at the wrong key is silent at build time** — every update is rejected at runtime with a signature mismatch. The release workflow signs with the private counterpart via `sign_update`; the two must match.
- **Don't ship a non-debug "Check for Updates" entry point** without a product discussion — it would also require a "skip this version" surface, which we don't have. For QA, add a temporary `#if DEBUG` wrapper around an `updater.checkForUpdates()` call inside `UpdateController` and don't commit it.
- **`xcodebuild` must stay warning-free under `SWIFT_STRICT_CONCURRENCY: complete`** after touching this module. Sparkle's bridged Obj-C API will sometimes warn — prefer `@preconcurrency` over `nonisolated(unsafe)`.
- **Don't restore `checkNow()` as production API.** It was removed in PR #8 — never wired up. Use the `#if DEBUG` recipe above if you need it for QA.

## Phase state machine

```
idle → checking → available → downloading → extracting → installing (process replaced)
        ↓ no update         ↓ dismiss
        idle                idle
```

`.failed(message)` is a side branch reachable from any phase via `showUpdaterError`; auto-bounces to `.idle` after 5 s.

## Testing

- **Local sanity:** rebuild after touching this module; xcodebuild stays warning-free under strict concurrency.
- **End-to-end:** install version N, publish N+1 via the release workflow. A low `SUScheduledCheckInterval` (e.g. 60 s) in a debug Info.plist override lets you watch the banner. Click → download → relaunch.
- **EdDSA tamper:** corrupt the `sparkle:edSignature` in `docs/appcast.xml` for a test release; Sparkle refuses to install and the banner clears (briefly `.failed` → `.idle`).
- **No unit tests yet** — the Sparkle SDK isn't easily mockable; integration via the live release pipeline is the source of truth.

## Pointers

- Why Sparkle 2 + custom banner (not `SPUStandardUserDriver`, not Sparkle 1) → `solutions/tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md`.
- Why direct download (not MAS) → `solutions/tooling-decisions/direct-download-distribution-2026-05-15.md`.
- Release workflow (xcodegen → archive → notarize → sign → publish) → `docs/build.md`.
