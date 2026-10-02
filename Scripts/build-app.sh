#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in
    debug|release) ;;
    *) echo "Usage: Scripts/build-app.sh [debug|release]" >&2; exit 2 ;;
esac
swift build --configuration "$configuration" --product Voxline
python3 Scripts/package-app.py "$configuration"
