#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:?Pass an unused xcresult path}"
project="${DESKLINK_TEST_PROJECT:-DeskLink.xcodeproj}"
destination="${DESKLINK_TEST_DESTINATION:-platform=macOS,variant=Mac Catalyst,arch=arm64}"
derived="${DESKLINK_TEST_DERIVED_DATA:-.build/Xcode}"
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
read -r port fingerprint < <("$python" -c 'import json,sys; data=json.load(open(sys.argv[1])); print(data["port"],data["pin"])' "$state/peer.json")
export TEST_RUNNER_DESKLINK_SSH_PORT="$port" TEST_RUNNER_DESKLINK_SSH_PIN="$fingerprint"
export TEST_RUNNER_DESKLINK_KEY_FIXTURES
TEST_RUNNER_DESKLINK_KEY_FIXTURES=$(base64 -i "$state/test-keys.json" | tr -d '\n')
echo "Interoperability events in $state/events.jsonl"
xcodebuild -quiet -project "$project" -scheme DeskLink -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$derived" -clonedSourcePackagesDirPath .build/Packages \
    -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO \
    -only-testing:DeskLinkTests/SSHWireTests -only-testing:DeskLinkTests/SSHAndRouteTests \
    -resultBundlePath "$out" -jobs 4 COMPILER_INDEX_STORE_ENABLE=NO test
