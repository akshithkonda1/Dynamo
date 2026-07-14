#!/usr/bin/env bash
# Packages a built (ideally notarized — run scripts/notarize.sh or the
# release.yml workflow first) .app into a distributable .dmg with a symlink
# to /Applications for a standard drag-to-install experience.
#
# Usage: scripts/make-dmg.sh [path/to/Dynamo.app]   (defaults to dist/Dynamo.app)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-${ROOT}/dist/Dynamo.app}"
DMG_PATH="${ROOT}/dist/Dynamo.dmg"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: ${APP_PATH} not found. Build it first (scripts/package-app.sh)." >&2
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT

cp -R "${APP_PATH}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

rm -f "${DMG_PATH}"
hdiutil create -volname "Dynamo" -srcfolder "${STAGING}" -ov -format UDZO "${DMG_PATH}"

echo "✓ Created: ${DMG_PATH}"
