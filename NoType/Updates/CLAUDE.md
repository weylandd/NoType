# Updates module

Auto-update path for NoType, built on **Sparkle 2** (SPM dependency, `from: 2.6.0`).

## Files

- `UpdateController.swift` — `@MainActor @Observable` SwiftUI-facing controller. Wraps `SPUUpdater`, exposes `phase`, drives the sidebar banner. Public methods: `installNow()` (banner main-body tap), `dismiss()` (postpone — `.dismiss`), `skipThisVersion()` (X chip on `.available` banner — `.skip`), `checkForUpdates()` (Settings → Updates button).
- `UpdateUserDriver.swift` — custom `SPUUserDriver`. Routes every Sparkle UI event into `UpdateController.phase` instead of showing Sparkle's modal alert. Captures Sparkle's reply callbacks so the banner's click can dispatch `.install` / `.dismiss` / `.skip` back into Sparkle's state machine.

UI surface: `NoType/UI/UpdateBanner.swift` (rendered at the bottom of the main-window sidebar via `MainWindowView.sidebar`) — `.available` phase uses the `AvailableBannerCard` variant with a trailing X chip. Settings → Updates row in `NoType/UI/Settings/SettingsTabView.swift` drives `checkForUpdates()`.

## Invariants

1. **Sparkle's standard modal alert is bypassed entirely.** All UI runs through `UpdateController.phase` + `UpdateBanner`.
2. **`Info.plist` contract:**
   - `SUFeedURL` = `https://weylandd.github.io/NoType/appcast.xml`.
   - `SUPublicEDKey` = base64 EdDSA public key. Sparkle verifies every downloaded `.zip` against this.
   - `SUEnableAutomaticChecks` = `true`.
   - `SUScheduledCheckInterval` = `86400` (24 hours).
   - `SUEnableInstallerLauncherService` deliberately NOT set — NoType is non-sandboxed; Sparkle 2 installs the `.zip` directly without the XPC installer-launcher service.
3. **`@preconcurrency import Sparkle`** in both files — absorbs the few callback closures Sparkle hasn't yet annotated as `Sendable`. Drop when Sparkle ships full Swift 6 concurrency support.
4. **`UpdateController.start()` is called from `applicationDidFinishLaunching(_:)`**, not from `init()`. Sparkle wants a live `NSApplication` to attach to, which that hook satisfies. It rides `NoTypeAppDelegate.launchHandler` alongside `AppearanceController.apply()` + `AppState.prime()` — see `NoType/UI/CLAUDE.md` "Launch ordering". **It used to be a `.task` on the main `Window`, which was a bug**: NoType is `LSUIElement` and that window isn't presented at launch once onboarding is complete, so menu-bar-only users never checked for updates at all. Don't move it back onto a scene modifier.
5. **`start()` is idempotent** via `didStart` flag. The launch hook fires once, so the latch mostly guards `checkForUpdates()`, which calls `start()` first — that manual check is the only remaining retry if the launch-time `start()` threw (it reopens the latch on failure).
6. **`.failed(message)` auto-bounces back to `.idle` after 5 s** so the banner doesn't stay stuck on a transient error.

## Hard rules

- **Forgetting `SUPublicEDKey` or pointing at the wrong key is silent at build time** — every update is rejected at runtime with a signature mismatch. The release workflow signs with the private counterpart via `sign_update`; the two must match.
- **`xcodebuild` must stay warning-free under `SWIFT_STRICT_CONCURRENCY: complete`** after touching this module. Sparkle's bridged Obj-C API will sometimes warn — prefer `@preconcurrency` over `nonisolated(unsafe)`.

### Hard rules pending smoke verification (plan 2026-05-18-001 §682–686)

The next two rules historically prohibited a production "Check for Updates" entry point and a `checkNow()`-style API because there was no per-version skip surface. The Settings → Updates "Check for updates" button and the X chip on the `.available` banner — wired through `UpdateController.checkForUpdates()` and `UpdateController.skipThisVersion()` (dispatches `SPUUserUpdateChoice.skip`) — jointly close that prohibition (R23 + R24). **The rules stay in place until a manual smoke against an EdDSA-signed staged release confirms that Sparkle persists `.skip` per-version under our custom `SPUUserDriver`**:

1. Install `v0.0.1-rc1` → wait for the banner → click X.
2. Wait for the next scheduled check (or override `SUScheduledCheckInterval` to ~60 s in a debug build) → confirm **no** re-show for `v0.0.1-rc1`.
3. Publish `v0.0.1-rc2` → confirm the banner reappears for the new version.

If the smoke passes, delete the two rules below and this preamble. If it fails, add a fallback `notype.update.skippedVersion: String` UserDefaults flag and have `UpdateUserDriver.showUpdateFound(...)` filter against it before publishing `.available(update)` to the controller — Sparkle's persistence path may live in `SPUStandardUserDriver` (which we bypass), in which case our custom driver needs to persist locally instead.

- **Don't ship a non-debug "Check for Updates" entry point** without a product discussion — it would also require a "skip this version" surface, which we don't have. For QA, add a temporary `#if DEBUG` wrapper around an `updater.checkForUpdates()` call inside `UpdateController` and don't commit it.
- **Don't restore `checkNow()` as production API.** It was removed in PR #8 — never wired up. Use the `#if DEBUG` recipe above if you need it for QA. (The new method is named `checkForUpdates()` to avoid confusion with the deleted `checkNow()`.)

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
- `NoTypeTests/UpdateControllerStateTests.swift` — pins the phase state machine + `skipThisVersion()` / `dismiss()` / `installNow()` reply-slot dispatch with synthetic closures. The Sparkle SDK itself isn't mocked; integration via the live release pipeline is the source of truth for everything past the controller's `pending*` slots.

## Pointers

- Why Sparkle 2 + custom banner (not `SPUStandardUserDriver`, not Sparkle 1) → `solutions/tooling-decisions/sparkle-2-with-custom-banner-ui-2026-05-15.md`.
- Why direct download (not MAS) → `solutions/tooling-decisions/direct-download-distribution-2026-05-15.md`.
- Release workflow (xcodegen → archive → notarize → sign → publish) → `docs/build.md`.
