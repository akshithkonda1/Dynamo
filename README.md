# Dynamo

**macOS notch dock** — a Dynamic Island–style widget tray for the MacBook notch, built for daily productivity rather than pure visual mimicry.

Dynamo turns the notch into an interactive tray with a plugin architecture (widgets are cheap to add or remove). **Dynamo is the notification router**: alerts are delivered as **Peeks** in the notch (and kept in the **Hub** inbox), not as typical top-right system banners for Dynamo’s own sources. Everything is **on-device by default** — free/native frameworks preferred over paid cloud APIs.

| | |
|---|---|
| **Version** | **1.1.1** |
| **Platform** | macOS 13+ (14.2+ for live process-tap EQ / Symphony Amplify) |
| **Daily driver** | `dist/Dynamo.app` only (single-instance) |
| **License** | MIT |

> Personal daily-driver project. Production ships **World Clock** instead of Weather (WeatherKit needs a paid Apple team). Amplify EQ is **local DSP + on-device Tone AI** — no Music Automation, **no cloud APIs**, no on-device storage of audio or training corpora.

---

## Widgets

Registered in `AppDelegate.bootstrap()`:

| Widget | What it does |
|--------|----------------|
| **Media** | Now playing, transport, scrub, playlists, output device, **Amplify** (local multi-band EQ + **Tone AI** genre tuning), cover-art equalizer |
| **Hub** | **Notification inbox** — unread, mark read, clear, **replay** as Peek; ambient unread badge |
| **Calendar** | Upcoming events (EventKit full access), in-notch **create event**, open Calendar.app |
| **Checklist** | Apple **Reminders** R/W (create / complete / due presets) + local checklist · Notes tab |
| **Clipboard** | Recent text, **images**, **Finder files**; pin with **color tags**; paste as plain |
| **Clocks** | **World Clock** — major cities · **Here first** · GPS “Here” label · Apple IANA time zones · **distance / reverse / random sort** · DST · converter · call window |
| **Battery** | Charge, health, drain, vitals grid; **Low / Auto / High** power modes (`pmset`); ambient fill glyph |
| **Focus** | Normal · Dynamic · True Focus · **Meeting** companion (notes, talk tips, duck volume) |
| **Sports** | Multi-league scores via free ESPN public CDN (no API key) |
| **System Health** | Local Mac health score + deep links to System Settings / updates |
| **Shelf** | Drop files on the notch; open / reveal / AirDrop |
| **Webcam** | Live mirror (incl. Continuity Camera); camera only while the tab is open |

**Background systems:**

| System | Role |
|--------|------|
| **`DynamoNotificationRouter`** | Single path for widgets · Focus · system apps · API / URL / Shortcuts → Peek |
| **`PeekNotificationCenter`** | Queue, coalesce, urgency, haptics, **inbox history** |
| **System app ingest** | Optional Messages / FaceTime / Mail / messengers → router (Full Disk Access) |
| **DynamoEQ + Tone AI** | Local Amplify designer + on-device genre tuning |
| Meeting speech (opt-in), global hotkeys, `dynamo://`, Peek Bridge | As before |

> **Production note:** **Weather** is **not registered** (WeatherKit needs a paid team). Source remains under `Widgets/Weather/` for a future opt-in build. **Clocks** is the free replacement.

---

## What’s new (1.0.x → 1.1.1)

| Area | Change |
|------|--------|
| **Notifications → Peek** | **Deliver through Peek only** (default). Dynamo routes all alerts into the notch — not a dual system-banner mirror. |
| **Router** | `DynamoNotificationRouter` owns policy; per-source toggles (widgets / Focus / system / external). |
| **Hub tab** | Inbox with unread, mark read, clear, **replay**; ambient unread badge when collapsed. |
| **Message Peeks** | Contact photo (Contacts) + **chrome tinted to the photo palette**; circular avatar. |
| **Tone AI (Amplify)** | On-device genre/tone classifier (Python + Swift). Pop vs classical vs electronic, etc. **No APIs.** No audio stored on device. |
| **Amplify fidelity** | Reference profile, linked true-peak (~−1 dBTP), live adaptive, Atmos/Spatial path auto, headroom, dry loudness match, device cal |
| **Amplify UX** | Toggle always clickable; seamless dual-bank crossfades; status shows path + **AI Genre** |
| **Battery** | Hero fill glyph, status chips, 2×2 vitals, tips, ambient shell |
| **Peek / HUD geometry** | Notch-aware: camera-band top inset, modest flare from the physical cutout |
| **Clocks** | **Here first**; **location permission on boot** for Here + distance sort |
| **Tray** | Icon-only + hover previews; island width cap **1650pt**; snappier collapse options |
| **Checklist** | Local + Apple Notes / Reminders polish |

---

## Highlights

### Preferences (not “Settings…”)
Menu bar and gear open **Preferences**. Sections: **General**, **Feel & alerts** (collapse delay, **notification router**, Amplify), **Appearance**, **Widgets**, **Permissions**, per-widget options.

### Tray UX
- **Icon-only** tray — no name chips when a tab is selected  
- **Hover preview** — short delay, then a tab-style name under the icon  
- Expanded island width is aspect-adaptive (cap **1650pt** on large displays)  
- Empty Calendar stays **compact**

### Clocks (World Clock)
Free, offline, no WeatherKit. **Location is requested on launch** (When In Use):

| Feature | Detail |
|---------|--------|
| References | Major cities · **Current Location / Here** · Apple IANA time zones |
| Sort | **Here first** · **Nearest** · **Farthest** · **Random** · **As picked** |
| Distance | km from GPS (in memory only) on distance modes |
| Extras | DST badges, call-window, “when it’s X here” converter, copy time |

---

## Notifications: Dynamo router → Peek (not typical banners)

```
  Widgets · Focus · Messages/FaceTime/Mail · API / URL / Shortcuts
                         │
                         ▼
              DynamoNotificationRouter     ← policy (per-source on/off)
                         │
                         ▼
              Peek hub (notch Peek + Hub inbox)
```

### How delivery works

| What | Behavior |
|------|----------|
| **Dynamo’s own alerts** | Always via **Peek only** — Dynamo does **not** post macOS corner banners for calendar, battery, media, Focus, Hub, API, etc. |
| **System apps (optional)** | Ingested from Notification Center → **router** → Peek + Hub (Messages, FaceTime, Mail, Slack, …) |
| **Peek-only mode** (default) | Longer dwell for messages/calls; hub is the presentation surface |
| **Hub tray tab** | Inbox, unread count, mark read, clear, tap to **replay** Peek |
| **Message chrome** | Contact photo from **Contacts**; island wash/ring/lip match the photo colors |

### Public API (always goes through the router)

| Path | Example |
|------|---------|
| Swift | `DynamoNotificationAPI.post(title:subtitle:…)` |
| URL | `dynamo://notify?title=Hello&subtitle=World&urgency=high` |
| Distributed | `com.akshithkonda.Dynamo.notify` |

### Stop the usual corner banners (Messages / FaceTime / …)

Apple does **not** allow third-party apps to hide other apps’ system banners. For **Peek-only** with texts/calls:

1. Preferences → **Deliver through Peek only** + **Route system apps into Peek**  
2. Grant **Full Disk Access** (so Dynamo can read the Notification Center store)  
3. Grant **Contacts** (contact photo + color on message Peeks)  
4. System Settings → **Notifications** → for **Messages**, **FaceTime**, **Mail** (etc.):
   - Keep **Allow Notifications** **on** (so Dynamo can still see deliveries)  
   - Set **Alert style → None** (kills the typical top-right banner)

Preferences includes **Open Notifications settings** / **Open Focus** helpers for this.

---

## Media Amplify — DynamoEQ + Tone AI

Local sound processing only — **no Music Automation, no cloud APIs, not the volume fader.**

| Goal | How |
|------|-----|
| **1. Amplify by media type & quality** | PCM analysis: speech / music / bass-heavy / bright / sparse / low-quality + DR/bandwidth |
| **2. Tune each “note” region** | Spectral regions (sub, punch, presence, air, …) get suggested gains |
| **3. “You are there” / symphony** | Device voicing: wired · wireless/BT · Mac speakers · external |
| **4. Tone AI (genre-aware)** | On-device classifier + local genre metadata → Pop vs Classical vs Electronic, etc. |

| | |
|--|--|
| **Realtime** | `LocalAmplifyEngine` + `AmplifyToneAI` — process tap → multi-band EQ (macOS **14.2+**) |
| **Designer** | `Tools/DynamoEQ/dynamo_eq.py` v4 + `dynamo_tone_ai.py` — pure Python 3 stdlib |
| **Profiles** | **Reference** · **Symphony** · Presence · Cinema · Impact (width only on Impact) |
| **Fidelity** | Linked true-peak (~−1 dBTP) · live adaptive · headroom · dry loudness match |
| **Seamless** | Equal-power dual-bank crossfade; wet engage / soft stop |
| **Atmos / Spatial** | Device-stream tap; multi-ch LFE/height; mid-side off on immersive paths; honest stereo-mix fallback label |
| **Privacy** | Audio never recorded or uploaded. Tone AI session EMA cleared on Amplify stop. Offline `train` discards PCM after features — only weights export. |

```bash
python3 Tools/DynamoEQ/dynamo_eq.py selftest
python3 Tools/DynamoEQ/dynamo_tone_ai.py selftest
python3 Tools/DynamoEQ/dynamo_eq.py coeffs --profile symphony --device headphones --sr 48000 \
  --metadata "Mozart Symphony classical"
python3 Tools/DynamoEQ/dynamo_tone_ai.py classify \
  --features '{"bass_ratio":0.15,"brightness":0.3,"crest_db":14,"zcr":0.06,"dynamic_range_db":18,"speech_likelihood":0.05,"bandwidth_hz":14000,"mid_ratio":0.35}' \
  --metadata "Mozart Piano Concerto"
python3 Tools/DynamoEQ/dynamo_tone_ai.py train --synthetic --export
```

---

## Calendar, Focus, Battery

### Calendar & Reminders
- **Full Calendar Access** required to list events (write-only is detected and prompted)  
- Create events / reminders in the notch  

### Focus & Meeting
- **Meeting** — notes, optional Listen, talk tips, volume duck; never auto-joins calls  
- Smart enter/leave from calendar + call apps  
- Meeting Mode quiets low/normal Peeks (calls/texts still surface when prioritized)

### Battery
- Hero % + live fill glyph, health, cycles, temp, drain grid  
- **Low · Auto · High** power modes via `pmset` when supported  
- Low-battery Peeks; ambient fill + LPM badge  

---

## Requirements

- **macOS 13+** (14.2+ for process-tap visualizer + **local Amplify**)  
- **Xcode 15+** (or recent beta) with macOS SDK when building from source  
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** only if you want the optional WeatherKit app target  

**Permissions (as needed):**

| Permission | Used for |
|------------|----------|
| Calendar (full) | Events in notch |
| Reminders | Checklist |
| Microphone / audio capture | Amplify EQ, peek EQ, Meeting Listen |
| Speech | Meeting Listen notes |
| Camera | Webcam tab only |
| **Location** (on boot) | Clocks “Here” + distance sort |
| **Contacts** | Message Peek photos + color tint |
| **Full Disk Access** | Route system apps (Messages, etc.) into Peek |
| Automation | Music/Spotify transport — **not** required for Amplify EQ |

---

## Build & run

### 1. Daily driver — packaged app (recommended)

```bash
./scripts/package-app.sh          # release → dist/Dynamo.app
./scripts/package-app.sh debug
open dist/Dynamo.app
```

- Ad-hoc signed; suitable for Launch at Login  
- **Only run `dist/Dynamo.app`** — single-instance daily driver  
- Embeds `dynamo_eq.py` + `dynamo_tone_ai.py` when present  
- Production tray **does not** include Weather  
- Remove older `Dynamo 2.app` / `Dynamo 3.app` copies so the notch is not contested  

### 2. Swift Package (fast compile / CI)

```bash
export DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer   # if needed
swift build -c release
.build/release/Dynamo
```

### 3. Xcode app target (optional WeatherKit)

```bash
brew install xcodegen
xcodegen generate
open Dynamo.xcodeproj
```

Signing → paid team if you enable WeatherKit.

---

## Preferences & shortcuts

**Preferences** (gear in tray, menu **Preferences**, or ⌘,):

- Launch at login, Hidden Mode, Meeting options  
- **Feel & alerts** — collapse delay, **Deliver through Peek only**, router source toggles, Amplify, test Peeks  
- Display picker, widget toggle + reorder  
- Clocks city/zone pickers + sort mode  
- Full permissions catalog  

**Hotkeys** (⌃⌥ = Control + Option):

| Shortcut | Action |
|----------|--------|
| ⌃⌥D | Show / expand notch |
| ⌃⌥P | Play / pause |
| ⌃⌥M | Mute |
| ⌃⌥S | Focus Shelf |
| ⌃⌥C | Focus Calendar |
| ⌃⌥B | Focus Clipboard |
| ⌃⌥H | Focus Hub |

**URL scheme:** `dynamo://show` · `mute` · `play` · `shelf` · `calendar` · `clipboard` · `hub` · `airdrop` · `notify?title=…` · `peek?title=…`

---

## Architecture

- **`NotchWidgetPlugin`** — every tray widget; hosts never special-case by name  
- **Capabilities** via protocol cast: `NotchAmbientProviding`, `NotchSneakPeekProviding`, `FileDropAccepting`, …  
- **One folder per widget** under `Sources/Dynamo/Widgets/<Name>/`  
- **`DynamoNotificationRouter`** — single entry for all alerts; source policy  
- **`PeekNotificationCenter`** — queue · coalesce · history · unread  
- **`NotchSneakPeekController`** — live Peek presentation + dwell  
- **`LocalAmplifyEngine`** + **`AmplifyToneAI`** + **`Tools/DynamoEQ/`** — Amplify  
- **`NotchGeometry`** — physical cutout metrics, expanded width (cap 1650pt), notch-aware peek/HUD sizes  
- **`NotchWindowController`** — collapsed ↔ expanded; peeks/HUD are overlays  

**SPM vs Xcode:** `Package.swift` = sources + CI; `project.yml` → signed `.app` with entitlements when needed.

---

## Weather (optional, not in production tray)

Native WeatherKit requires the **Xcode app target** and a **paid team**. Production uses **Clocks** instead. Weather source remains in-tree for opt-in builds.

---

## Notarization & release

| Script | Role |
|--------|------|
| `scripts/package-app.sh` | Ad-hoc `dist/Dynamo.app` |
| `scripts/notarize.sh` | Developer ID + notary + staple |
| `scripts/make-dmg.sh` | DMG with Applications symlink |
| `scripts/release-local.sh` | Package → optional notary → DMG |
| `.github/workflows/release.yml` | Tag `v*` → CI archive / notary / DMG |

No credentials in repo — see script headers for secrets.

---

## Tests

```bash
./scripts/test.sh           # all
./scripts/test.sh python    # DynamoEQ + Tone AI
./scripts/test.sh swift     # Package XCTest
./scripts/test.sh shell     # sanity
python3 -m unittest Tests/python/test_dynamo_tone_ai.py -v
python3 Tools/DynamoEQ/dynamo_eq.py selftest
python3 Tools/DynamoEQ/dynamo_tone_ai.py selftest
```

See **[Tests/README.md](Tests/README.md)**. Manual UI smoke: **[docs/SMOKE_TEST.md](docs/SMOKE_TEST.md)** · **[docs/PRODUCTION_READINESS.md](docs/PRODUCTION_READINESS.md)**.

Quick checks:

1. One process: `dist/Dynamo.app` only  
2. Hover tray icons → **name preview**; press stays icon-only  
3. **Clocks** present; no Weather tab; sort nearest / farthest / random  
4. Media: play/pause first-click; Amplify on/off; status may show **AI Genre**  
5. Calendar: Full Access → events; empty state is short  
6. Checklist → add reminder  
7. Battery power chips + vitals  
8. Focus → Meeting → Leave  
9. **Hub** tab lists Peeks; Calendar filter shows calendar alerts; inbox survives relaunch  
10. `open 'dynamo://notify?title=Test&subtitle=Hub&urgency=high'` → notch Peek + Hub inbox  
11. Message Peek (with Contacts): photo + color-matched chrome  
12. Copy text → Peek “Copied”; copy a Finder file → Clipboard history row; pin + color tag  
13. `open 'dynamo://clipboard'` / `dynamo://hub` expand those tabs; menu **AirDrop Last Shelf Item** when Shelf is non-empty  

---

## Project layout

```
Sources/Dynamo/
  App/                 AppDelegate, Preferences
  Notch/               Panel, geometry, Peek presentation, tray UX
  Plugins/             Widget protocols + registry
  Support/             DynamoNotificationRouter, PeekNotificationCenter,
                       system ingest, Focus, Meeting, Contacts photo, URLs
  System/              Volume, HUD, launch at login
  Theme/               NotchTheme, live EQ visualizer, chrome
  Widgets/             Media, Notifications (Hub), Calendar, Clocks, Battery, …
Tools/DynamoEQ/        dynamo_eq.py + dynamo_tone_ai.py (no network)
scripts/               package, notarize, dmg, release, test
docs/                  Smoke test, production readiness
dist/                  Packaged Dynamo.app (daily driver)
Tests/                 Python (EQ / Tone AI) + Swift XCTest
```

---

## History (condensed)

| Phase | Focus |
|-------|--------|
| 1–2 | Notch engine, plugin tray, Media/Calendar/Clipboard/Checklist, Battery, Shelf, HUD, package-app |
| 3–4 | WeatherKit target, peeks, Webcam, helper process, multi-display, release scripts |
| 5–7 | Stability, Focus/Meeting, Sports, System Health, power modes, process-tap visualizer |
| **0.5.x** | Adaptive width, Amplify intents, Peek center |
| **1.0.0** | Production without Weather; packaging hardened |
| **1.0.1** | World Clock + distance sort, Preferences, calendar full-access, icon-only tray |
| **1.1.1** | DynamoEQ Symphony + Tone AI; Atmos/Spatial path; **notification router + Peek-only hub**; Battery/Peek notch polish; message contact-photo tint |

See [CHANGELOG.md](CHANGELOG.md) for release notes.

---

## Known limitations

- **WeatherKit** needs paid team + Xcode-signed app (not in production tray)  
- **Local Amplify** needs **macOS 14.2+** and audio-capture permission; not a licensed Dolby decoder — it EQs the **post-render** Spatial/Atmos mix  
- **Power modes** may open Battery Settings if `pmset` is blocked  
- **Sports** uses an undocumented free ESPN feed  
- **System-app routing** needs Full Disk Access; best-effort against the Notification Center store  
- **macOS banners for other apps** cannot be killed by Dynamo — set Alert style to **None** (or use Focus) for Peek-only visuals  
- Automated UI tests remain thin relative to surface area  

---

## License

MIT — see [LICENSE](LICENSE).
