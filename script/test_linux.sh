#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
result="${1:?Pass an unused xcresult path}"
project="${DESKLINK_TEST_PROJECT:-DeskLink.xcodeproj}"
destination="${DESKLINK_TEST_DESTINATION:-platform=macOS,variant=Mac Catalyst,arch=arm64}"
derived="${DESKLINK_TEST_DERIVED_DATA:-.build/Xcode}"
cache="$PWD/.build/linux-peer"
mkdir -p "$cache"
python3 script/linux-peer/fetch.py "$cache"
python3 script/linux-peer/prepare.py "$cache"
swiftc -module-cache-path "$cache/module-cache" -framework Virtualization script/linux-peer/Guest.swift -o "$cache/DeskLinkLinuxTest"
codesign -f -s - --entitlements script/linux-peer/Guest.entitlements "$cache/DeskLinkLinuxTest"
run=$(mktemp -d "$cache/test.XXXXXX")
ln -s "$cache/Image" "$cache/guest-initrd" "$run/"
"$cache/DeskLinkLinuxTest" "$run" > "$run/console.log" 2>&1 &
peer=$!
trap 'kill "$peer" 2>/dev/null || true; wait "$peer" 2>/dev/null || true' EXIT
for attempt in {1..400}; do
    if [[ -s "$run/wayland-port" ]] && rg -q DESKLINK_WAYVNC_READY "$run/console.log"; then break; fi
    kill -0 "$peer" 2>/dev/null || { cat "$run/console.log"; exit 1; }
    sleep 0.25
done
rg -q DESKLINK_XVNC_READY "$run/console.log"
rg -q DESKLINK_WAYVNC_READY "$run/console.log" || { tail -45 "$run/console.log"; exit 1; }
echo "Linux guest console at $run/console.log"
export TEST_RUNNER_DESKLINK_LINUX_PORT
TEST_RUNNER_DESKLINK_LINUX_PORT=$(cat "$run/vnc-port")
export TEST_RUNNER_DESKLINK_TLS_PORT TEST_RUNNER_DESKLINK_TLS_PIN
export TEST_RUNNER_DESKLINK_WAYLAND_PORT
TEST_RUNNER_DESKLINK_WAYLAND_PORT=$(cat "$run/wayland-port")
export TEST_RUNNER_DESKLINK_RESIZE_PORT
TEST_RUNNER_DESKLINK_RESIZE_PORT=$(cat "$run/resize-port")
TEST_RUNNER_DESKLINK_TLS_PORT=$(cat "$run/tls-port")
TEST_RUNNER_DESKLINK_TLS_PIN=$(cat "$cache/tls-pin")
xcodebuild -quiet -project "$project" -scheme DeskLink -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$derived" -clonedSourcePackagesDirPath .build/Packages \
    -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO -only-testing:DeskLinkTests/LinuxDesktopTests \
    -resultBundlePath "$result" -jobs 4 COMPILER_INDEX_STORE_ENABLE=NO test
rg -q DESKLINK_X11_INPUT_RECEIVED "$run/console.log"
rg -q 'DESKLINK_X11_GEOMETRY 2048 1280' "$run/console.log"
rg -q 'DESKLINK_X11_GEOMETRY 2560 1600' "$run/console.log"
rg -q DESKLINK_X11_CLIPBOARD_ROUNDTRIP "$run/console.log"
rg -q DESKLINK_X11_AUTOMATIC_CLIPBOARD "$run/console.log"
rg -q DESKLINK_X11_DISCONNECTED_TEST_VIEWER "$run/console.log"
rg -q DESKLINK_X11_UNICODE_TEXT_RECEIVED "$run/console.log"
rg -q DESKLINK_WAYLAND_INPUT_RECEIVED "$run/console.log"
