#!/usr/bin/env bash
#
# reset-install-state.sh — wipe all NoType state on the current user account
# so the next launch reproduces the first-time-install experience.
#
# Wipes:
#   - The installed app from /Applications
#   - TCC grants (Accessibility, Microphone, etc.)
#   - UserDefaults (onboarding state, selected mic device)
#   - ~/Library/Application Support/NoType (history.json)
#   - Keychain entry for the Gemini API key
#   - All NoType entries from the Launch Services database
#     (so Launchpad/Spotlight don't show ghost copies from DerivedData,
#      build/, or .xcarchive)
#
# This is destructive for *your* dev grants — you will have to re-grant
# Accessibility/Microphone the next time you build & run from Xcode.

set -uo pipefail

BUNDLE_ID="app.notype"
APP_PATH="/Applications/NoType.app"
SUPPORT_DIR="${HOME}/Library/Application Support/NoType"
KEYCHAIN_SERVICE="app.notype.gemini"

echo "▶ Removing installed app from /Applications"
if [[ -d "${APP_PATH}" ]]; then
    rm -rf "${APP_PATH}"
    echo "  deleted ${APP_PATH}"
else
    echo "  not installed"
fi

echo "▶ Resetting TCC grants for ${BUNDLE_ID}"
tccutil reset All "${BUNDLE_ID}" 2>&1 || echo "  (tccutil refused — sometimes happens; not fatal)"

echo "▶ Clearing UserDefaults for ${BUNDLE_ID}"
defaults delete "${BUNDLE_ID}" 2>/dev/null && echo "  cleared" || echo "  (no defaults present)"

echo "▶ Removing ${SUPPORT_DIR}"
rm -rf "${SUPPORT_DIR}"
echo "  done"

echo "▶ Removing Gemini API key from Keychain"
security delete-generic-password -s "${KEYCHAIN_SERVICE}" 2>/dev/null && echo "  removed" || echo "  (no key present)"

echo "▶ Unregistering all NoType.app paths from Launch Services"
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
"${LSREG}" -dump 2>/dev/null \
    | grep -E '^[[:space:]]*path:.*NoType\.app' \
    | sed -E 's/^[[:space:]]*path:[[:space:]]+//; s/[[:space:]]+\(0x[0-9a-f]+\)$//' \
    | while IFS= read -r p; do
        echo "  unregister: ${p}"
        "${LSREG}" -u "${p}" 2>/dev/null || true
      done

echo "▶ Restarting Dock to refresh Launchpad"
killall Dock 2>/dev/null || true

echo
echo "✓ NoType state reset. The next install will behave as a first-time install."
