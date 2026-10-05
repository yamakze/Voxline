#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in
    debug|release) ;;
    *) echo "Usage: Scripts/build-app.sh [debug|release]" >&2; exit 2 ;;
esac
export VOXLINE_MAC_SIGN_IDENTITY
VOXLINE_MAC_SIGN_IDENTITY=$(python3 Scripts/build-metadata.py mac-signing)
export VOXLINE_BUILD_VERSION
VOXLINE_BUILD_VERSION=$(python3 Scripts/build-metadata.py version)
swift build --configuration "$configuration" --product Voxline
python3 Scripts/package-app.py "$configuration"
