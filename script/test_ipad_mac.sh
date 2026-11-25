#!/bin/bash
# Run after the user has connected the installed iPad viewer to this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
device="${1:?Pass the paired iPad identifier}"
manifest="${2:?Pass the generated iPhoneOS xctestrun file}"
result="${3:?Pass an unused xcresult path}"
operation="${4:-input}"
host="${5:-}"
case "$operation" in
    input) ;;
    prepare|counters) [[ -n "$host" ]] || { echo "Pass the Mac's hostname as the fifth argument" >&2; exit 2; } ;;
    *) echo "Use input, prepare, or counters" >&2; exit 2 ;;
esac
run=$(mktemp -d "$PWD/.build/physical-input.XXXXXX")
python3 - "$manifest" "$run/Installed-iPad.xctestrun" "$operation" "$host" <<'PY'
import plistlib
import sys
import uuid
from pathlib import Path

manifest = plistlib.loads(Path(sys.argv[1]).read_bytes())
target = manifest["DeskLinkUITests"]
for key in ("TestHostPath", "TestBundlePath", "UITargetAppPath", "DependentProductPaths"):
    target.pop(key, None)
target.update({
    "UseDestinationArtifacts": True,
    "TestHostBundleIdentifier": "local.nikey.desklink.uitests.xctrunner",
    "UITargetAppBundleIdentifier": "local.nikey.desklink",
    "TestBundleDestinationRelativePath": "__TESTHOST__/PlugIns/DeskLinkUITests.xctest",
    "SystemAttachmentLifetime": "keepNever",
    "UserAttachmentLifetime": "keepNever",
})
operations = {
    "input": "testTapAndTypeIntoConsentingMacTestWindow",
    "prepare": "testPrepareHighPerformanceConnectionOnInstalledIPad",
    "counters": "testReadMediaCountersFromInstalledIPad",
}
operation, host = sys.argv[3:]
target["OnlyTestIdentifiers"] = ["PhysicalSessionUITests/" + operations[operation]]
if operation == "input":
    target["EnvironmentVariables"]["DESKLINK_CHECK_MAC_WINDOW"] = "1"
    challenge = "PAD-" + uuid.uuid4().hex[:4].upper()
    target["EnvironmentVariables"]["DESKLINK_PANEL_CHALLENGE"] = challenge
    Path(sys.argv[2]).with_suffix(".challenge").write_text(challenge)
else:
    target["EnvironmentVariables"]["DESKLINK_MEDIA_CHECK"] = operation
    target["EnvironmentVariables"]["DESKLINK_MAC_TEST_HOST"] = host
Path(sys.argv[2]).write_bytes(plistlib.dumps({
    "__xctestrun_metadata__": manifest["__xctestrun_metadata__"], "DeskLinkUITests": target
}))
PY
runner="$(dirname "$manifest")/Debug-iphoneos/DeskLinkUITests-Runner.app"
xcrun devicectl device install app --device "$device" "$runner" > "$run/install.log"
if [[ "$operation" != input ]]; then
    exec xcodebuild -xctestrun "$run/Installed-iPad.xctestrun" -destination "platform=iOS,id=$device" \
        -parallel-testing-enabled NO -collect-test-diagnostics never -resultBundlePath "$result" test-without-building
fi
swiftc -parse-as-library -module-cache-path .build/FixtureModules script/mac_session_check.swift -o "$run/Panel"
DESKLINK_PANEL_CHALLENGE=$(cat "$run/Installed-iPad.challenge") "$run/Panel" "$run" > "$run/panel.log" 2>&1 &
panel_pid=$!
trap 'kill "$panel_pid" 2>/dev/null || true; wait "$panel_pid" 2>/dev/null || true' EXIT
for attempt in {1..100}; do
    if [[ -s "$run/events.jsonl" ]] && rg -q test_window_ready "$run/events.jsonl"; then break; fi
    kill -0 "$panel_pid" 2>/dev/null || exit 1
    sleep 0.1
done
rg -q test_window_ready "$run/events.jsonl"
echo "Mac panel events $run/events.jsonl"
xcodebuild -xctestrun "$run/Installed-iPad.xctestrun" -destination "platform=iOS,id=$device" \
    -parallel-testing-enabled NO -collect-test-diagnostics never -resultBundlePath "$result" test-without-building
rg -q test_button_clicked "$run/events.jsonl"
rg -q keyboard_target_focused "$run/events.jsonl"
rg -q keyboard_challenge_matched "$run/events.jsonl"
