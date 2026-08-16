# Changelog

All notable changes to Dynamo are documented here.

## [1.1.1] — 2026-08-15

**Symphony Amplify + polish release.**

### Amplify / DynamoEQ
- Local multi-band amplifier (no Music Automation, no network APIs)
- **Media type & quality** analysis (speech / music / bass-heavy / bright / low-quality)
- **Per-note spectral tuning** (sub, punch, presence, air, …)
- **Device-aware symphony path**: wired headphones, wireless/BT, Mac speakers, external
- Spatial / Atmos–safe: post-render EQ, same curve per channel, mid-side width on stereo
- Profiles: **Reference** (transparent) · **Symphony** (mild default) · Presence · Cinema · Impact (width only)
- **Seamless transitions (v3):** equal-power dual-bank crossfade (~90 ms); wet engage / soft stop
- **Full Dolby Atmos support:** device-stream tap; multi-ch layout; LFE/height/surround roles; Spatial path; stereo-mix fallback labeled
- **Fidelity Tier A/B:** linked true-peak limiter (−1 dBTP); live adaptive analysis; quieter gains; headroom staging; mild device calibration; dry loudness match
- Python designer: `Tools/DynamoEQ/dynamo_eq.py` (`reference`, `coeffs --path atmosBed`, …)


### Performance & feel
- **Instant island:** faster expand springs (~0.20s), snappier collapse default (3s; migrate from 5s), 1s collapse option, tighter hover near-pad
- Adaptive media poll (0.75s playing / 2s idle); snappier skip/seek refresh probes
- Responsive polls: notifications 1.5s, volume 1.25s, calls 2s, clipboard 1.5s, Amplify sync 0.75s
- Checklist/Notes/Reminders refresh on open; Calendar EventKit 30s
- Tray: hover name previews ~90ms, press scale, haptics, bounce (macOS 14+)
- Amplify toggle always works (Meeting only auto-offs on enter)
- Friendlier empty states across Calendar, Clipboard, Checklist, Media, Shelf, Focus

### Also in this line
- World Clock distance / reverse / random sort
- Preferences rebrand, Feel & alerts, icon-only tray + hover previews
- Calendar full-access fix, compact empty island, wider island (1650pt)

### Version
- `CFBundleShortVersionString` **1.1.1** / build **111**


## [1.0.1] — 2026-08-15

**Snappier notch + World Clock + Preferences.**

### Highlights

- **World Clock** replaces Weather in the production tray (free, offline, no WeatherKit)
- Clocks references: **major cities**, **current location** (Core Location city label), **Apple IANA time zones**
- DST badges, call-window, converter (“when it’s X here”), copy time, full TZ search in Preferences
- **Preferences** renames awkward “Settings…” labeling (menu, gear tray, window title)
- New **Feel & alerts** pane: collapse delay (incl. 3s snappy), Peek duration/haptics, Amplify EQ, notification mirror
- Snappier expand/collapse springs and faster media / volume / call / notif polls
- Slightly more sensitive hover (near padding, shorter retreat / suppress windows)

### Notes

- Weather source remains in tree for a future opt-in build
- Version 1.0.1 build 101


## [1.0.0] — 2026-08-03

**Production daily driver (Weather disabled).**

### Highlights

- Production tray without Weather/WeatherKit (paid-team dependency removed from ship path)
- Peek notification center + system notification mirror + DynamoNotificationAPI
- Media Amplify (EQ-only Presence/Cinema/Impact); transport under scrubber
- Calendar create, Reminders R/W, battery power modes, Focus/Meeting
- Full permissions catalog in Settings
- Single-instance dist/Dynamo.app packaging (ditto/python byte-copy + ad-hoc codesign)

### Notes

- Weather source remains in tree for a future opt-in build
- Notarization / Developer ID still optional for other Macs


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
