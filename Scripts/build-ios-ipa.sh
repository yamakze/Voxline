#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "${1:-}" == --help ]]; then
    echo "Usage: Scripts/build-ios-ipa.sh [debug|release]"
    exit 0
fi
if (( $# > 1 )); then
    echo "Too many arguments; use --help." >&2
    exit 2
fi
configuration="${1:-release}"
./Scripts/build-ios.sh device "$configuration"
case "$configuration" in
    debug) xcode_configuration=Debug ;;
    release) xcode_configuration=Release ;;
esac

app_bundle="$PWD/.build/ios/device/DerivedData/Build/Products/$xcode_configuration-iphoneos/Voxline.app"
python3 Scripts/lib/package-ios.py "$app_bundle"
