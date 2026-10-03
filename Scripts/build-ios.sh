#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "${1:-}" == --help ]]; then
    echo "Usage: Scripts/build-ios.sh [simulator|device] [debug|release] [destination]"
    exit 0
fi
if (( $# > 3 )); then
    echo "Too many arguments; use --help." >&2
    exit 2
fi
platform="${1:-simulator}"
configuration="${2:-debug}"
case "$platform" in
    simulator) destination="${3:-generic/platform=iOS Simulator}"; sdk=iphonesimulator ;;
    device) destination="generic/platform=iOS"; sdk=iphoneos ;;
    *) echo "Usage: Scripts/build-ios.sh [simulator|device] [debug|release] [destination]" >&2; exit 2 ;;
esac
case "$configuration" in
    debug) xcode_configuration=Debug ;;
    release) xcode_configuration=Release ;;
    *) echo "Configuration must be debug or release." >&2; exit 2 ;;
esac

mkdir -p "build/ios/$platform"
build_started=$SECONDS
xcodebuild -project Voxline.xcodeproj -scheme VoxlineIOS \
    -configuration "$xcode_configuration" -destination "$destination" \
    -derivedDataPath "$PWD/build/ios/$platform/DerivedData" \
    CODE_SIGNING_ALLOWED=NO -showBuildTimingSummary build \
    2>&1 | tee "build/ios/$platform/build.log"

echo "构建耗时：$((SECONDS - build_started)) 秒"
echo "构建完成：build/ios/$platform/DerivedData/Build/Products/$xcode_configuration-$sdk/Voxline.app"
