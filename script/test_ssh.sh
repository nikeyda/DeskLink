#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:?Pass an unused xcresult path}"
project="${DESKLINK_TEST_PROJECT:-DeskLink.xcodeproj}"
destination="${DESKLINK_TEST_DESTINATION:-platform=macOS,variant=Mac Catalyst,arch=arm64}"
derived="${DESKLINK_TEST_DERIVED_DATA:-.build/Xcode}"
device="${DESKLINK_TEST_DEVICE:-}"
if [[ -n "$device" ]]; then destination="platform=iOS,arch=arm64,id=$device"; fi
build=(xcodebuild -quiet -project "$project" -scheme DeskLink -configuration Debug
       -destination "$destination" -derivedDataPath "$derived" -clonedSourcePackagesDirPath .build/Packages
       -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO -jobs 2 COMPILER_INDEX_STORE_ENABLE=NO)
if [[ -n "$device" ]]; then
    "${build[@]}" DESKLINK_TEAM="${DESKLINK_TEAM:-}" build-for-testing
fi
python="${DESKLINK_FIXTURE_PYTHON:-.build/ssh-peer-env/bin/python}"
state=$(mktemp -d "$PWD/.build/ssh-test.XXXXXX")
"$python" script/ssh_test_desktop.py --ready "$state/peer.json" --log "$state/events.jsonl" &
peer=$!
trap 'kill "$peer" 2>/dev/null || true; wait "$peer" 2>/dev/null || true' EXIT
for attempt in {1..100}; do
    [[ -s "$state/peer.json" ]] && break
    kill -0 "$peer" 2>/dev/null || exit 1
    sleep 0.1
done
echo "Interoperability events in $state/events.jsonl"
if [[ -n "$device" ]]; then
    sdk=$(xcrun --sdk iphoneos --show-sdk-version)
    manifest="$derived/Build/Products/DeskLink_iphoneos${sdk}-arm64.xctestrun"
    python3 script/linux-peer/paired_device.py --ssh "$device" "$state" "$manifest" "$out"
    exit $?
fi
read -r port fingerprint < <("$python" -c 'import json,sys; data=json.load(open(sys.argv[1])); print(data["port"],data["pin"])' "$state/peer.json")
export TEST_RUNNER_DESKLINK_SSH_PORT="$port" TEST_RUNNER_DESKLINK_SSH_PIN="$fingerprint"
export TEST_RUNNER_DESKLINK_KEY_FIXTURES
TEST_RUNNER_DESKLINK_KEY_FIXTURES=$(base64 -i "$state/test-keys.json" | tr -d '\n')
"${build[@]}" -only-testing:DeskLinkTests/SSHWireTests -only-testing:DeskLinkTests/SSHAndRouteTests \
    -resultBundlePath "$out" test
