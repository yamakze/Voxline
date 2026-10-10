#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "${1:-}" == --help ]]; then
    echo "Usage: Scripts/compile_and_run.sh [debug|release]"
    exit 0
fi
if (( $# > 1 )); then echo "Too many arguments; use --help." >&2; exit 2; fi
./Scripts/build-app.sh "${1:-debug}"

app_bundle="$PWD/build/Voxline.app"
app_executable="$app_bundle/Contents/MacOS/Voxline"
while read -r process_id executable; do
    if [[ "$executable" != "$app_executable" ]]; then continue; fi
    echo "停止旧 Voxline 进程：$process_id"
    kill -TERM "$process_id"
    stop_deadline=$((SECONDS + 5))
    while kill -0 "$process_id" 2>/dev/null && (( SECONDS < stop_deadline )); do
        sleep 0.1
    done
    if kill -0 "$process_id" 2>/dev/null; then
        echo "旧进程未退出，强制停止：$process_id"
        kill -KILL "$process_id"
    fi
done < <(ps -axo pid=,comm=)

open -n "$app_bundle"
echo "已启动：$app_bundle"
