# Dynamo

**macOS notch dock** — a Dynamic Island–style widget tray for the MacBook notch, built for daily productivity rather than pure visual mimicry.

Dynamo turns the notch into an interactive tray with a plugin architecture (widgets are cheap to add or remove). Alerts surface as **Peeks** in the notch instead of system banners. Everything is **on-device by default** — free/native frameworks preferred over paid cloud APIs.

| | |
|---|---|
| **Version** | **1.1.1** (Tone AI + notch polish) |
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
| **Calendar** | Upcoming events (EventKit full access), in-notch **create event**, open Calendar.app |
| **Checklist** | Apple **Reminders** R/W (create / complete / due presets) + local checklist · Notes tab |
| **Clipboard** | Recent snippets |
| **Clocks** | **World Clock** — major cities · **Here first** · GPS “Here” label · Apple IANA time zones · **distance / reverse / random sort** · DST · converter · call window |
| **Battery** | Charge, health, drain, vitals grid; **Low / Auto / High** power modes (`pmset`); ambient fill glyph |
| **Focus** | Normal · Dynamic · True Focus · **Meeting** companion (notes, talk tips, duck volume) |
| **Sports** | Multi-league scores via free ESPN public CDN (no API key) |
| **System Health** | Local Mac health score + deep links to System Settings / updates |
| **Shelf** | Drop files on the notch; open / reveal / AirDrop |
| **Webcam** | Live mirror (incl. Continuity Camera); camera only while the tab is open |

**Background systems:** **`DynamoNotificationRouter`** → **Peek hub** (widgets · Focus · optional system apps · API; **Hub** tray inbox), Meeting speech capture (opt-in), global hotkeys, `dynamo://` URL scheme, Peek Bridge, **DynamoEQ** + **Tone AI**.

> **Production note:** **Weather** is **not registered** (WeatherKit needs a paid team). Source remains under `Widgets/Weather/` for a future opt-in build. **Clocks** is the free replacement.

---

## What’s new (since 1.0.x → 1.1.1)

| Area | Change |
|------|--------|
| **Tone AI (Amplify)** | On-device genre/tone classifier (Python + Swift). Pop vs classical vs electronic, etc. dynamically shapes EQ. **No APIs.** Ephemeral session EMA only — **no audio or training data stored on device**. |
| **Amplify fidelity** | Reference profile, linked true-peak (~−1 dBTP), live adaptive, Atmos/Spatial path auto, headroom staging, dry loudness match, mild device cal |
| **Amplify UX** | Toggle always clickable; seamless dual-bank crossfades; status shows path + **AI Genre** |
| **Battery** | Hero fill glyph, status chips, 2×2 vitals, actionable tips, ambient shell |
| **Peek / HUD** | Notch-aware silhouette: camera-band top inset, modest flare from the cutout (not a banner toast) |
| **Clocks** | **Here first** sort; **location permission requested on boot** for “Here” + distance modes |
| **Notification Hub** | Peek is the hub (not a dual mirror): queue + inbox + unread + replay; system apps **routed in**; **Hub** tray tab |
| **Tray** | Icon-only + hover previews; aspect-adaptive island (cap 1650pt); snappier collapse options |
| **Checklist** | Local + Apple Notes / Reminders polish |

---

## Highlights (core product)

### Preferences (not “Settings…”)
Menu bar and gear open **Preferences**. Sections include **General**, **Feel & alerts** (collapse delay, Peek, Amplify), **Appearance**, **Widgets**, **Permissions**, and per-widget options.

### Tray UX
- **Icon-only** tray — no name chips when a tab is selected  
- **Hover preview** — short delay, then a tab-style name under the icon  
- Expanded island width is aspect-adaptive (cap **1650pt** on large displays)  
- Empty Calendar stays **compact** (no giant blank sheet)

### Clocks (World Clock)
Free, offline, no WeatherKit. **Location is requested on launch** (When In Use) so “Here” and distance sort work immediately:

| Feature | Detail |
|---------|--------|
| References | Major cities · **Current Location / Here** · Apple IANA time zones |
| Sort | **Here first** · **Nearest** · **Farthest** · **Random** · **As picked** |
| Distance | km from GPS (or fallback) on distance modes — coordinate used only in memory |
| Extras | DST badges, call-window, “when it’s X here” converter, copy time |

### Media Amplify — DynamoEQ + Tone AI
Local sound processing only — **no Music Automation, no cloud APIs, not the volume fader.**

| Goal | How |
|------|-----|
| **1. Amplify by media type & quality** | PCM analysis: speech / music / bass-heavy / bright / sparse / low-quality + DR/bandwidth |
| **2. Tune each “note” region** | Spectral regions (sub, punch, presence, air, …) get suggested gains toward a musical balance |
| **3. “You are there” / symphony** | Device voicing: wired headphones · wireless/BT · Mac speakers · external + gentle mid-side stage |
| **4. Tone AI (genre-aware)** | On-device classifier (features + optional local Music/Spotify genre text) → Pop vs Classical vs Electronic vs Hip-hop, etc. Live makeup/HF + band bias. **Ephemeral only** |

| | |
|--|--|
| **Realtime** | `LocalAmplifyEngine` + `AmplifyToneAI` — process tap → multi-band EQ → output (macOS **14.2+**) |
| **Designer** | `Tools/DynamoEQ/dynamo_eq.py` v4 + `dynamo_tone_ai.py` — pure Python 3 stdlib |
| **Profiles** | **Reference** (transparent) · **Symphony** (mild default) · Presence · Cinema · Impact (width OK) |
| **Fidelity** | Linked true-peak (−1 dBTP) · live adaptive trims · headroom staging · dry loudness match |
| **Seamless** | Equal-power dual-bank crossfade; wet engage / soft stop |
| **Dolby Atmos** | Device-stream tap; multi-ch layout; LFE/height roles; mid-side off; status “Dolby Atmos bed” |
| **Spatial Audio** | Binaural path; no MS; stereo-mix fallback labeled honestly |
| **Privacy** | Audio never recorded or uploaded. Tone AI session EMA cleared on Amplify stop. Offline `train` may read developer PCM folders and **discards samples after features** — only weight numbers can be exported. |
| **UI** | Status: path · ch · **AI Genre** · device cal |

```bash
python3 Tools/DynamoEQ/dynamo_eq.py selftest
python3 Tools/DynamoEQ/dynamo_tone_ai.py selftest
python3 Tools/DynamoEQ/dynamo_eq.py coeffs --profile symphony --device headphones --sr 48000 \
  --metadata "Mozart Symphony classical"
python3 Tools/DynamoEQ/dynamo_tone_ai.py classify \
  --features '{"bass_ratio":0.15,"brightness":0.3,"crest_db":14,"zcr":0.06,"dynamic_range_db":18,"speech_likelihood":0.05,"bandwidth_hz":14000,"mid_ratio":0.35}' \
  --metadata "Mozart Piano Concerto"
# Optional developer-side retrain (weights only — no audio written):
python3 Tools/DynamoEQ/dynamo_tone_ai.py train --synthetic --export
python3 Tools/DynamoEQ/dynamo_eq.py symphony --device wireless --path spatialBinaural --sr 48000 < stereo.f32le
python3 Tools/DynamoEQ/dynamo_eq.py process --from-profile cinema --profile symphony \
  --transition-ms 90 --fade-in-ms 120 --sr 48000 < in.f32le > out.f32le
```

### Dynamo as notification **router** → Peek **hub**
- **`DynamoNotificationRouter`** is the single path: widgets · Focus · system apps · API / URL / Shortcuts  
- **Peek hub** presents + stores inbox (queue, unread, replay) — Dynamo owns routing, not a dual banner mirror  
- Per-source toggles in Preferences; **Hub** tray tab + ambient unread badge  
- Message Peeks tint from contact photos  
- API: `dynamo://notify?…` · `DynamoNotificationAPI` → Router → Hub  
- Meeting Mode quiets low/normal peeks; use **Focus** to silence macOS banners for Peek-only  
- Full Disk Access only for system-app ingest

### Calendar & Reminders
- **Full Calendar Access** required to list events (write-only is detected and prompted)  
- Create events / reminders in the notch  

### Focus & Meeting
- **Meeting** — notes, optional Listen, talk tips, volume duck; never auto-joins calls  
- Smart enter/leave suggestions from calendar + call apps  

### Battery
- Hero % + live fill glyph, health, cycles, temp, drain grid  
- **Low · Auto · High** power modes via `pmset` when supported  
- Low-battery Peeks; ambient fill + LPM badge

---

## Requirements

- **macOS 13+** (14.2+ for process-tap visualizer + **local Amplify**)  
- **Xcode 15+** (or recent beta) with macOS SDK when building from source  
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** only if you want the optional WeatherKit app target  

**Permissions (as needed):** Calendar (full), Reminders, Microphone / audio capture (Amplify + peek EQ + Meeting Listen), Speech, Camera (Webcam), **Location (requested on boot for Clocks “Here” + distance sort)**, Automation (transport / playlists for Music & Spotify — **not** required for Amplify EQ).

---

## Build & run

### 1. Daily driver — packaged app (recommended)

```bash
./scripts/package-app.sh          # release → dist/Dynamo.app
./scripts/package-app.sh debug    # debug
open dist/Dynamo.app
```

- Ad-hoc signed; suitable for Launch at Login  
- **Only run `dist/Dynamo.app`** — it owns the single-instance daily driver  
- Embeds `dynamo_eq.py` + `dynamo_tone_ai.py` in Resources when present (optional; embedded EQ + Tone AI curves always work)  
- Production tray **does not** include Weather  
- **Only one Dynamo.app** — remove older `Dynamo 2.app` / `Dynamo 3.app` copies under `dist/` so the notch is not contested  

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
- **Feel & alerts** — collapse delay (incl. 3s snappy / 5s default), Peek, Amplify  
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

**URL scheme:** `dynamo://show` · `mute` · `play` · `shelf` · `calendar` · `notify?title=…` · `peek?title=…`

---

## Architecture

- **`NotchWidgetPlugin`** — every tray widget; hosts never special-case by name  
- **Capabilities** via protocol cast: `NotchAmbientProviding`, `NotchSneakPeekProviding`, `FileDropAccepting`, …  
- **One folder per widget** under `Sources/Dynamo/Widgets/<Name>/`  
- **Data behind protocols** (mock vs real without UI rewrites)  
- **`NotchWindowController`** — collapsed ↔ expanded; peeks/HUD are overlays  
- **`PeekNotificationCenter`** — delivery policy; **`NotchSneakPeekController`** — presentation  
- **`LocalAmplifyEngine`** + **`AmplifyToneAI`** + **`Tools/DynamoEQ/`** — local Amplify DSP + genre Tone AI  
- **`NotchGeometry`** — notch cutout + aspect-adaptive expanded width (cap 1650pt) + notch-aware peek/HUD sizes  

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

Mixed suite — **Python** (DynamoEQ), **Swift** (XCTest), **shell** (sanity):

```bash
./scripts/test.sh           # all
./scripts/test.sh python    # DynamoEQ + Tone AI unit tests
./scripts/test.sh swift     # Package XCTest
./scripts/test.sh shell     # project greps / version / syntax
python3 -m unittest Tests/python/test_dynamo_tone_ai.py -v
```

See **[Tests/README.md](Tests/README.md)** for layout. Manual UI smoke remains in **[docs/SMOKE_TEST.md](docs/SMOKE_TEST.md)**.

```bash
open dist/Dynamo.app
```

Walk **[docs/SMOKE_TEST.md](docs/SMOKE_TEST.md)** and **[docs/PRODUCTION_READINESS.md](docs/PRODUCTION_READINESS.md)**.

Quick checks:

1. One process: `dist/Dynamo.app` only  
2. Hover tray icons → **name preview**; press stays icon-only  
3. **Clocks** present; no Weather tab  
4. Clocks sort: nearest / farthest / random  
5. Media play/pause first-click; Amplify green/red; status like `Impact · Local EQ · Spatial-ready`  
6. Calendar: Full Access → events; empty state is short  
7. Checklist → add reminder  
8. Battery power chips  
9. Focus → Meeting → Leave  
10. `open 'dynamo://notify?title=Test&subtitle=1.0.1'`  

---

## Project layout

```
Sources/Dynamo/
  App/              AppDelegate, Preferences window
  Notch/            Panel, geometry, Peek presentation, tray UX
  Plugins/          Widget protocols + registry
  Support/          Focus, Meeting, PeekNotificationCenter, hotkeys, URLs
  System/           Volume, HUD, launch at login
  Theme/            NotchTheme, live EQ visualizer, chrome
  Widgets/          One folder per widget (incl. WorldClock)
Tools/DynamoEQ/     Pure-Python EQ designer / self-test (no network)
scripts/            package, notarize, dmg, release
docs/               Smoke test, production readiness
dist/               Packaged Dynamo.app (daily driver)
```

---

## History (condensed)

| Phase | Focus |
|-------|--------|
| 1–2 | Notch engine, plugin tray, Media/Calendar/Clipboard/Checklist, Battery, Shelf, HUD, package-app |
| 3–4 | WeatherKit target, peeks, Webcam, helper process, multi-display, release scripts |
| 5–6 | Stability, transport reliability |
| 7 | Focus/Meeting, Sports, System Health, power modes, process-tap visualizer |
| **0.5.x** | Adaptive width, Amplify intents, Peek center, pressable Amplify |
| **1.0.0** | Production without Weather; packaging hardened |
| **1.0.1** | World Clock + distance sort, Preferences, calendar full-access fix, icon-only tray |
| **1.1.1** | DynamoEQ Symphony Amplify (media/quality/note tuning + device path), Spatial/Atmos-safe local EQ |

See [CHANGELOG.md](CHANGELOG.md) for release notes.

---

## Known limitations

- **WeatherKit** needs paid team + Xcode-signed app (not in production tray)  
- **Local Amplify** needs **macOS 14.2+** and audio-capture permission; not a licensed Dolby decoder — it EQs the **post-render** Spatial/Atmos mix  
- **Power modes** may open Battery Settings if `pmset` is blocked  
- **Sports** uses an undocumented free ESPN feed  
- **Notification mirror** is best-effort and may need Full Disk Access  
- Automated UI tests remain thin relative to surface area  

---

## License

MIT — see [LICENSE](LICENSE).
