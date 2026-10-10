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
  found { print }
' "$ROOT/CHANGELOG.md")"

# Trim leading/trailing blank lines.
SECTION="$(printf '%s\n' "$SECTION" | awk 'NF {found=1} found' | awk '{lines[NR]=$0} END {last=NR; while (last>0 && lines[last] !~ /[^[:space:]]/) last--; for (i=1;i<=last;i++) print lines[i]}')"

if [ -z "$SECTION" ]; then
  echo "ERROR: CHANGELOG.md has no section for version $VERSION (expected '## $VERSION - <date>')" >&2
  exit 1
fi

printf '%s\n' "$SECTION"
