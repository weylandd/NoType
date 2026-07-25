#!/usr/bin/env bash
#
# sparkle_appcast_item.sh — inserts a new <item> into docs/appcast.xml.
#
# Called by scripts/publish_release.sh after `sign_update` produces the
# EdDSA signature for the release .zip. Can also be invoked manually if a
# publish fails partway through and you need to recover the appcast by hand.
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
# Defaults to the current MACOSX_DEPLOYMENT_TARGET (see ADR-001).
# Pass --minimum-system-version to override.
MIN_SYSTEM_VERSION="15.0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)                VERSION="$2";              shift 2 ;;
        --build)                  BUILD="$2";                shift 2 ;;
        --signature)              SIGNATURE="$2";            shift 2 ;;
        --notes-file)             NOTES_FILE="$2";           shift 2 ;;
        --output-appcast)         OUTPUT_APPCAST="$2";       shift 2 ;;
        --download-url-base)      DOWNLOAD_URL_BASE="$2";    shift 2 ;;
        --minimum-system-version) MIN_SYSTEM_VERSION="$2";   shift 2 ;;
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

export VERSION BUILD SIGNATURE NOTES OUTPUT_APPCAST ZIP_URL PUB_DATE MIN_SYSTEM_VERSION

python3 - <<'PYEOF'
import os, re, sys

path       = os.environ["OUTPUT_APPCAST"]
version    = os.environ["VERSION"]
build      = os.environ["BUILD"]
signature  = os.environ["SIGNATURE"]
notes      = os.environ["NOTES"]
zip_url    = os.environ["ZIP_URL"]
pub_date   = os.environ["PUB_DATE"]
min_sys_ver = os.environ["MIN_SYSTEM_VERSION"]

# Extract the section for `version` from the full CHANGELOG.md text.
# We expect Keep-a-Changelog layout: each version starts with
#   `## [X.Y.Z] — ...`
# and the next section starts with another `## [` line. The section
# ends at the `---` separator that precedes the next `## [`. Anything
# between is taken verbatim.
#
# If the version isn't found in the changelog (unlikely if you bumped
# CHANGELOG.md before releasing), we fall back to using the full file
# so we never ship an empty description. A warning is printed to
# stderr in that case.
def extract_section(text: str, version: str) -> str:
    # Two callers, two shapes of `--notes-file`:
    #   * a full CHANGELOG.md (this script's documented usage) — find and
    #     return the section for `version`;
    #   * an already-extracted section, which is what
    #     `scripts/publish_release.sh` passes (it extracts the notes itself
    #     for the GitHub Release body and reuses the same file here).
    #
    # Telling them apart matters. Before this check the script always tried
    # to extract, so the pre-extracted input — which has no `## [x.y.z]`
    # heading — hit the not-found branch on every release and printed
    # "using full CHANGELOG as description". The fallback returned the whole
    # input, which for that caller happens to be exactly the right text, so
    # the appcast was correct and the warning was noise. The cost was that a
    # REAL extraction failure looked identical to the normal path.
    #
    # A body with no version headings at all is already a section: use it
    # verbatim, no warning. Only warn when the text does look like a
    # changelog but lacks the requested version — the case actually worth
    # shouting about.
    if not re.search(r"^##\s+\[", text, re.MULTILINE):
        # Same trailing-separator trim the extract path applies, so both
        # callers produce a byte-identical description for the same release.
        return re.sub(r"\n---\s*$", "", text.strip()).rstrip()

    # Match `## [VERSION]` followed by anything until the next `## [`
    # or end of file. The trailing `---` separator (if present) and
    # any whitespace immediately before the next heading are dropped.
    pattern = re.compile(
        r"^##\s+\[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=\n##\s+\[|\Z)",
        re.DOTALL | re.MULTILINE,
    )
    m = pattern.search(text)
    if not m:
        sys.stderr.write(
            f"warning: changelog section for {version} not found in a file that "
            f"does contain version headings — using the whole file as the "
            f"description. The appcast item will be wrong; fix CHANGELOG.md.\n"
        )
        return text
    body = m.group(1).strip()
    # Drop a trailing `---` horizontal rule (the section separator).
    body = re.sub(r"\n---\s*$", "", body).rstrip()
    return body

description = extract_section(notes, version)

# CDATA can't contain "]]>". Defensively split if it ever appears.
safe_description = description.replace("]]>", "]]]]><![CDATA[>")

item = f"""    <item>
      <title>Version {version}</title>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_sys_ver}</sparkle:minimumSystemVersion>
      <description><![CDATA[
{safe_description}
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
