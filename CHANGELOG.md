# Changelog

All notable changes to Dynamo are documented here.

## [0.4.0] — 2026-07-15

**Stability & day-driver release.** Focus: the notch stays put, Music works, Webcam mirrors correctly, and local packaging is trustworthy.

### Highlights

- **Stable notch hover** — debounced collapse, ignore spurious `mouseExited` during resize, larger hit target, single-instance guard so two copies don’t fight
- **Music / Spotify that actually controls playback** — dual-fire MediaRemote + AppleScript, bundle-id targeting, safe metadata parsing, no empty-flash after skip
- **Webcam as a real mirror** — horizontal flip by default, preference remembered, session no longer thrashing on expand/collapse
- **Show Notch** menu item when the collapsed strip is hard to find
- **Reminders peeks**, multi-display picker, hardened MediaRemote helper, release packaging scripts

### Fixes

- Notch expand/collapse thrashing (intermittent “vanishing” tray)
- Panel window level / `isFloatingPanel` demoting under menu bar chrome
- Webcam black/flickering preview; mirror not applied or not persisted
- Media transport that returned success without controlling Music
- AppleScript field separator breaking on titles containing `|`
- MediaRemote helper discovery + live publish + auto-restart
- SPM resource-bundle codesign failures (xcassets excluded from Package target)

### Features

- Smoke-test checklist (`docs/SMOKE_TEST.md`) and run guide (`docs/RUN.md`)
- EventKit incomplete-reminder peeks (~5 min lead)
- Settings → Display for notch (multi-monitor)
- Regenerated app icon (correct pixel sizes)
- `scripts/release-local.sh` (package → optional notary → DMG)
- Safer ad-hoc codesign (nested binaries, then bundle)

### Notes

- **WeatherKit** still needs a paid Apple Developer team + Xcode-signed app for live weather
- First Music/Spotify control may prompt **Automation** permission — allow Dynamo → Music
- Messages widget removed (compose-only send was not a good notch fit)

### Build

```bash
cd ~/Documents/Dynamo
xcodegen generate && open Dynamo.xcodeproj   # or:
./scripts/package-app.sh debug && open dist/Dynamo.app
```

---

## [0.3.0] — earlier

Phase 3–4 foundation: WeatherKit widget, XcodeGen app target, peek-a-boo, ambient now-playing, shelf AirDrop, webcam introduction, MediaRemote helper, notarization pipeline scaffolding.
