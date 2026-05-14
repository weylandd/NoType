#!/usr/bin/env bash
#
# release.sh — build, sign, notarize, and package NoType for distribution.
#
# Prerequisites (one-time setup):
#   1. A "Developer ID Application" certificate in the login Keychain.
#      Verify with:   security find-identity -p codesigning -v
#   2. A notarytool keychain profile named "notype-notary":
#        xcrun notarytool store-credentials "notype-notary" \
#          --apple-id "<your apple id>" \
#          --team-id  "49T6U8DQXZ"
#      (it will prompt for your app-specific password)
#   3. xcodegen on PATH (brew install xcodegen).
#
# Output: build/NoType-<version>.dmg — signed, notarized, stapled, ready to send.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="NoType.xcodeproj"
SCHEME="NoType"
CONFIG="Release"
KEYCHAIN_PROFILE="notype-notary"
BUILD_DIR="build"
ARCHIVE_PATH="${BUILD_DIR}/NoType.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_OPTIONS="ExportOptions.plist"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" NoType/Info.plist)
DMG_PATH="${BUILD_DIR}/NoType-${VERSION}.dmg"
SPARKLE_ZIP_PATH="${BUILD_DIR}/NoType-${VERSION}.zip"
# Version-less alias of the .dmg. Lets the README / website use a
# stable "always points to latest" link:
#   https://github.com/weylandd/NoType/releases/latest/download/NoType.dmg
# GitHub requires the asset filename to match exactly across releases
# for `/latest/download/<filename>` to redirect — so we ship NoType.dmg
# in every release alongside the versioned one.
DMG_LATEST_PATH="${BUILD_DIR}/NoType.dmg"
STAGING="${BUILD_DIR}/dmg-staging"
ZIP_PATH="${BUILD_DIR}/NoType-notarize.zip"
APP_PATH="${EXPORT_DIR}/NoType.app"

# Look up the Developer ID Application identity (CN, e.g.
# "Developer ID Application: Иван Иванов (49T6U8DQXZ)"). We need this to
# sign the DMG itself.
SIGN_IDENTITY=$(security find-identity -p codesigning -v \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    echo "✗ No 'Developer ID Application' identity found in the login Keychain." >&2
    echo "  Open Xcode → Settings → Accounts → Manage Certificates → '+' → " >&2
    echo "  'Developer ID Application' to create one." >&2
    exit 1
fi

echo "▶ Using signing identity: ${SIGN_IDENTITY}"
echo "▶ Building NoType ${VERSION}"
echo

echo "▶ Cleaning previous build outputs"
rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}" "${STAGING}" "${DMG_PATH}" "${DMG_LATEST_PATH}" "${ZIP_PATH}" "${SPARKLE_ZIP_PATH}"

echo "▶ Regenerating Xcode project from project.yml"
xcodegen generate

echo "▶ Archiving (${CONFIG})"
# Pin the signing identity explicitly so the build doesn't fall back
# to looking for "Apple Development" (the legacy "Mac Development"
# cert) when signing intermediate artefacts like Sparkle.framework.
# Locally both certs are usually present so this is a no-op; on CI
# only Developer ID Application is imported and Xcode would otherwise
# fail with `No "Mac Development" signing certificate found`.
xcodebuild -project "${PROJECT}" \
           -scheme "${SCHEME}" \
           -configuration "${CONFIG}" \
           -archivePath "${ARCHIVE_PATH}" \
           -destination "generic/platform=macOS" \
           CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" \
           -quiet \
           archive

echo "▶ Exporting signed .app with Developer ID"
xcodebuild -exportArchive \
           -archivePath "${ARCHIVE_PATH}" \
           -exportOptionsPlist "${EXPORT_OPTIONS}" \
           -exportPath "${EXPORT_DIR}" \
           -quiet

echo "▶ Verifying signature on the exported .app"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

echo "▶ Submitting .app to Apple notary service (1–5 min)"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"
xcrun notarytool submit "${ZIP_PATH}" \
                 --keychain-profile "${KEYCHAIN_PROFILE}" \
                 --wait

echo "▶ Stapling notarization ticket to .app"
xcrun stapler staple "${APP_PATH}"

echo "▶ Gatekeeper check on .app"
spctl --assess --type execute --verbose "${APP_PATH}"

echo "▶ Building DMG"
mkdir -p "${STAGING}"
cp -R "${APP_PATH}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
hdiutil create \
        -volname "NoType" \
        -srcfolder "${STAGING}" \
        -ov \
        -format UDZO \
        "${DMG_PATH}"

echo "▶ Signing DMG"
codesign --sign "${SIGN_IDENTITY}" --timestamp "${DMG_PATH}"

echo "▶ Submitting DMG to notary service (1–5 min)"
xcrun notarytool submit "${DMG_PATH}" \
                 --keychain-profile "${KEYCHAIN_PROFILE}" \
                 --wait

echo "▶ Stapling DMG"
xcrun stapler staple "${DMG_PATH}"

echo "▶ Final Gatekeeper check on DMG"
spctl --assess --type open --context context:primary-signature --verbose "${DMG_PATH}"

# Version-less alias. Identical bytes; we copy (not symlink) so
# GitHub Releases stores it as a real asset that `/latest/download`
# can redirect to.
echo "▶ Creating version-less alias ${DMG_LATEST_PATH}"
cp "${DMG_PATH}" "${DMG_LATEST_PATH}"

# Cleanup intermediates
rm -rf "${STAGING}" "${ZIP_PATH}"

# Sparkle 2 auto-update artefact: a zip of the notarized + stapled .app.
# CI then runs `sign_update` against this to produce the EdDSA signature
# that goes into docs/appcast.xml. The .dmg above stays the artefact the
# website links to for first-time installs.
echo "▶ Packaging .app into ${SPARKLE_ZIP_PATH} for Sparkle"
ditto -c -k --keepParent "${APP_PATH}" "${SPARKLE_ZIP_PATH}"

if command -v sign_update >/dev/null 2>&1; then
    echo "▶ Computing Sparkle EdDSA signature (informational — paste into appcast if running outside CI)"
    sign_update "${SPARKLE_ZIP_PATH}" || true
else
    echo "ℹ sign_update not on PATH — install Sparkle ('brew install --cask sparkle') to print the EdDSA signature here."
fi

echo
echo "✓ Ready to send:"
echo "    ${DMG_PATH}            (first-time install)"
echo "    ${DMG_LATEST_PATH}                (stable 'always latest' alias)"
echo "    ${SPARKLE_ZIP_PATH}    (Sparkle auto-update artefact)"
echo
ls -lh "${DMG_PATH}" "${DMG_LATEST_PATH}" "${SPARKLE_ZIP_PATH}"
