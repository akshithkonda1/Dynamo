#!/usr/bin/env bash
# Dynamo combined test runner — Python (primary DSP) + Swift (package) + light shell checks.
# Usage:
#   ./scripts/test.sh           # all
#   ./scripts/test.sh python    # DynamoEQ only
#   ./scripts/test.sh swift     # XCTest only
#   ./scripts/test.sh shell     # smoke/shell only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -d "/Users/akshithkonda/Downloads/Xcode-beta.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Users/akshithkonda/Downloads/Xcode-beta.app/Contents/Developer}"
fi

MODE="${1:-all}"
FAILED=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
section() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

run_python() {
  section "Python — DynamoEQ (Tools/DynamoEQ + unittest)"
  if ! command -v python3 >/dev/null; then
    red "python3 not found"
    return 1
  fi
  python3 Tools/DynamoEQ/dynamo_eq.py selftest || return 1
  python3 -m unittest discover -s Tests/python -p 'test_*.py' -v || return 1
  green "Python tests passed"
  return 0
}

run_swift() {
  section "Swift — XCTest (Package.swift DynamoTests)"
  # Clear resource-fork xattrs that break ad-hoc codesign of SPM products
  xattr -cr .build 2>/dev/null || true
  if ! swift test --filter DynamoTests; then
    red "swift test failed once — cleaning and retrying"
    rm -rf .build
    swift test --filter DynamoTests || return 1
  fi
  green "Swift tests passed"
  return 0
}

run_shell() {
  section "Shell — project sanity"
  # Version consistency
  VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/Dynamo/Info.plist) || return 1
  echo "Info.plist version: $VER"
  [[ -n "$VER" ]] || return 1

  # Required paths
  test -f Package.swift || return 1
  test -f Tools/DynamoEQ/dynamo_eq.py || return 1
  test -f Tests/DynamoTests/WidgetRegistryTests.swift || return 1
  test -f Tests/python/test_dynamo_eq.py || return 1
  test -f scripts/package-app.sh || return 1

  # Python syntax
  python3 -m py_compile Tools/DynamoEQ/dynamo_eq.py || return 1
  python3 -m py_compile Tests/python/test_dynamo_eq.py || return 1

  # No Weather in production registration (grep source)
  if grep -n 'registry.register(WeatherPlugin' Sources/Dynamo/App/AppDelegate.swift 2>/dev/null; then
    red "WeatherPlugin still registered in AppDelegate (production should omit it)"
    return 1
  fi
  grep -q 'WorldClockPlugin' Sources/Dynamo/App/AppDelegate.swift || return 1

  # Notes tab present
  grep -q 'case notes' Sources/Dynamo/Widgets/Checklist/ChecklistPlugin.swift || return 1
  grep -q 'NotesProvider' Sources/Dynamo/Widgets/Checklist/NotesProvider.swift || return 1

  green "Shell checks passed"
  return 0
}

case "$MODE" in
  python) run_python || FAILED=1 ;;
  swift)  run_swift  || FAILED=1 ;;
  shell)  run_shell  || FAILED=1 ;;
  all)
    run_shell  || FAILED=1
    run_python || FAILED=1
    run_swift  || FAILED=1
    ;;
  *)
    echo "Usage: $0 [all|python|swift|shell]"
    exit 2
    ;;
esac

echo ""
if [[ "$FAILED" -eq 0 ]]; then
  green "✓ All requested tests passed ($MODE)"
  exit 0
else
  red "✗ Some tests failed ($MODE)"
  exit 1
fi
