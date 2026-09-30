#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AIBar"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

if [ "${AI_BAR_RELEASE:-0}" = "1" ]; then
    if [ -z "${AI_BAR_CODESIGN_IDENTITY:-}" ]; then
        echo "Release builds require AI_BAR_CODESIGN_IDENTITY (Developer ID Application)." >&2
        exit 1
    fi
    case "$AI_BAR_CODESIGN_IDENTITY" in
        "Developer ID Application:"*) ;;
        *) echo "AI_BAR_CODESIGN_IDENTITY must be a Developer ID Application identity." >&2; exit 1 ;;
    esac
fi

cd "$ROOT_DIR"
BUILD_FLAGS=(-c release -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=." -Xswiftc -debug-prefix-map -Xswiftc "$ROOT_DIR=.")
if [ -n "${AI_BAR_SWIFT_SDK:-}" ]; then
    swift build "${BUILD_FLAGS[@]}" --disable-sandbox --sdk "$AI_BAR_SWIFT_SDK"
else
    swift build "${BUILD_FLAGS[@]}"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp ".build/release/AIBar" "$MACOS_DIR/AIBar"
cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

BUILD_NUMBER="$(date '+%Y%m%d.%H%M')"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"

chmod +x "$MACOS_DIR/AIBar"
/usr/bin/strip -S "$MACOS_DIR/AIBar"
if [ "${AI_BAR_RELEASE:-0}" = "1" ]; then
    codesign --force --deep --options runtime --timestamp --sign "$AI_BAR_CODESIGN_IDENTITY" "$APP_DIR"
else
    # Local development only. An ad-hoc signature is not a public release identity.
    codesign --force --deep --sign - "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"
echo "$APP_DIR"
