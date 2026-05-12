# Build, run, test, ship

## Local development

Requirements:
- macOS 26 (Tahoe) or later.
- Xcode 26 or later.
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The Xcode project is regenerated from `project.yml` — do not edit `NoType.xcodeproj/project.pbxproj` by hand.
- A Gemini API key for live testing (free tier is enough for development).

```bash
# Regenerate NoType.xcodeproj from project.yml whenever you add files,
# change targets, or pull a change that touched project.yml.
xcodegen generate

# Open in Xcode
open NoType.xcodeproj

# Or build from CLI:
xcodebuild -project NoType.xcodeproj \
           -scheme NoType \
           -configuration Debug \
           build

# Run unit tests:
xcodebuild -project NoType.xcodeproj \
           -scheme NoType \
           test -destination 'platform=macOS'
```

Integration tests against the live Gemini API are gated behind the env var `NOTYPE_INTEGRATION=1`. They live alongside the unit tests in `NoTypeTests/` and skip themselves when the variable is unset — no separate scheme today.

---

## Building from Claude Code / automation

When verifying changes compile, **always** build into Xcode's default DerivedData:

```bash
xcodebuild -project NoType.xcodeproj -scheme NoType -configuration Debug build
```

Hard rules:

- **Never** pass `-derivedDataPath` (or any flag that redirects build output into the repo, e.g. `./build/`). Output landing inside the working tree creates a duplicate `NoType.app` that macOS Spotlight indexes alongside the real one — the user ends up with multiple "NoType" entries in Launchpad / app pickers and can't tell which build they're launching. The repo `.gitignore` covers `build/`, so it won't reach a commit, but the on-disk duplicate is still confusing.
- **Never** open / `open NoType.app` / launch the built bundle. The app installs a CGEventTap, mic recorder, and menu-bar UI — launching it from an agent surprises the user. Building is enough to verify the change compiles.
- If you ever need to locate the freshly built bundle (e.g. to inspect Info.plist, sign-state, or resource layout), it's always at `~/Library/Developer/Xcode/DerivedData/NoType-*/Build/Products/Debug/NoType.app`.
- If a previous run did leave a `build/` folder in the repo or a stale `NoType-<oldhash>/` directory in DerivedData, removing it is fine — but ask the user before deleting anything under `/Applications/` (those are real installs, not build artefacts).

The same rules apply for archive / release builds (`xcodebuild ... archive`): default DerivedData unless the user explicitly asks for a specific output directory. The release script (see "Release build & notarization" below) is the exception — it writes to `build/` deliberately, because the DMG output is the user-facing artefact.

---

## Setting the Gemini key for development

Two options:

1. **In-app Settings.** Run NoType, open Settings from the menu-bar popover, paste the key. Persisted in the macOS Keychain via `SecretStore` (see ADR-011 and `NoType/Keychain/CLAUDE.md`). Earlier builds used a 0600 JSON file under `~/Library/Application Support/NoType/`; that file is migrated into the Keychain transparently on first launch of a Keychain-backed build.
2. **Environment variable.** Set `NOTYPE_GEMINI_KEY` before launching NoType. Read at startup *only if* the Keychain has no entry. Never persisted from env — env is for ephemeral dev use.

For CI / integration tests, use `NOTYPE_GEMINI_KEY` exclusively.

---

## First-run permissions

On first launch you'll be prompted for Microphone and Accessibility — the onboarding wizard walks through both. NoType does **not** request Speech Recognition (we use Silero, not Apple's speech stack). If you deny by accident, re-grant in System Settings → Privacy & Security; the wizard can also reopen the relevant pane directly.

---

## Release build & notarization

The project is signed with Apple Developer Team ID `49T6U8DQXZ` (see `project.yml` → `DEVELOPMENT_TEAM`) and uses a stable designated requirement (`signing/NoType.xcrequirements` — `designated => identifier "app.notype"`) so TCC grants and Keychain ACLs survive dev rebuilds.

To cut a new release:

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `NoType/Info.plist`.
2. From the repo root, run `./scripts/release.sh`.

The script reads the version from `Info.plist`, regenerates the Xcode project, archives + exports + signs the `.app`, notarizes both the `.app` and the `.dmg` via the `notype-notary` keychain profile, staples both, and emits `build/NoType-<version>.dmg` ready to ship. The Developer ID identity is auto-discovered from the login Keychain.

One-time prerequisites on a fresh machine (already done on the current dev box):
- A "Developer ID Application" certificate in the login Keychain (`security find-identity -p codesigning -v` to verify).
- A notarytool keychain profile named `notype-notary`: `xcrun notarytool store-credentials "notype-notary" --apple-id "<id>" --team-id "49T6U8DQXZ"` (will prompt for an app-specific password).
- `xcodegen` on PATH (`brew install xcodegen`).

**Do not run `scripts/release.sh` from an agent** — it talks to Apple's notary service and ships a real binary; let the user invoke it.

---

## Auto-updates — planned

Sparkle is **not yet wired up**. The plan for v0.1.0 RC:

1. Add `Sparkle` via SPM, set `SUPublicEDKey` in `Info.plist`.
2. Host an appcast at a stable URL (TBD when domain is set up; tentatively `https://notype.app/appcast.xml`).
3. Per-release: bump `CFBundleShortVersionString` + `CFBundleVersion`, build/notarize as above, sign the DMG with Sparkle's `sign_update` tool, upload, append the entry to `appcast.xml`.

Until Sparkle lands, ship updates as new DMGs via GitHub Releases; users re-download manually.

---

## Releasing v0.x (beta)

Beta tagging convention: `v0.MINOR.PATCH` (e.g. `v0.1.0`). Use GitHub Releases. Each release should include:
- The signed, notarized DMG.
- Auto-generated changelog (Conventional Commits since previous tag).
- A short "what's new" paragraph for users.

Once we hit v1, switch to `v1.MINOR.PATCH` and start tracking breaking changes carefully.
