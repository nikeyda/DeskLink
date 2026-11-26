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
# Stop only a process launched from this project's build product.
binary="$bundle/Contents/MacOS/DeskLink"
while IFS= read -r pid; do
    if [[ "$(ps -p "$pid" -o comm=)" == "$binary" ]]; then kill -TERM "$pid"; fi
done < <(pgrep -x DeskLink || true)
if [[ "$mode" == --debug ]]; then exec lldb -- "$binary"; fi
open -n "$bundle"
case "$mode" in
    --verify) for attempt in {1..20}; do pgrep -x DeskLink >/dev/null && exit 0; sleep 0.25; done; exit 1 ;;
    --logs|--telemetry) exec /usr/bin/log stream --level info --predicate 'process == "DeskLink"' ;;
esac
