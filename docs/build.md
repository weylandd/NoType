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

### Cutting a release — the happy path (local-only, until macos-26 lands on GitHub runners)

> ⚠️ **CI is currently disabled.** GitHub-hosted `macos-latest` runners are still on macOS 15 / Xcode 16 and reject our `MACOSX_DEPLOYMENT_TARGET = 26.0` with "supported range is 10.13 to 15.5.99". The CI workflow `.github/workflows/release.yml` is preserved but its tag trigger is commented out — releases happen locally on this Mac until GitHub ships `macos-26`. Re-enable the workflow trigger at that point; the steps inside are still correct.

Releases now go through two scripts:

```bash
# 1. On main, bump version + add CHANGELOG entry. Commit & push.
#    NoType/Info.plist:
#      CFBundleShortVersionString  →  X.Y.Z      (semantic; tag will be vX.Y.Z)
#      CFBundleVersion             →  N          (monotonic integer; > previous)
#    CHANGELOG.md:
#      ## [X.Y.Z] — YYYY-MM-DD
#      ...what changed...

# 2. Build + notarize + DMG + .zip locally (~10 minutes; ~5 of that is Apple notary).
./scripts/release.sh

# 3. Sign the .zip, patch docs/appcast.xml, tag, push, create GitHub Release.
./scripts/publish_release.sh
```

That's the whole flow. `publish_release.sh` is idempotent — if a Release for the current version already exists on GitHub, it exits without doing anything.

Installed copies of NoType see the new version through their next scheduled Sparkle check (≤ 24 h), or immediately if the user opens the main window after a launch with no recent check.

### What each script does

`scripts/release.sh`:
1. `xcodegen generate` (regenerates `NoType.xcodeproj` from `project.yml`).
2. `xcodebuild archive` (Release configuration) + export with Developer ID.
3. `notarytool submit --wait` on the `.app` → staple ticket.
4. Build the `.dmg`, sign it, notarize the `.dmg`, staple.
5. `ditto -c -k --keepParent` the notarized `.app` into `build/NoType-<version>.zip` (Sparkle's artefact).

`scripts/publish_release.sh`:
1. Find `sign_update` (Sparkle CLI tool — checks `tools/sparkle/sign_update` first, then PATH, `~/Downloads/Sparkle-*/bin/`, `/tmp/sparkle/bin/`, or `--sparkle-bin <path>` flag).
2. Sign `build/NoType-<version>.zip` with the EdDSA private key (read from Keychain — placed there by `generate_keys` once at setup time).
3. Extract the version's section from `CHANGELOG.md` for release notes.
4. Patch `docs/appcast.xml` via `scripts/sparkle_appcast_item.sh`, commit & push to `main`.
5. Create + push tag `vX.Y.Z`.
6. `gh release create` with the `.dmg` and `.zip` attached, release notes from CHANGELOG.

Hyphenated tags (`v0.1.2-rc1`, `v0.2.0-beta`) are uploaded as **prerelease** on GitHub — they still appear in the appcast, so installed copies will pick them up. To test a release before serving it to anyone, run `publish_release.sh --dry-run` first.

### Required local tooling (one-time setup)

```bash
brew install xcodegen
brew install gh                            # GitHub CLI
gh auth login                              # log into your GitHub account

# Sparkle CLI `sign_update`. Live at tools/sparkle/sign_update (gitignored).
# See tools/sparkle/README.md for the obtain-once recipe. publish_release.sh
# looks there first.

# One-time: Apple Developer ID setup (already done on this Mac).
#   1. "Developer ID Application" cert in login Keychain
#      (verify with: security find-identity -p codesigning -v)
#   2. notarytool keychain profile named `notype-notary`:
#      xcrun notarytool store-credentials notype-notary \
#          --apple-id "<id>" --team-id "49T6U8DQXZ"

# One-time: Sparkle EdDSA keypair (already done — see git history for the
# public key in Info.plist, private key is in Keychain + your password manager).
```

**Do not run `scripts/release.sh` from an agent** — it talks to Apple's notary service and ships a real binary; let the human invoke it.

### CI secrets — still configured, currently unused

The six GitHub Secrets set up for the CI path (`DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD`, `TEAM_ID`, `SPARKLE_ED_PRIVATE_KEY`) stay in place. They'll start being read again the moment we re-enable the workflow trigger in `.github/workflows/release.yml` once GitHub adds `macos-26` runners. No action needed in the meantime.

### GitHub Pages — one-time setup

The appcast is served from `https://weylandd.github.io/NoType/appcast.xml`. Already enabled:

- Settings → Pages → Source: `Deploy from a branch`, Branch: `main`, Folder: `/docs`.

`publish_release.sh` commits new `<item>` entries to `docs/appcast.xml` on `main`; Pages re-deploys automatically (~30 s).

---

## Releasing v0.x (beta)

Beta tagging convention: `v0.MINOR.PATCH` (e.g. `v0.1.0`). Use GitHub Releases. Each release should include:
- The signed, notarized DMG.
- Auto-generated changelog (Conventional Commits since previous tag).
- A short "what's new" paragraph for users.

Once we hit v1, switch to `v1.MINOR.PATCH` and start tracking breaking changes carefully.
