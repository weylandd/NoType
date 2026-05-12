#!/usr/bin/env bash
#
# publish_release.sh — publish a locally-built NoType release.
#
# Assumes `./scripts/release.sh` has already produced:
#   build/NoType-<version>.dmg
#   build/NoType-<version>.zip
#
# This script then:
#   1. Signs the .zip with Sparkle's EdDSA private key (read from Keychain
#      by `sign_update` — placed there once by `generate_keys`).
#   2. Extracts the current version's section from CHANGELOG.md.
#   3. Patches docs/appcast.xml with a new <item> via
#      `scripts/sparkle_appcast_item.sh`, commits, and pushes to origin.
#   4. Creates (if missing) and pushes the git tag `v<version>`.
#   5. Creates the GitHub Release with the .dmg + .zip attached and the
#      extracted CHANGELOG section as release notes — via the `gh` CLI.
#
# Prerequisites (one-time):
#   brew install gh                                 # GitHub CLI
#   gh auth login                                   # log into your account
#
#   # Sparkle CLI `sign_update`. The canonical location is
#   #   tools/sparkle/sign_update   (gitignored — see tools/sparkle/README.md
#   #                                for the curl + tar + cp recipe)
#   # The script also falls back to PATH, ~/Downloads/Sparkle-*/bin, and
#   # /tmp/sparkle/bin, or you can pass --sparkle-bin <dir> explicitly.
#
# Usage:
#   ./scripts/publish_release.sh                    # publish current Info.plist version
#   ./scripts/publish_release.sh --dry-run          # don't push/release; print what would happen
#   ./scripts/publish_release.sh --sparkle-bin /path/to/Sparkle/bin
#
# Idempotent: if the GitHub Release for this version already exists, exits 0
# without re-publishing. Re-run after deleting the Release if you need to redo.

set -euo pipefail

cd "$(dirname "$0")/.."

DRY_RUN=false
SPARKLE_BIN_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)     DRY_RUN=true; shift ;;
        --sparkle-bin) SPARKLE_BIN_OVERRIDE="$2"; shift 2 ;;
        -h|--help)     sed -n '1,40p' "$0"; exit 0 ;;
        *)             echo "✗ unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------
# Locate `sign_update` from a few well-known places. Search order:
#   1. --sparkle-bin <dir>   (explicit override)
#   2. tools/sparkle/        (the canonical in-repo location, gitignored)
#   3. on PATH
#   4. ~/Downloads/Sparkle-*/bin
#   5. /tmp/sparkle/bin
# ---------------------------------------------------------------------
SIGN_UPDATE=""
candidates=()
if [[ -n "$SPARKLE_BIN_OVERRIDE" ]]; then
    candidates+=("$SPARKLE_BIN_OVERRIDE/sign_update")
fi
candidates+=("tools/sparkle/sign_update")
if command -v sign_update >/dev/null 2>&1; then
    candidates+=("$(command -v sign_update)")
fi
# Newest-first so a freshly-downloaded version wins over an older one.
while IFS= read -r path; do
    candidates+=("$path")
done < <(ls -dt "$HOME"/Downloads/Sparkle-*/bin/sign_update 2>/dev/null || true)
candidates+=("/tmp/sparkle/bin/sign_update")

for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then
        SIGN_UPDATE="$c"
        break
    fi
done

if [[ -z "$SIGN_UPDATE" ]]; then
    cat <<EOF >&2
✗ sign_update not found. Drop one into tools/sparkle/sign_update — see
  tools/sparkle/README.md for the curl + tar + cp recipe. Alternatively
  pass --sparkle-bin <path-to-Sparkle/bin> at the command line.
EOF
    exit 1
fi
echo "▶ sign_update: ${SIGN_UPDATE}"

# ---------------------------------------------------------------------
# Sanity-check `gh` is installed and authenticated.
# ---------------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
    echo "✗ gh CLI not found. Install with: brew install gh" >&2
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "✗ gh CLI not authenticated. Run: gh auth login" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# Read version + verify artefacts.
# ---------------------------------------------------------------------
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" NoType/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy   -c "Print :CFBundleVersion"            NoType/Info.plist)
TAG="v${VERSION}"
DMG_PATH="build/NoType-${VERSION}.dmg"
ZIP_PATH="build/NoType-${VERSION}.zip"

echo "▶ Publishing NoType ${VERSION} (build ${BUILD}) as ${TAG}"

for f in "$DMG_PATH" "$ZIP_PATH"; do
    if [[ ! -f "$f" ]]; then
        echo "✗ Missing $f. Run ./scripts/release.sh first." >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------
# Branch + tree guard.
# ---------------------------------------------------------------------
BRANCH=$(git branch --show-current)
if [[ "$BRANCH" != "main" ]]; then
    echo "✗ Must be on 'main' to publish a release (currently on '$BRANCH')." >&2
    echo "    Switch via: git checkout main && git pull" >&2
    exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "✗ Working tree has uncommitted changes. Commit/stash before publishing:" >&2
    git status --short >&2
    exit 1
fi

# ---------------------------------------------------------------------
# Idempotency: skip if Release already exists.
# ---------------------------------------------------------------------
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "ℹ Release ${TAG} already exists on GitHub — exiting (delete it manually if you want to re-publish)"
    exit 0
fi

# ---------------------------------------------------------------------
# 1. Sign the .zip with Sparkle EdDSA. Output is one line of the form:
#    sparkle:edSignature="..." length="..."
# ---------------------------------------------------------------------
echo "▶ Signing ${ZIP_PATH} with Sparkle EdDSA"
SIG_LINE=$("$SIGN_UPDATE" "$ZIP_PATH")
echo "    $SIG_LINE"

# ---------------------------------------------------------------------
# 2. Extract release notes for $VERSION from CHANGELOG.md.
# ---------------------------------------------------------------------
NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT

VERSION="$VERSION" python3 - <<'PYEOF' > "$NOTES_FILE"
import os, re, sys

version = os.environ["VERSION"]
with open("CHANGELOG.md", encoding="utf-8") as f:
    content = f.read()

# Match `## [VERSION] ...\n` up to the next `## [...` or EOF.
pattern = r"^##\s*\[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^##\s*\[|\Z)"
m = re.search(pattern, content, re.DOTALL | re.MULTILINE)
if m:
    notes = m.group(1).strip()
else:
    notes = f"Version {version}."

# Strip the trailing reference-link definitions block if it leaked in.
notes = re.sub(r"\n+\[[^\]]+\]:\s*http[^\n]+(?:\n|\Z)", "\n", notes).strip()
print(notes if notes else f"Version {version}.")
PYEOF

echo "▶ Release notes for ${VERSION}:"
sed 's/^/    | /' "$NOTES_FILE"

# ---------------------------------------------------------------------
# 3. Patch docs/appcast.xml and commit on main.
# ---------------------------------------------------------------------
echo "▶ Patching docs/appcast.xml"
scripts/sparkle_appcast_item.sh \
    --version   "$VERSION" \
    --build     "$BUILD" \
    --signature "$SIG_LINE" \
    --notes-file "$NOTES_FILE" \
    --output-appcast docs/appcast.xml

if $DRY_RUN; then
    echo
    echo "✓ Dry run complete — appcast patched locally."
    echo "    Would tag:    $TAG"
    echo "    Would push:   docs/appcast.xml on main"
    echo "    Would release: $DMG_PATH + $ZIP_PATH"
    echo
    echo "Revert local appcast change with: git checkout docs/appcast.xml"
    exit 0
fi

if [[ -n "$(git status --porcelain docs/appcast.xml)" ]]; then
    echo "▶ Committing appcast on main"
    git add docs/appcast.xml
    git commit -m "chore(release): publish ${TAG} appcast"
    git push origin HEAD
else
    echo "ℹ appcast.xml unchanged (already contains ${VERSION}) — skipping commit"
fi

# ---------------------------------------------------------------------
# 4. Create + push tag.
# ---------------------------------------------------------------------
if git rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null; then
    echo "ℹ Tag ${TAG} already exists locally — reusing"
else
    git tag -a "$TAG" -m "$TAG"
fi
echo "▶ Pushing tag ${TAG}"
git push origin "$TAG" || true   # `|| true` so we don't fail if tag is already on origin

# ---------------------------------------------------------------------
# 5. GitHub Release.
# ---------------------------------------------------------------------
PRERELEASE_FLAGS=()
if [[ "$TAG" == *-* ]]; then
    PRERELEASE_FLAGS=(--prerelease)
fi

echo "▶ Creating GitHub Release ${TAG}"
gh release create "$TAG" \
    "$DMG_PATH" \
    "$ZIP_PATH" \
    --title "$TAG" \
    --notes-file "$NOTES_FILE" \
    "${PRERELEASE_FLAGS[@]}"

echo
echo "✓ Released ${TAG}"
echo "    Appcast:  https://weylandd.github.io/NoType/appcast.xml"
echo "    Release:  https://github.com/weylandd/NoType/releases/tag/${TAG}"
echo
echo "Installed copies will pick up the update on their next scheduled check (≤24 h),"
echo "or immediately if you re-open NoType."
