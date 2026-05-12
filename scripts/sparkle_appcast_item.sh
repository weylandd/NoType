#!/usr/bin/env bash
#
# sparkle_appcast_item.sh — inserts a new <item> into docs/appcast.xml.
#
# Used by .github/workflows/release.yml after `sign_update` produces the
# EdDSA signature for the release .zip. Can also be invoked manually if
# CI fails partway through and you need to recover by hand.
#
# Usage:
#   scripts/sparkle_appcast_item.sh \
#       --version 0.1.2 \
#       --build   12 \
#       --signature 'sparkle:edSignature="..." length="1234567"' \
#       --notes-file CHANGELOG.md \
#       [--output-appcast docs/appcast.xml] \
#       [--download-url-base https://github.com/weylandd/NoType/releases/download]
#
# The --signature value is the full output line from `sign_update` —
# pass it verbatim, including the two attribute pairs. We don't try to
# parse/recompose it; that's the contract Sparkle ships.
#
# Insertion point: immediately after the <language>...</language> tag in
# the channel, so newer items appear at the top (conventional). Sparkle
# itself doesn't care about order — it picks the highest version that
# satisfies SUMinimumSystemVersion regardless.
#
# Idempotent: if an item with the same <sparkle:shortVersionString> is
# already in the file, the script logs and exits 0 without re-inserting.

set -euo pipefail

VERSION=""
BUILD=""
SIGNATURE=""
NOTES_FILE=""
OUTPUT_APPCAST="docs/appcast.xml"
DOWNLOAD_URL_BASE="https://github.com/weylandd/NoType/releases/download"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)           VERSION="$2";           shift 2 ;;
        --build)             BUILD="$2";             shift 2 ;;
        --signature)         SIGNATURE="$2";         shift 2 ;;
        --notes-file)        NOTES_FILE="$2";        shift 2 ;;
        --output-appcast)    OUTPUT_APPCAST="$2";    shift 2 ;;
        --download-url-base) DOWNLOAD_URL_BASE="$2"; shift 2 ;;
        -h|--help)
            sed -n '1,40p' "$0"; exit 0 ;;
        *)
            echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

[[ -n "$VERSION"   ]] || { echo "--version required"   >&2; exit 1; }
[[ -n "$BUILD"     ]] || { echo "--build required"     >&2; exit 1; }
[[ -n "$SIGNATURE" ]] || { echo "--signature required" >&2; exit 1; }
[[ -f "$OUTPUT_APPCAST" ]] || { echo "appcast not found: $OUTPUT_APPCAST" >&2; exit 1; }

NOTES=""
if [[ -n "$NOTES_FILE" && -f "$NOTES_FILE" ]]; then
    NOTES=$(cat "$NOTES_FILE")
fi

ZIP_URL="${DOWNLOAD_URL_BASE}/v${VERSION}/NoType-${VERSION}.zip"
PUB_DATE=$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")

export VERSION BUILD SIGNATURE NOTES OUTPUT_APPCAST ZIP_URL PUB_DATE

python3 - <<'PYEOF'
import os, re, sys

path      = os.environ["OUTPUT_APPCAST"]
version   = os.environ["VERSION"]
build     = os.environ["BUILD"]
signature = os.environ["SIGNATURE"]
notes     = os.environ["NOTES"]
zip_url   = os.environ["ZIP_URL"]
pub_date  = os.environ["PUB_DATE"]

# CDATA can't contain "]]>". Defensively split if it ever appears.
safe_notes = notes.replace("]]>", "]]]]><![CDATA[>")

item = f"""    <item>
      <title>Version {version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
{safe_notes}
      ]]></description>
      <enclosure url="{zip_url}"
                 type="application/octet-stream"
                 {signature} />
    </item>
"""

with open(path, encoding="utf-8") as f:
    content = f.read()

marker = f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
if marker in content:
    sys.stderr.write(f"appcast already contains version {version} — skipping\n")
    sys.exit(0)

m = re.search(r"(<language>[^<]*</language>\s*\n)", content)
if not m:
    sys.stderr.write("could not find <language> anchor in appcast\n")
    sys.exit(1)

insert_at = m.end()
new_content = content[:insert_at] + item + content[insert_at:]

with open(path, "w", encoding="utf-8") as f:
    f.write(new_content)

print(f"✓ inserted item for {version} into {path}")
PYEOF
