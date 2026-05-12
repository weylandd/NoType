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

### Cutting a release — the happy path

Releases are driven by **git tags**. Pushing `vX.Y.Z` fires `.github/workflows/release.yml` which builds + notarizes on a GitHub-hosted macOS runner, signs the Sparkle artefact, publishes the GitHub Release, and commits the updated `docs/appcast.xml` back to `main`. End-users on an older version see the update via Sparkle within 24 h (or immediately if they re-open the main window after the next check fires).

```bash
# 1. Bump version on main (PR or direct commit).
#    Edit NoType/Info.plist:
#      CFBundleShortVersionString  →  X.Y.Z      (semantic)
#      CFBundleVersion              →  N         (monotonic integer; > previous)
#    Add an entry to CHANGELOG.md describing what changed.

# 2. Tag the commit. Tag name MUST be `v` + CFBundleShortVersionString.
git tag v0.1.2
git push origin v0.1.2
```

That's it. Watch the workflow on GitHub Actions; ~10–15 minutes later the release is live, the appcast has the new `<item>`, and existing installs will pick it up on their next scheduled check.

### What the workflow does

1. Checkout at the tag (full history so the appcast push to `main` works).
2. Install xcodegen + Sparkle CLI tools (downloaded as a tarball from Sparkle's release page; pinned via `SPARKLE_VERSION` env var in the workflow).
3. Import the Developer ID Application certificate from GitHub Secrets.
4. Create the `notype-notary` notarytool keychain profile from Apple secrets.
5. Sanity-check that the tag version equals `CFBundleShortVersionString`.
6. Run `scripts/release.sh` — archive + export + notarize + staple + DMG, plus the new `.zip` for Sparkle.
7. Run `sign_update` against the `.zip` to produce the EdDSA signature.
8. Switch to `main`, run `scripts/sparkle_appcast_item.sh` to insert a new `<item>` into `docs/appcast.xml`, commit, push.
9. Create the GitHub Release with the `.dmg` and `.zip` attached, body from `CHANGELOG.md`.

Tags with a hyphen (`v0.1.2-rc1`, `v0.2.0-beta`) are marked as **prerelease** on GitHub but **still appear in the appcast** — Sparkle has no separate prerelease channel yet. If you want to test a release without offering it to existing users, hold the push to `main` (i.e. tag a side branch and delete the appcast commit before merging).

### Required GitHub Secrets

The workflow needs six secrets in **Settings → Secrets and variables → Actions**:

| Name                              | Value                                                                                    |
|---|---|
| `DEVELOPER_ID_CERT_P12`           | base64 of `Developer ID Application` certificate exported as `.p12`                       |
| `DEVELOPER_ID_CERT_PASSWORD`      | password set when exporting the `.p12`                                                    |
| `APPLE_ID`                        | Apple ID email used for notarization                                                       |
| `APPLE_APP_PASSWORD`              | app-specific password generated at [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords |
| `TEAM_ID`                         | `49T6U8DQXZ`                                                                              |
| `SPARKLE_ED_PRIVATE_KEY`          | base64 EdDSA private key exported via `generate_keys -x sparkle_private_key.txt`           |

Exporting the certificate (one-time):

```bash
# Find it in the login Keychain
security find-identity -p codesigning -v
# Export to a .p12 (Keychain Access app: right-click → Export, or:)
security export -k login.keychain -t identities -f pkcs12 \
    -P "<choose a strong password>" \
    -o ~/Desktop/NoType-DeveloperID.p12

# Convert to base64 for GitHub Secrets
base64 -i ~/Desktop/NoType-DeveloperID.p12 | pbcopy
# Paste into the DEVELOPER_ID_CERT_P12 secret.
```

The Sparkle ED key:

```bash
# Sparkle tools live in the cask; the CLI is in /Applications/Sparkle.app/Contents/MacOS/
brew install --cask sparkle
# Or download the tarball — see .github/workflows/release.yml for the URL.

generate_keys                                        # Stores the private key in Keychain
generate_keys -x sparkle_private_key.txt             # Exports a base64 copy for the secret
generate_keys -p                                     # Prints the public key — paste into Info.plist
```

Paste the contents of `sparkle_private_key.txt` into the `SPARKLE_ED_PRIVATE_KEY` GitHub Secret. Delete the local file once it's safely in the secret + your password manager (lose it = future updates rejected).

### Running the script locally (without CI)

`scripts/release.sh` is fully usable on its own when you need to validate the release pipeline without triggering CI. It produces `build/NoType-<version>.dmg` AND `build/NoType-<version>.zip`, and prints the EdDSA signature for the zip (if Sparkle's `sign_update` is on PATH).

**Do not run `scripts/release.sh` from an agent** — it talks to Apple's notary service and ships a real binary; let the user invoke it.

### GitHub Pages — one-time setup

The appcast is served from `https://weylandd.github.io/NoType/appcast.xml`. To enable:

1. Repo Settings → Pages.
2. Source: `Deploy from a branch`.
3. Branch: `main`, Folder: `/docs`.
4. Save. ~30 s later the URL resolves to the live XML.

That's it; the release workflow pushes new items into `docs/appcast.xml` on `main`, and Pages re-deploys automatically.

---

## Releasing v0.x (beta)

Beta tagging convention: `v0.MINOR.PATCH` (e.g. `v0.1.0`). Use GitHub Releases. Each release should include:
- The signed, notarized DMG.
- Auto-generated changelog (Conventional Commits since previous tag).
- A short "what's new" paragraph for users.

Once we hit v1, switch to `v1.MINOR.PATCH` and start tracking breaking changes carefully.
