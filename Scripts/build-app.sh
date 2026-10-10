#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == --help ]]; then
    echo "Usage: Scripts/build-app.sh [debug|release]"
    echo "VOXLINE_MAC_ARCHS: host architecture (default), or 'arm64 x86_64'"
    echo "VOXLINE_MAC_SIGN_IDENTITY: fixed certificate name/SHA-1, or '-' for ad-hoc"
    exit 0
fi
if (( $# > 1 )); then echo "Too many arguments; use --help." >&2; exit 2; fi
configuration="${1:-debug}"
case "$configuration" in
    debug|release) ;;
    *) echo "Usage: Scripts/build-app.sh [debug|release]" >&2; exit 2 ;;
esac
export VOXLINE_MAC_SIGN_IDENTITY
VOXLINE_MAC_SIGN_IDENTITY=$(python3 Scripts/lib/build-metadata.py mac-signing)
export VOXLINE_BUILD_VERSION
VOXLINE_BUILD_VERSION=$(python3 Scripts/lib/build-metadata.py version)
binary_directories=()
read -r -a architectures <<< "${VOXLINE_MAC_ARCHS:-$(uname -m)}"
for architecture in "${architectures[@]}"; do
    swift build --configuration "$configuration" --product Voxline --arch "$architecture"
    binary_directories+=("$(swift build --configuration "$configuration" --arch "$architecture" --show-bin-path)")
done
python3 Scripts/lib/package-app.py "$configuration" "${binary_directories[@]}"
