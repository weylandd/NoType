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

echo "▶ Archiving (${CONFIG}) unsigned"
# We archive WITHOUT signing, then code-sign the exported .app by hand below.
# Why we can't let xcodebuild sign during archive/export:
#  - The data-protection keychain migration (#70) added the
#    `keychain-access-groups` entitlement. The moment Xcode's build system
#    sees that entitlement, `archive` (and `exportArchive`) demand a
#    provisioning profile and fail with
#    `"NoType" requires a provisioning profile` — even under Manual signing
#    with an empty PROVISIONING_PROFILE_SPECIFIER. (Confirmed twice on CI.)
#  - A NON-sandboxed macOS app on Developer ID needs NO profile for this
#    entitlement: the access group is prefixed with the literal Team ID
#    (`49T6U8DQXZ.app.notype`, see NoType.entitlements), which the Developer
#    ID signature authorizes directly. (iOS would need a real profile.)
#  - So we sidestep xcodebuild's profile machinery entirely: archive
#    unsigned (`CODE_SIGNING_ALLOWED=NO`), then `codesign` the bundle
#    inside-out with the Developer ID identity + `NoType.entitlements`.
#    This is the standard recipe for Developer ID apps carrying entitlements
#    that Xcode wants a profile for.
xcodebuild -project "${PROJECT}" \
           -scheme "${SCHEME}" \
           -configuration "${CONFIG}" \
           -archivePath "${ARCHIVE_PATH}" \
           -destination "generic/platform=macOS" \
           CODE_SIGNING_ALLOWED=NO \
           CODE_SIGNING_REQUIRED=NO \
           -quiet \
           archive

echo "▶ Exporting the unsigned .app from the archive"
# No `-exportArchive` — it would re-sign and hit the same profile wall.
# Just copy the built bundle out of the archive into EXPORT_DIR.
rm -rf "${EXPORT_DIR}"
mkdir -p "${EXPORT_DIR}"
ditto "${ARCHIVE_PATH}/Products/Applications/NoType.app" "${APP_PATH}"

echo "▶ Code-signing with Developer ID (inside-out, hardened runtime)"
# Sign nested Mach-O code first (Sparkle's XPC services, Updater.app,
# Autoupdate, then the framework bundle), each with the hardened runtime.
# These helpers carry no entitlements in a non-sandboxed app; Autoupdate's
# lone `application-identifier` is intentionally dropped on re-sign — it is
# unused here and keeping it would re-trigger the profile requirement.
SPK_V="${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in \
    "${SPK_V}/XPCServices/Downloader.xpc" \
    "${SPK_V}/XPCServices/Installer.xpc" \
    "${SPK_V}/Updater.app" \
    "${SPK_V}/Autoupdate" \
    "${APP_PATH}/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${nested}"
done
# Main app last: our entitlements (keychain-access-groups + audio-input) and
# the stable designated requirement (`identifier "app.notype"`) so TCC grants
# survive across updates (signing/NoType.xcrequirements — same DR the old
# xcodebuild path embedded via OTHER_CODE_SIGN_FLAGS).
codesign --force --options runtime --timestamp \
         --entitlements "NoType/NoType.entitlements" \
         --requirements="$(pwd)/signing/NoType.xcrequirements" \
         --sign "${SIGN_IDENTITY}" "${APP_PATH}"

echo "▶ Verifying signature on the signed .app"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

echo "▶ AMFI gate — proving the entitlements can actually exec"
# WHY THIS EXISTS: v0.1.11 shipped a bundle that passed `codesign --verify
# --deep --strict`, notarization, stapling AND `spctl --assess` — and could not
# launch on a single machine. `keychain-access-groups` is a *restricted*
# entitlement: AMFI SIGKILLs a binary carrying it unless the bundle embeds a
# matching provisioning profile. None of the checks above validate restricted
# entitlements, so the breakage was invisible until users ran it:
#
#   amfid: not valid: ... Code=-413 "No matching profile found"
#   AMFI:  Code has restricted entitlements, but the validation of its code
#          signature failed.
#   kernel: proc N: load code signature error 4 for file "NoType"
#
# The only check that catches this is an actual exec. We can't exec NoType
# itself here (it installs a CGEventTap, opens the mic and shows a menu-bar
# item), so we sign a do-nothing binary with the SAME identity, the SAME
# entitlements file and the SAME embedded-profile state as the real bundle, and
# confirm the kernel lets it run.
#
# See docs/solutions/runtime-errors/amfi-restricted-entitlement-launch-kill-2026-07-25.md
AMFI_PROBE_DIR="$(mktemp -d)"
trap 'rm -rf "${AMFI_PROBE_DIR}"' EXIT
PROBE_APP="${AMFI_PROBE_DIR}/AMFIProbe.app"
mkdir -p "${PROBE_APP}/Contents/MacOS"
# Same bundle id as the real app: a provisioning profile only satisfies AMFI
# for the App ID it was issued for, so the probe must claim the same identity
# or a correctly-profiled build would fail this gate.
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string app.notype" \
                        -c "Add :CFBundleExecutable string probe" \
                        -c "Add :CFBundlePackageType string APPL" \
                        "${PROBE_APP}/Contents/Info.plist" >/dev/null
printf 'int main(void){return 0;}\n' > "${AMFI_PROBE_DIR}/probe.c"
xcrun clang -o "${PROBE_APP}/Contents/MacOS/probe" "${AMFI_PROBE_DIR}/probe.c"
# Mirror the real bundle's profile state. Once a Developer ID profile is
# embedded (restoring the data-protection keychain — see
# docs/solutions/documentation-gaps/developer-id-provisioning-profile-2026-07-25.md)
# the probe picks it up automatically and this gate keeps passing.
if [[ -f "${APP_PATH}/Contents/embedded.provisionprofile" ]]; then
    cp "${APP_PATH}/Contents/embedded.provisionprofile" "${PROBE_APP}/Contents/"
fi
codesign --force --options runtime --timestamp=none \
         --entitlements "NoType/NoType.entitlements" \
         --sign "${SIGN_IDENTITY}" "${PROBE_APP}"
if "${PROBE_APP}/Contents/MacOS/probe"; then
    echo "  ✓ entitlements exec cleanly under AMFI"
else
    probe_rc=$?
    echo >&2
    echo "✗ AMFI REJECTED the entitlements — this build would NOT launch." >&2
    echo "  A probe signed with NoType.entitlements exited ${probe_rc} (137 = SIGKILL)." >&2
    echo >&2
    echo "  Cause: NoType/NoType.entitlements declares a RESTRICTED entitlement" >&2
    echo "  with no matching provisioning profile embedded in the bundle." >&2
    echo "  Diagnose with:" >&2
    echo "    log show --last 2m --predicate 'process == \"amfid\"' --style compact" >&2
    echo >&2
    echo "  Fix: either drop the restricted entitlement, or embed a Developer ID" >&2
    echo "  provisioning profile at Contents/embedded.provisionprofile before" >&2
    echo "  signing. Aborting before notarization." >&2
    exit 1
fi

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
