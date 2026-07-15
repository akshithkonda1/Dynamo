#!/usr/bin/env bash
# Build Dynamo and wrap it in an ad-hoc signed .app bundle suitable for
# Launch at Login (SMAppService) and day-to-day use without a paid Developer ID.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -d "/Users/akshithkonda/Downloads/Xcode-beta.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Users/akshithkonda/Downloads/Xcode-beta.app/Contents/Developer}"
fi

CONFIG="${1:-release}"
if [[ "$CONFIG" == "release" ]]; then
  BUILD_FLAGS=(-c release)
  BIN_DIR=".build/release"
else
  BUILD_FLAGS=(-c debug)
  BIN_DIR=".build/debug"
fi

echo "→ Building Dynamo ($CONFIG)…"
swift build "${BUILD_FLAGS[@]}"

APP_DIR="${ROOT}/dist/Dynamo.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS}" "${RESOURCES}"

cp "${BIN_DIR}/Dynamo" "${MACOS}/Dynamo"
chmod +x "${MACOS}/Dynamo"
cp "${ROOT}/Sources/Dynamo/Info.plist" "${CONTENTS}/Info.plist"

# Optional MediaRemote helper process, if the target built (swift build with
# no --product flag builds every target, so it's already sitting in BIN_DIR
# alongside Dynamo). See MediaRemoteHelperProcess.swift for why it exists.
if [[ -f "${BIN_DIR}/DynamoMediaRemoteHelper" ]]; then
  cp "${BIN_DIR}/DynamoMediaRemoteHelper" "${MACOS}/DynamoMediaRemoteHelper"
  chmod +x "${MACOS}/DynamoMediaRemoteHelper"
fi

# Optional app icon if present.
if [[ -f "${ROOT}/Sources/Dynamo/Resources/AppIcon.icns" ]]; then
  cp "${ROOT}/Sources/Dynamo/Resources/AppIcon.icns" "${RESOURCES}/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${CONTENTS}/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "${CONTENTS}/Info.plist"
fi

# Bump executable name for Launch Services.
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Dynamo" "${CONTENTS}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Dynamo" "${CONTENTS}/Info.plist"

# Finder resource forks break codesign — strip extended attributes first.
xattr -cr "${APP_DIR}" 2>/dev/null || true

echo "→ Ad-hoc codesign…"
# Sign nested binaries first, then the bundle (avoid --deep which can fail
# with "bundle format unrecognized" on some toolchains).
if [[ -x "${MACOS}/DynamoMediaRemoteHelper" ]]; then
  codesign --force --sign - --timestamp=none "${MACOS}/DynamoMediaRemoteHelper"
  echo "✓ Embedded DynamoMediaRemoteHelper"
else
  echo "warning: DynamoMediaRemoteHelper not embedded (media falls back to AppleScript)"
fi
codesign --force --sign - --timestamp=none "${MACOS}/Dynamo"
codesign --force --sign - --timestamp=none "${APP_DIR}"

echo "✓ Packaged: ${APP_DIR}"
echo "  Open with: open \"${APP_DIR}\""
echo "  Launch at Login works more reliably from this .app than from the bare SPM binary."
