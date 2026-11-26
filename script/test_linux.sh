#!/bin/bash
# Set DESKLINK_TEST_DEVICE and DESKLINK_TEAM to run on a paired, unlocked iPad.
# DESKLINK_TEST_RSA_AES=128 or 256 selects a TigerVNC RSA-AES desktop.
# DESKLINK_TEST_RSA_UI=1 with the 256-bit account fixture checks the iPad picker and identity dialog.
# DESKLINK_TEST_RSA_ACCOUNT=1 checks the local PAM account instead of the VNC password.
# DESKLINK_TEST_PINYIN=1 checks the first Chinese word in a fresh X11 session.
# On iPad, select the Simplified Chinese Pinyin software keyboard before this test.
# Xcode installs the Debug test host. Its connection library and pasteboard are isolated.
# DESKLINK_RASPIOS_IMAGE optionally selects an unpacked 64-bit Raspberry Pi OS
# desktop image. The Wayland test uses its WayVNC executable on a read-only disk.
# With DESKLINK_TEST_PI_DESKTOP_ACCOUNT=1 that image boots its own login and
# screen-sharing services and checks the active account, a wrong password and
# a different valid account. Each run uses a fresh in-memory overlay.
set -euo pipefail
cd "$(dirname "$0")/.."
result="${1:?Pass an unused xcresult path}"
project="${DESKLINK_TEST_PROJECT:-DeskLink.xcodeproj}"
destination="${DESKLINK_TEST_DESTINATION:-platform=macOS,variant=Mac Catalyst,arch=arm64}"
derived="${DESKLINK_TEST_DERIVED_DATA:-.build/Xcode}"
device="${DESKLINK_TEST_DEVICE:-}"
pi_account="${DESKLINK_TEST_PI_DESKTOP_ACCOUNT:-0}"
if [[ "$pi_account" == 1 && ! -f "${DESKLINK_RASPIOS_IMAGE:-}" ]]; then
    echo "Set DESKLINK_RASPIOS_IMAGE to an unpacked Raspberry Pi OS 64-bit desktop image." >&2
    exit 1
fi
if [[ -n "$device" ]]; then
    destination="platform=iOS,arch=arm64,id=$device"
fi
build=(xcodebuild -quiet -project "$project" -scheme DeskLink -configuration Debug
       -destination "$destination" -derivedDataPath "$derived" -clonedSourcePackagesDirPath .build/Packages
       -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO -jobs 4 COMPILER_INDEX_STORE_ENABLE=NO)
cache="$PWD/.build/linux-peer"
mkdir -p "$cache"
python3 script/linux-peer/fetch.py "$cache"
if [[ -n "$device" ]]; then
    "${build[@]}" DESKLINK_TEAM="${DESKLINK_TEAM:-}" build-for-testing
    local_address=$(python3 script/linux-peer/paired_device.py --local-address "$device")
    python3 script/linux-peer/prepare.py "$cache" "$local_address"
else
    python3 script/linux-peer/prepare.py "$cache"
fi
swiftc -module-cache-path "$cache/module-cache" -framework Virtualization script/linux-peer/Guest.swift -o "$cache/DeskLinkLinuxTest"
codesign -f -s - --entitlements script/linux-peer/Guest.entitlements "$cache/DeskLinkLinuxTest"
run=$(mktemp -d "$cache/test.XXXXXX")
ln -s "$cache/Image" "$run/"
if [[ "$pi_account" == 1 ]]; then
    cp "$cache/guest-initrd" "$run/guest-initrd"
    bsdtar --format newc -czf - -C script/linux-peer/raspios-account . >> "$run/guest-initrd"
else
    ln -s "$cache/guest-initrd" "$run/"
fi
if [[ -n "${DESKLINK_RASPIOS_IMAGE:-}" ]]; then
    pi_image=$(realpath "$DESKLINK_RASPIOS_IMAGE")
    [[ -f "$pi_image" ]]
    ln -s "$pi_image" "$run/raspios.img"
fi
"$cache/DeskLinkLinuxTest" "$run" > "$run/console.log" 2>&1 &
peer=$!
trap 'kill "$peer" 2>/dev/null || true; wait "$peer" 2>/dev/null || true' EXIT
for attempt in {1..400}; do
    if [[ -s "$run/wayland-port" ]] && rg -q DESKLINK_WAYVNC_READY "$run/console.log"; then break; fi
    kill -0 "$peer" 2>/dev/null || { cat "$run/console.log"; exit 1; }
    sleep 0.25
done
if [[ "$pi_account" != 1 ]]; then rg -q DESKLINK_XVNC_READY "$run/console.log"; fi
rg -q DESKLINK_WAYVNC_READY "$run/console.log" || { tail -45 "$run/console.log"; exit 1; }
if [[ -n "${DESKLINK_RASPIOS_IMAGE:-}" ]]; then rg 'DESKLINK_PI_PACKAGE wayvnc ' "$run/console.log"; fi
echo "Linux guest console at $run/console.log"
if [[ "$pi_account" == 1 ]]; then
    if [[ -n "$device" ]]; then
        sdk=iphoneos
        target=("$device")
    else
        "${build[@]}" build-for-testing
        sdk=iphonesimulator
        if [[ "$destination" == *macOS* ]]; then sdk=macosx; fi
        target=(--pi-local "$destination")
    fi
    version=$(xcrun --sdk "$sdk" --show-sdk-version)
    manifest="$derived/Build/Products/DeskLink_${sdk}${version}-arm64.xctestrun"
    python3 script/linux-peer/paired_device.py "${target[@]}" "$run" "$manifest" "$result"
    [[ $(rg -c 'DESKLINK_WAYLAND_INPUT_RECEIVED' "$run/console.log") -eq 2 ]]
    rg -q "Login for user 'deskother' rejected" "$run/console.log"
    rg -q 'authentication failure.*user=fixture' "$run/console.log"
    exit
fi
if [[ -n "${DESKLINK_TEST_RSA_AES:-}" ]]; then
    if [[ -n "$device" ]]; then
        sdk=$(xcrun --sdk iphoneos --show-sdk-version)
        python3 script/linux-peer/paired_device.py "$device" "$run" "$derived/Build/Products/DeskLink_iphoneos${sdk}-arm64.xctestrun" "$result"
    else
        export TEST_RUNNER_DESKLINK_RSA_ACCOUNT="${DESKLINK_TEST_RSA_ACCOUNT:-0}"
        export TEST_RUNNER_DESKLINK_RSA_PORT TEST_RUNNER_DESKLINK_RSA_PIN TEST_RUNNER_DESKLINK_RSA_BITS="$DESKLINK_TEST_RSA_AES"
        TEST_RUNNER_DESKLINK_RSA_PORT=$(cat "$run/resize-port")
        TEST_RUNNER_DESKLINK_RSA_PIN=$(cat "$cache/rsa-pin")
        "${build[@]}" -only-testing:DeskLinkTests/LinuxDesktopTests/testRSAAESHostApprovalPasswordAndEncryptedDesktopInput \
            -only-testing:DeskLinkTests/RSAAESRecordTests -only-testing:DeskLinkTests/ScreensArchiveTests -resultBundlePath "$result" test
    fi
    if [[ "${DESKLINK_TEST_RSA_UI:-}" != 1 ]]; then rg -q 'DESKLINK_X11_WHEEL_COUNT 0' "$run/console.log"; fi
    exit
fi
if [[ "${DESKLINK_TEST_PINYIN:-}" == 1 ]]; then
    if [[ -n "$device" ]]; then
        sdk=$(xcrun --sdk iphoneos --show-sdk-version)
        manifest="$derived/Build/Products/DeskLink_iphoneos${sdk}-arm64.xctestrun"
        python3 script/linux-peer/paired_device.py --pinyin "$device" "$run" "$manifest" "$result"
    elif [[ "$destination" == *"platform=macOS"* ]]; then
        export TEST_RUNNER_DESKLINK_RESIZE_PORT
        TEST_RUNNER_DESKLINK_RESIZE_PORT=$(cat "$run/resize-port")
        "${build[@]}" -only-testing:DeskLinkTests/LinuxDesktopTests/testTigerVNCReceivesTheFirstUnicodeWordWithKeyboardCompatibilityEnabled \
            -only-testing:DeskLinkTests/KeyboardPositionTests -resultBundlePath "$result" test
    else
        export TEST_RUNNER_DESKLINK_TEST_PINYIN=1
        export TEST_RUNNER_DESKLINK_TEST_PINYIN_TERMINAL="vnc://127.0.0.1:$(cat "$run/resize-port")"
        "${build[@]}" -only-testing:DeskLinkUITests/SessionUITests/testPinyinCandidateSendsOnlyCommittedCharactersToTheRemoteDesktop \
            -only-testing:DeskLinkUITests/SessionUITests/testSelectedPinyinCandidateArrivesInTheLinuxTerminal \
            -resultBundlePath "$result" test
    fi
    rg -q DESKLINK_X11_PINYIN_CANDIDATE_RECEIVED "$run/console.log"
    exit
fi
if [[ -n "$device" ]]; then
    sdk=$(xcrun --sdk iphoneos --show-sdk-version)
    manifest="$derived/Build/Products/DeskLink_iphoneos${sdk}-arm64.xctestrun"
    python3 script/linux-peer/paired_device.py "$device" "$run" "$manifest" "$result"
else
    export TEST_RUNNER_DESKLINK_LINUX_PORT TEST_RUNNER_DESKLINK_WAYLAND_PORT
    export TEST_RUNNER_DESKLINK_RESIZE_PORT TEST_RUNNER_DESKLINK_TLS_PORT TEST_RUNNER_DESKLINK_TLS_PIN
    TEST_RUNNER_DESKLINK_LINUX_PORT=$(cat "$run/vnc-port")
    TEST_RUNNER_DESKLINK_WAYLAND_PORT=$(cat "$run/wayland-port")
    TEST_RUNNER_DESKLINK_RESIZE_PORT=$(cat "$run/resize-port")
    TEST_RUNNER_DESKLINK_TLS_PORT=$(cat "$run/tls-port")
    TEST_RUNNER_DESKLINK_TLS_PIN=$(cat "$cache/tls-pin")
    "${build[@]}" -only-testing:DeskLinkTests/LinuxDesktopTests -resultBundlePath "$result" test
fi
rg -q DESKLINK_X11_INPUT_RECEIVED "$run/console.log"
rg -q 'DESKLINK_X11_GEOMETRY 2048 1280' "$run/console.log"
rg -q 'DESKLINK_X11_GEOMETRY 2560 1600' "$run/console.log"
rg -q DESKLINK_X11_CLIPBOARD_ROUNDTRIP "$run/console.log"
rg -q DESKLINK_X11_AUTOMATIC_CLIPBOARD "$run/console.log"
rg -q DESKLINK_X11_DISCONNECTED_TEST_VIEWER "$run/console.log"
rg -q DESKLINK_X11_UNICODE_TEXT_RECEIVED "$run/console.log"
for ticks in 2 3 4 6 8; do
    rg -q "DESKLINK_X11_WHEEL_COUNT $ticks\b" "$run/console.log"
done
rg -q DESKLINK_WAYLAND_INPUT_RECEIVED "$run/console.log"
