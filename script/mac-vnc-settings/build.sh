#!/bin/bash
set -euo pipefail

if [[ "${EFFECTIVE_PLATFORM_NAME:-}" != "-maccatalyst" ]]; then
    exit 0
fi

tool="${SCRIPT_OUTPUT_FILE_0}"
contents="$tool/Contents"
inputs="$SRCROOT/script/mac-vnc-settings"
mkdir -p "$contents/MacOS"
cp "$inputs/Info.plist" "$contents/Info.plist"
for language in en zh-Hans; do
    resources="$contents/Resources/$language.lproj"
    mkdir -p "$resources"
    cp "$SRCROOT/Shared/$language.lproj/Localizable.strings" "$resources/"
done
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CURRENT_PROJECT_VERSION" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MACOSX_DEPLOYMENT_TARGET" "$contents/Info.plist"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
executables=()
for architecture in $ARCHS; do
    binary="$DERIVED_FILE_DIR/TelescopeVNC-$architecture"
    xcrun --sdk macosx swiftc -target "$architecture-apple-macosx$MACOSX_DEPLOYMENT_TARGET" \
        -sdk "$sdk" -swift-version 6 -O -parse-as-library \
        "$SRCROOT/App/MacVNCLinkHandler.swift" "$inputs/TelescopeVNC.swift" -o "$binary"
    executables+=("$binary")
done
xcrun lipo -create "${executables[@]}" -output "$contents/MacOS/TelescopeVNC"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
    /usr/bin/codesign --force --timestamp=none --options runtime \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$tool"
fi
