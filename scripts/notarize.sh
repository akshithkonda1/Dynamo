#!/usr/bin/env bash
# Re-signs a built .app with a Developer ID Application identity, submits it
# to Apple's notary service, and staples the resulting ticket.
#
# This targets the SPM/package-app.sh-built .app (ad-hoc signed, no
# WeatherKit — see that script and the README's "Build & run" section). For a
# release that includes a working Weather widget, notarize an .app exported
# from the Xcode target instead (xcodebuild -exportArchive with method
# developer-id) — .github/workflows/release.yml does exactly that in CI and
# does not call this script; this one is for local ad-hoc-build notarization.
#
# Requires your own Apple Developer Program credentials — this repo ships no
# certificates or secrets. Set:
#   DEVELOPER_ID_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#                           (see `security find-identity -v -p codesigning`)
# and either an API key:
#   NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_PATH
# or an Apple ID + app-specific password (generate one at appleid.apple.com):
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_APP_PASSWORD
#
# Usage: scripts/notarize.sh [path/to/Dynamo.app]   (defaults to dist/Dynamo.app)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-${ROOT}/dist/Dynamo.app}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: ${APP_PATH} not found. Build it first (scripts/package-app.sh)." >&2
  exit 1
fi

: "${DEVELOPER_ID_IDENTITY:?Set DEVELOPER_ID_IDENTITY to your \"Developer ID Application: ...\" identity}"

echo "→ Re-signing with Developer ID (ad-hoc signing can't be notarized)…"
codesign --force --deep --options runtime --timestamp \
  --entitlements "${ROOT}/Sources/Dynamo/Dynamo.entitlements" \
  --sign "${DEVELOPER_ID_IDENTITY}" "${APP_PATH}"

ZIP_PATH="${ROOT}/dist/Dynamo-notarize.zip"
rm -f "${ZIP_PATH}"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "→ Submitting to Apple's notary service (this can take a few minutes)…"
if [[ -n "${NOTARY_KEY_ID:-}" ]]; then
  : "${NOTARY_ISSUER_ID:?}"
  : "${NOTARY_KEY_PATH:?}"
  xcrun notarytool submit "${ZIP_PATH}" \
    --key "${NOTARY_KEY_PATH}" --key-id "${NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER_ID}" \
    --wait
else
  : "${NOTARY_APPLE_ID:?Set NOTARY_APPLE_ID (or the NOTARY_KEY_ID API-key trio)}"
  : "${NOTARY_TEAM_ID:?}"
  : "${NOTARY_APP_PASSWORD:?}"
  xcrun notarytool submit "${ZIP_PATH}" \
    --apple-id "${NOTARY_APPLE_ID}" --team-id "${NOTARY_TEAM_ID}" --password "${NOTARY_APP_PASSWORD}" \
    --wait
fi

echo "→ Stapling ticket…"
xcrun stapler staple "${APP_PATH}"

rm -f "${ZIP_PATH}"
echo "✓ Notarized and stapled: ${APP_PATH}"
