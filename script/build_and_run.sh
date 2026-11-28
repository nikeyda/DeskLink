#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-run}"
case "$mode" in run|--verify|--debug|--logs|--telemetry) ;; *) exit 2 ;; esac
xcodebuild -quiet -project DeskLink.xcodeproj -scheme DeskLink -configuration Debug \
    -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
    -derivedDataPath .build/Xcode -clonedSourcePackagesDirPath .build/Packages \
    -onlyUsePackageVersionsFromResolvedFile -jobs 6 \
    COMPILER_INDEX_STORE_ENABLE=NO build
bundle="$PWD/.build/Xcode/Build/Products/Debug-maccatalyst/Telescope.app"
codesign --verify --strict "$bundle"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")"
binary="$bundle/Contents/MacOS/$executable"
test -x "$binary"
bundle_pids() {
    local path="$1" pid
    while IFS= read -r pid; do
        if [[ "$(ps -p "$pid" -o comm= 2>/dev/null || true)" == "$path" ]]; then
            printf '%s\n' "$pid"
        fi
    done < <(pgrep -x "${path##*/}" || true)
}
# Stop only processes from this project's debug build directory.
while IFS= read -r pid; do
    kill -TERM "$pid"
done < <(bundle_pids "$binary"; bundle_pids "$bundle/Contents/MacOS/DeskLink")
if [[ "$mode" == --debug ]]; then exec lldb -- "$binary"; fi
open -n "$bundle"
case "$mode" in
    --verify) for attempt in {1..20}; do [[ -n "$(bundle_pids "$binary")" ]] && exit 0; sleep 0.25; done; exit 1 ;;
    --logs|--telemetry) exec /usr/bin/log stream --level info --predicate "process == '$executable'" ;;
esac
