# Dynamo tests

Mixed suite: **Python** (DynamoEQ DSP), **Swift** (XCTest on package logic), **shell** (project sanity).

## Quick run

```bash
./scripts/test.sh           # everything
./scripts/test.sh python    # DynamoEQ only
./scripts/test.sh swift     # XCTest only
./scripts/test.sh shell     # file/version/grep checks
```

## Python (`Tests/python/`)

| File | Covers |
|------|--------|
| `test_dynamo_eq.py` | Biquads, profiles, media analysis, symphony coeffs, stereo process, CLI |

Also: `python3 Tools/DynamoEQ/dynamo_eq.py selftest`

## Swift (`Tests/DynamoTests/`)

| File | Covers |
|------|--------|
| `WidgetRegistryTests.swift` | Register / enable / reorder / config sanitize / sneak-peek fan-out |
| `NotchGeometryTests.swift` | Expanded width/height bounds, peek/HUD sizes |
| `AmplifyProfileTests.swift` | Profile resolve + device infer + embedded EQ curves |
| `WorldClockSortTests.swift` | Sort modes, city coords, distance / random stability |

```bash
export DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer   # if needed
swift test --filter DynamoTests
```

## Notes

- SPM does **not** embed `AppIcon.icns` (avoids codesign “resource fork” failures during `swift test`).
- Executable target `Dynamo` is still `@testable import`able from XCTest.
- UI / permission / process-tap behavior remains in manual smoke: `docs/SMOKE_TEST.md`.
