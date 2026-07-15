#!/usr/bin/env bash
# Local release helper: package → (optional) Developer ID re-sign + notarize → DMG.
#
# WeatherKit-signed releases should come from Xcode / CI exportArchive with a
# paid team. This script covers the ad-hoc → Developer ID → notary path for
# personal distribution of the non-WeatherKit build, and will also wrap any
# .app you pass in (including one you exported from Xcode).
#
# Usage:
#   scripts/release-local.sh                  # package debug? no — release package
#   scripts/release-local.sh --skip-notary    # package + DMG only (ad-hoc)
#   scripts/release-local.sh path/to/Dynamo.app
#
# Notarization env (when not --skip-notary):
#   DEVELOPER_ID_IDENTITY
#   and either NOTARY_KEY_ID/NOTARY_ISSUER_ID/NOTARY_KEY_PATH
#   or NOTARY_APPLE_ID/NOTARY_TEAM_ID/NOTARY_APP_PASSWORD
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SKIP_NOTARY=0
APP_PATH=""
for arg in "$@"; do
  case "$arg" in
    --skip-notary) SKIP_NOTARY=1 ;;
    *) APP_PATH="$arg" ;;
  esac
done

if [[ -z "$APP_PATH" ]]; then
  echo "→ Packaging release .app…"
  "${ROOT}/scripts/package-app.sh" release
  APP_PATH="${ROOT}/dist/Dynamo.app"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app not found at ${APP_PATH}" >&2
  exit 1
fi

# Verify MediaRemote helper embed (required for reliable now-playing on 15.4+).
HELPER="${APP_PATH}/Contents/MacOS/DynamoMediaRemoteHelper"
if [[ -x "$HELPER" ]]; then
  echo "✓ MediaRemote helper present: ${HELPER}"
else
  echo "warning: DynamoMediaRemoteHelper missing from app bundle — media may fall back to AppleScript only" >&2
fi

if [[ "$SKIP_NOTARY" -eq 0 ]]; then
  if [[ -z "${DEVELOPER_ID_IDENTITY:-}" ]]; then
    echo "note: DEVELOPER_ID_IDENTITY not set — skipping notarize. Re-run with credentials or --skip-notary."
    SKIP_NOTARY=1
  fi
fi

if [[ "$SKIP_NOTARY" -eq 0 ]]; then
  echo "→ Notarizing…"
  "${ROOT}/scripts/notarize.sh" "${APP_PATH}"
else
  echo "→ Skipping notarization"
fi

echo "→ Building DMG…"
"${ROOT}/scripts/make-dmg.sh" "${APP_PATH}"

echo "✓ Release artifacts under dist/"
ls -la "${ROOT}/dist" || true
