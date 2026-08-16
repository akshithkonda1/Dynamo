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

# Pure byte-copy so no resource forks / xattrs poison codesign.
copy_bytes() {
  local src="$1" dst="$2"
  python3 -c "from pathlib import Path; s=Path('${src}'); d=Path('${dst}'); d.write_bytes(s.read_bytes()); d.chmod(0o755)"
}

copy_bytes "${BIN_DIR}/Dynamo" "${MACOS}/Dynamo"
echo "  copied Dynamo"

if [[ -f "${BIN_DIR}/DynamoMediaRemoteHelper" ]]; then
  copy_bytes "${BIN_DIR}/DynamoMediaRemoteHelper" "${MACOS}/DynamoMediaRemoteHelper"
  echo "  copied DynamoMediaRemoteHelper"
fi

python3 -c "from pathlib import Path; Path('${CONTENTS}/Info.plist').write_bytes(Path('${ROOT}/Sources/Dynamo/Info.plist').read_bytes())"

# Optional icon (byte-copy). If codesign later fails on the bundle, re-run without icon.
if [[ -f "${ROOT}/Sources/Dynamo/Resources/AppIcon.icns" ]]; then
  python3 -c "from pathlib import Path; Path('${RESOURCES}/AppIcon.icns').write_bytes(Path('${ROOT}/Sources/Dynamo/Resources/AppIcon.icns').read_bytes())"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${CONTENTS}/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "${CONTENTS}/Info.plist"
fi

# Local Amplify EQ designer + on-device Tone AI (pure Python, optional at runtime).
if [[ -f "${ROOT}/Tools/DynamoEQ/dynamo_eq.py" ]]; then
  python3 -c "from pathlib import Path; Path('${RESOURCES}/dynamo_eq.py').write_bytes(Path('${ROOT}/Tools/DynamoEQ/dynamo_eq.py').read_bytes())"
  echo "  copied dynamo_eq.py"
fi
if [[ -f "${ROOT}/Tools/DynamoEQ/dynamo_tone_ai.py" ]]; then
  python3 -c "from pathlib import Path; Path('${RESOURCES}/dynamo_tone_ai.py').write_bytes(Path('${ROOT}/Tools/DynamoEQ/dynamo_tone_ai.py').read_bytes())"
  echo "  copied dynamo_tone_ai.py"
fi

/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Dynamo" "${CONTENTS}/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Dynamo" "${CONTENTS}/Info.plist"

xattr -cr "${APP_DIR}" 2>/dev/null || true
xattr -c "${MACOS}/Dynamo" 2>/dev/null || true
[[ -f "${MACOS}/DynamoMediaRemoteHelper" ]] && xattr -c "${MACOS}/DynamoMediaRemoteHelper" 2>/dev/null || true

echo "→ Ad-hoc codesign…"
if [[ -x "${MACOS}/DynamoMediaRemoteHelper" ]]; then
  codesign --force --sign - --timestamp=none "${MACOS}/DynamoMediaRemoteHelper"
  echo "✓ Embedded DynamoMediaRemoteHelper"
else
  echo "warning: DynamoMediaRemoteHelper not embedded (media falls back to AppleScript)"
fi
codesign --force --sign - --timestamp=none "${MACOS}/Dynamo"
if ! codesign --force --sign - --timestamp=none "${APP_DIR}" 2>/dev/null; then
  # Icon xattrs sometimes break bundle sign — drop icon and retry once.
  echo "  retry without AppIcon…"
  rm -f "${RESOURCES}/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "${CONTENTS}/Info.plist" 2>/dev/null || true
  xattr -cr "${APP_DIR}" 2>/dev/null || true
  codesign --force --sign - --timestamp=none "${MACOS}/DynamoMediaRemoteHelper" 2>/dev/null || true
  codesign --force --sign - --timestamp=none "${MACOS}/Dynamo"
  codesign --force --sign - --timestamp=none "${APP_DIR}"
fi
codesign --verify --verbose=0 "${APP_DIR}"

echo "✓ Packaged: ${APP_DIR}"
echo "  Open with: open \"${APP_DIR}\""
echo "  Launch at Login works more reliably from this .app than from the bare SPM binary."
