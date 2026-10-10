#!/bin/bash
# Extracts the CHANGELOG.md section for a version.
# Usage: Scripts/release-notes.sh <version>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:?usage: release-notes.sh <version>}"

SECTION="$(awk -v ver="$VERSION" '
  /^## / {
    if (found) exit
    if ($2 == ver) { found = 1; next }
  }
  found {
    if (!NF) {
      if (started) blanks++
      next
    }
    while (blanks > 0) { print ""; blanks-- }
    print
    started = 1
  }
' "$ROOT/CHANGELOG.md")"

if [ -z "$SECTION" ]; then
  echo "ERROR: CHANGELOG.md has no section for version $VERSION (expected '## $VERSION - <date>')" >&2
  exit 1
fi

printf '%s\n' "$SECTION"
