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

app_bundle="$PWD/build/ios/device/DerivedData/Build/Products/$xcode_configuration-iphoneos/Voxline.app"
output_directory="$PWD/build/ios"
# Stage a fresh Payload so an older package cannot retain removed files.
staging_directory=$(mktemp -d "$output_directory/ipa.XXXXXX")
trap 'rm -rf "$staging_directory"' EXIT
mkdir "$staging_directory/Payload"
ditto --norsrc --noextattr "$app_bundle" "$staging_directory/Payload/Voxline.app"
ditto -c -k --norsrc --noextattr --keepParent "$staging_directory/Payload" "$staging_directory/Voxline-unsigned.ipa"
python3 - "$staging_directory" <<'PY'
import hashlib, json, plistlib, sys, zipfile
from pathlib import Path
stage = Path(sys.argv[1])
ipa = stage / "Voxline-unsigned.ipa"
with zipfile.ZipFile(ipa) as archive:
    info = plistlib.loads(archive.read("Payload/Voxline.app/Info.plist"))
if info["CFBundleIdentifier"] != "dev.voxline.ios":
    raise SystemExit("IPA Bundle ID changed; refusing to replace the existing package")
metadata = {"bundleIdentifier": info["CFBundleIdentifier"],
            "version": info["CFBundleShortVersionString"], "buildVersion": info["CFBundleVersion"],
            "signing": "unsigned", "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest()}
(stage / "Voxline-unsigned.identity.json").write_text(json.dumps(metadata, indent=2) + "\n")
print(f"IPA identity: {metadata['bundleIdentifier']} · Build: {metadata['buildVersion']}")
PY
mv -f "$staging_directory/Voxline-unsigned.ipa" "$output_directory/Voxline-unsigned.ipa"
mv -f "$staging_directory/Voxline-unsigned.identity.json" "$output_directory/Voxline-unsigned.identity.json"
echo "未签名 IPA：$output_directory/Voxline-unsigned.ipa"
echo "真机运行前需要使用有效开发签名重新签名。"
