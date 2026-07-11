# Build, run, test, ship

## Local development

Requirements:
- macOS 15 (Sequoia) or later (deployment target — see ADR-001).
- Xcode 26 or later (needed for the macOS 26 SDK we link against; the resulting binary still runs on 15+).
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

- **Don't build when you don't need to.** Prompt-text edits, doc edits, comment-only changes — no build required. Only build when Swift source has changed and you actually need to verify it compiles. This is the simplest way to avoid the LaunchServices duplicate described in the next rule.
- **After every required build, delete the freshly-built bundle from DerivedData.** `xcodebuild` runs a `RegisterWithLaunchServices` step on the freshly-signed `NoType.app` and `lsd` (the LaunchServices daemon) **continually re-scans `~/Library/Developer/Xcode/DerivedData/` on a few-second interval** and re-registers anything it finds. This means **`lsregister -u` alone does not work** — within 3 seconds of running it, `lsd` re-discovers the on-disk bundle and brings the registration back. We learned this the hard way after ten failed cleanup rounds.
  The only durable fix is to delete the bundle itself so `lsd` has nothing to find:
  ```bash
  # Run after EVERY xcodebuild build / test (archive is the exception — see below).
  # Glob covers all DerivedData hashes; Debug + Release both register.
  find "$HOME/Library/Developer/Xcode/DerivedData" \
       -maxdepth 6 \
       -path "*/NoType-*/Build/Products/*/NoType.app" \
       -type d -prune -exec rm -rf {} +
  ```
  Xcode's intermediate object/archive caching lives under `Build/Intermediates.noindex/` (which `lsd` ignores by name), not in the `.app` bundle, so deleting the bundle does NOT trigger a full rebuild — the next build re-links from cached objects in seconds.
  Cross-check with `mdfind "kMDItemCFBundleIdentifier == 'app.notype'"` — only `/Applications/NoType.app` should appear.
  Spotlight UI keeps a short-lived render cache; if a phantom entry still shows after the sweep, `killall Dock` forces an immediate refresh.
- **One-time `.metadata_never_index` markers.** Drop empty `.metadata_never_index` files at `~/Library/Developer/Xcode/DerivedData/` and `<repo>/build/` (already done — keep them there). They tell Spotlight to skip metadata indexing of these trees so a stray bundle that survives the rm sweep doesn't surface via `mdfind`. The marker does NOT stop `lsd` registration — only deletion does — but it's a useful belt-and-braces for Spotlight's separate index. Don't commit the marker in `<repo>/build/` (the path is already in `.gitignore`).
- **`xcodebuild archive` is an exception.** The release script (`scripts/release.sh`) writes a `NoType.xcarchive` to `<repo>/build/NoType.xcarchive/` deliberately — the archive's inner `NoType.app` is the input to notarization. Do NOT delete it; the script needs it. The repo's `build/` marker keeps it out of Spotlight, and `lsd` registers it as `<repo>/build/NoType.xcarchive/Products/Applications/NoType.app` which is benign (`.app` inside `.xcarchive` — Finder treats the parent as a document, not an app, so Launchpad usually doesn't surface it). After a successful release flow, the user is free to `rm -rf build/NoType.xcarchive` when they don't need the archive anymore.
- **`build/export/NoType.app` IS a Launchpad-duplicate trap — clean it up after each release.** `scripts/release.sh` also writes a fully-formed `NoType.app` to `<repo>/build/export/NoType.app` (copied out of the archive with `ditto`, then code-signed inside-out — it's the input to the DMG step and the `.zip` Sparkle artefact). Unlike the bundle inside `.xcarchive`, this one **does** get indexed by Spotlight and **does** appear as a second "NoType" entry in Launchpad — empirically the `.metadata_never_index` marker at `build/` does NOT reliably cover nested `.app` bundles below it. So after publishing a release (`scripts/publish_release.sh`), clean up:
  ```bash
  rm -rf build/export
  # Cross-check: only /Applications/NoType.app should remain
  mdfind "kMDItemCFBundleIdentifier == 'app.notype'"
  # If Launchpad still shows the duplicate, force the Dock to refresh:
  killall Dock
  ```
  `build/` is gitignored, so deletion never reaches a commit. The release script does not auto-clean `build/export/` because a failed publish might want to re-run the upload step without rebuilding — leaving it to the user (or the post-publish followup) is the safer default. Agents should run the cleanup above (and offer it to the user) whenever they detect `build/export/NoType.app` exists alongside `/Applications/NoType.app` via `mdfind`.
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

### Cutting a release (local)

Releases are cut **locally** from the maintainer's Mac. The signing keys (Developer ID cert + private key, Sparkle EdDSA key, notary credentials) live only in your local Keychain and never touch CI — that's a deliberate security choice (see "Release credentials" below). **There is no GitHub Actions release workflow**; pushing a tag does not trigger anything.

```bash
# 1. On main (via PR), bump version + add CHANGELOG entry.
#    NoType/Info.plist:
#      CFBundleShortVersionString  →  X.Y.Z      (semantic; tag will be vX.Y.Z)
#      CFBundleVersion             →  N          (monotonic integer; > previous)
#    CHANGELOG.md:
#      ## [X.Y.Z] — YYYY-MM-DD
#      ...what changed...

# 2. Build + notarize + DMG + .zip (~10 min; ~5 of that is Apple notary).
./scripts/release.sh

# 3. Sign the .zip, patch docs/appcast.xml, commit/push to main, tag, GitHub Release.
./scripts/publish_release.sh
```

`publish_release.sh` is idempotent — if a Release for the current version already exists on GitHub, it exits without doing anything. It also **creates and pushes the `vX.Y.Z` tag itself**, so you do not tag manually.

Hyphenated tags (`v0.1.2-rc1`, `v0.2.0-beta`) are uploaded as **prerelease** on GitHub — they still appear in the appcast, so installed copies pick them up. To test before serving anyone, run `publish_release.sh --dry-run` first.

Installed copies of NoType see the new version on their next scheduled Sparkle check (≤ 24 h), or immediately when the user next opens the main window after a launch with no recent check.

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

### Release credentials (local only)

There are **no GitHub Actions secrets** for releasing. The CI release workflow was removed (2026-06-01) and the six release secrets (`DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD`, `TEAM_ID`, `SPARKLE_ED_PRIVATE_KEY`) were deleted, so no software-signing key sits in CI's attack surface. Everything `release.sh` / `publish_release.sh` need lives on the maintainer's Mac:

| Credential | Where it lives |
|---|---|
| Developer ID Application cert + private key | login Keychain (`security find-identity -p codesigning -v`) |
| Notary credentials (Apple ID + app-specific password) | `notype-notary` keychain profile (`xcrun notarytool store-credentials`) |
| Sparkle EdDSA private key | login Keychain (placed by `generate_keys` at setup) |

Nothing here is base64'd into a repo secret. If you ever want CI releases back, re-add the secrets and restore `.github/workflows/release.yml` from git history — but the keys then re-enter CI's attack surface, which is the exact thing local signing avoids. Note: **don't regenerate the Sparkle EdDSA keypair** to "rotate" it — `SUPublicEDKey` is baked into every shipped binary, so a new key orphans auto-updates for already-installed copies.

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
