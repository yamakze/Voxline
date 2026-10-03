#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "${1:-}" == --help ]]; then
    echo "Usage: Scripts/compile_and_run_ios.sh [simulator-UDID] [debug|release] | --list"
    exit 0
fi
if [[ "${1:-}" == --list ]]; then
    xcrun simctl list devices available
    exit
fi
if (( $# > 2 )); then
    echo "Usage: Scripts/compile_and_run_ios.sh [simulator-UDID] [debug|release] | --list" >&2
    exit 2
fi

device_id="${1:-}"
configuration="${2:-debug}"
case "$configuration" in
    debug|release) ;;
    *) echo "Configuration must be debug or release." >&2; exit 2 ;;
esac
# Prefer an already booted device; otherwise choose the first available iPhone.
device_id=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = [d for runtime, group in json.load(sys.stdin)["devices"].items()
           if ".iOS-" in runtime for d in group if d["isAvailable"]]
requested = sys.argv[1]
if requested:
    selected = next((d for d in devices if d["udid"] == requested), None)
else:
    selected = next((d for d in devices if d["state"] == "Booted"), None)
    if selected is None:
        selected = next((d for d in devices if d["name"].startswith("iPhone")), None)
if selected is None:
    sys.exit("找不到可用 iOS 模拟器；用 --list 查看设备，或在 Xcode 安装 iOS runtime。")
print(selected["udid"])
' "$device_id")

./Scripts/build-ios.sh simulator "$configuration" "platform=iOS Simulator,id=$device_id"
case "$configuration" in
    debug) xcode_configuration=Debug ;;
    release) xcode_configuration=Release ;;
esac
app_bundle="$PWD/build/ios/simulator/DerivedData/Build/Products/$xcode_configuration-iphonesimulator/Voxline.app"
device_state=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
print(next(d["state"] for group in json.load(sys.stdin)["devices"].values()
           for d in group if d["udid"] == sys.argv[1]))
' "$device_id")
if [[ "$device_state" == Shutdown ]]; then
    xcrun simctl boot "$device_id"
fi
xcrun simctl bootstatus "$device_id" -b
open -a Simulator --args -CurrentDeviceUDID "$device_id"
xcrun simctl install "$device_id" "$app_bundle"
# Replacing the installed app preserves its sandbox data; launch terminates an old instance.
xcrun simctl launch --terminate-running-process "$device_id" dev.voxline.ios
echo "已在模拟器启动 Voxline：$device_id"
