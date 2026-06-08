#!/usr/bin/env bash
#
# Print the CHANGELOG.md section for one version: its "## [<version>] - <date>"
# header and the lines under it, up to (but not including) the next release
# header, with surrounding blank lines trimmed. Used as the GitHub release notes
# by .github/workflows/release.yml; the header is kept so the release body
# mirrors the changelog section verbatim.
#
# Usage:
#   changelog-section.sh <version> [changelog-path]
#
# Exits non-zero if the version has no section, so a caller never publishes an
# empty release.

set -euo pipefail

VERSION="${1:?usage: changelog-section.sh <version> [changelog-path]}"
CHANGELOG="${2:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/CHANGELOG.md}"

[ -f "${CHANGELOG}" ] || { echo "changelog-section: no CHANGELOG.md at ${CHANGELOG}" >&2; exit 1; }

# Slice the section (literal header match, so dots in the version are not
# treated as regex), keeping the header line, then strip trailing blank lines.
body="$(
  awk -v hdr="## [${VERSION}]" '
    index($0, hdr) == 1 { f = 1; print; next }
    f && index($0, "## [") == 1 { exit }
    f { print }
  ' "${CHANGELOG}" \
  | awk 'NF{if(s)while(p-->0)print"";s=1;p=0;print;next} s{p++}'
)"

[ -n "${body}" ] || { echo "changelog-section: no section for version '${VERSION}' in ${CHANGELOG}" >&2; exit 1; }
printf '%s\n' "${body}"
