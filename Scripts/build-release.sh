#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == --help ]]; then
    echo "Usage: Scripts/build-release.sh [all|macos|ios] [adhoc|notarized]"
    echo "Mac releases default to Universal (arm64 + x86_64)."
    echo "Notarized mode requires VOXLINE_MAC_SIGN_IDENTITY and VOXLINE_NOTARY_PROFILE."
    exit 0
fi
platform="${1:-all}"
mode="${2:-adhoc}"
case "$platform" in all|macos|ios) ;; *) echo "Use --help." >&2; exit 2 ;; esac
case "$mode" in adhoc|notarized) ;; *) echo "Use --help." >&2; exit 2 ;; esac
if (( $# > 2 )); then echo "Too many arguments; use --help." >&2; exit 2; fi
export VOXLINE_BUILD_VERSION
VOXLINE_BUILD_VERSION=$(python3 Scripts/lib/build-metadata.py version)
output="$PWD/dist/release"
work="$PWD/.build/packaging/release"
mkdir -p "$output" "$work"
if [[ "$platform" != ios ]]; then
    rm -f "$output/appcast.xml"
    export VOXLINE_MAC_ARCHS="${VOXLINE_MAC_ARCHS:-arm64 x86_64}"
    export VOXLINE_MAC_OUTPUT_DIRECTORY="$work/macos"
    if [[ "$mode" == notarized ]]; then
        : "${VOXLINE_MAC_SIGN_IDENTITY:?Set a Developer ID Application signing identity}"
        : "${VOXLINE_NOTARY_PROFILE:?Store notarytool credentials and set their profile name}"
        certificate=$(security find-identity -v -p codesigning | grep -F "$VOXLINE_MAC_SIGN_IDENTITY")
        if [[ "$certificate" != *'"Developer ID Application:'* ]]; then
            echo "Notarized distribution requires a Developer ID Application certificate." >&2
            exit 1
        fi
        export VOXLINE_MAC_DISTRIBUTION=1
    else
        export VOXLINE_MAC_SIGN_IDENTITY=- VOXLINE_MAC_DISTRIBUTION=0
    fi
    Scripts/build-app.sh release
    app="$VOXLINE_MAC_OUTPUT_DIRECTORY/Voxline.app"
    if [[ "$mode" == notarized ]]; then
        ditto -c -k --keepParent "$app" "$work/notarize.zip"
        notary_arguments=(--keychain-profile "$VOXLINE_NOTARY_PROFILE")
        if [[ -n "${VOXLINE_NOTARY_KEYCHAIN:-}" ]]; then
            notary_arguments+=(--keychain "$VOXLINE_NOTARY_KEYCHAIN")
        fi
        xcrun notarytool submit "$work/notarize.zip" "${notary_arguments[@]}" --wait
        xcrun stapler staple "$app"
        xcrun stapler validate "$app"
        spctl --assess --type execute --verbose "$app"
    fi
    python3 Scripts/lib/release-assets.py macos "$mode"
fi
if [[ "$platform" != macos ]]; then
    Scripts/build-ios-ipa.sh release
    python3 Scripts/lib/release-assets.py ios
fi
python3 Scripts/lib/release-assets.py checksums
echo "Release assets: $output"
