# Dynamo

**macOS notch dock** — a Dynamic Island–style widget tray for the MacBook notch, built for daily productivity rather than pure visual mimicry.

Dynamo turns the notch into an interactive tray with a plugin architecture (widgets are cheap to add or remove). Alerts surface as **Peeks** in the notch instead of system banners. Everything is on-device by default; free/native Apple frameworks are preferred over paid APIs.

| | |
|---|---|
| **Version** | 0.5.2 |
| **Platform** | macOS 13+ (14.2+ for live process-tap equalizer) |
| **Daily driver** | `dist/Dynamo.app` only (single-instance) |
| **License** | MIT |

> Personal daily-driver project. Prefer free data sources and native frameworks; treat notarization / paid-team WeatherKit as optional infrastructure.

---

## Widgets

Registered in `AppDelegate.bootstrap()`:

| Widget | What it does |
|--------|----------------|
| **Media** | Now playing, transport, scrub, playlists, output device, **Amplify** (green = on / red = off), cover-art equalizer |
| **Calendar** | Upcoming events (EventKit), in-notch **create event**, open Calendar.app |
| **Checklist** | Apple **Reminders** R/W (create / complete / due presets) + local checklist |
| **Clipboard** | Recent snippets |
| **Weather** | WeatherKit forecast (needs paid team + Xcode-signed app for live data) |
| **Battery** | Charge, health, drain estimate; **Low / Auto / High** power modes (`pmset`) |
| **Focus** | Normal · Dynamic · True Focus · **Meeting** companion (notes, talk tips, duck volume) |
| **Sports** | Multi-league scores via free ESPN public CDN (no API key) |
| **System Health** | Local Mac health score + deep links to Settings / updates |
| **Shelf** | Drop files on the notch; open / reveal / AirDrop |
| **Webcam** | Live mirror (incl. Continuity Camera); camera only while the tab is open |

**Background systems (not tray tabs):** Peek notification center, Meeting speech capture (opt-in), global hotkeys, `dynamo://` URL scheme, Peek Bridge for Shortcuts.

---

## Highlights (0.5.x)

### Peek as notification center
All Dynamo-originated alerts go through **`PeekNotificationCenter`**:

- Queue + coalesce by id; media / critical peeks preempt
- Haptics (optional critical sound)
- Calendar lead times, reminder due, battery low, Focus/Meeting offers, media track changes
- External: `dynamo://peek?title=…&subtitle=…` or distributed notification `com.akshithkonda.Dynamo.externalPeek`
- Meeting Mode quiets low/normal peeks; Dynamo does **not** hijack other apps’ Notification Center

### Media Amplify (Dolby-style intents, no volume fader)
Transport-row icon button (same first-click path as play/pause):

- **Green glow** = Amplify on · **Red glow** = off  
- **Presence** — dialogue/air clarity (Vocal Booster / Treble)  
- **Cinema** — perceived loudness contour (Loudness)  
- **Impact** — bass body & punch (Bass Booster / Electronic / Rock)  
- **EQ only** — never raises system volume; re-applies on track/source change  
- Right-click for profile; disabled while Meeting Mode is ducking volume  

### Adaptive island
Expanded width scales with display aspect ratio (min ~540pt, max ~940pt). Active tray tab shows a short label; primary widgets sit left of Focus / tools.

### Focus & Meeting
User-selected modes (Meeting is not a silent auto-overlay):

- **Meeting** — notes, optional Listen (speech), talk tips, volume duck; never joins the call  
- Optional smart enter (calendar “now” + call app) and leave suggestions  
- Call apps: FaceTime, Zoom, Teams, Discord, Slack, Loom, Webex, …  

### Calendar & Reminders
- Create events in the notch (title, duration, start chips, location)  
- Create reminders with due presets: **1h · Today · Tomorrow · None**  

### Battery power modes
**Low · Auto · High** via `pmset` (High when the Mac supports it). Opt-in auto Low Power when unplugged and battery is low.

---

## Requirements

- **macOS 13+** (14.2+ unlocks live Core Audio process-tap EQ; older macOS degrades gracefully)
- **Xcode 15+** (or recent beta) with macOS SDK
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** (`brew install xcodegen`) for the WeatherKit app target
- **Paid Apple Developer membership** — only if you want live **WeatherKit** (not required for Media, Calendar, Focus, etc.)

Permissions (as needed): Calendar, Reminders, Microphone (EQ sample + Meeting Listen), Speech, Camera (Webcam), Location (Weather), Automation (Music / Spotify).

---

## Build & run

Two paths by design:

### 1. Daily driver — packaged app (recommended)

```bash
./scripts/package-app.sh          # release → dist/Dynamo.app
./scripts/package-app.sh debug    # debug
open dist/Dynamo.app
```

- Ad-hoc signed; good for Launch at Login  
- **Only run this `.app`** — Dynamo terminates stray debug/Xcode copies when `dist` launches  
- WeatherKit is **not** available on ad-hoc builds (needs the Xcode target + paid team)

### 2. Swift Package (fast compile / CI)

```bash
export DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer   # if needed
swift build
.build/release/Dynamo   # or .build/debug/Dynamo
```

No entitlements → no live WeatherKit.

### 3. Xcode app target (WeatherKit)

```bash
brew install xcodegen
xcodegen generate          # project.yml → Dynamo.xcodeproj (git-ignored)
open Dynamo.xcodeproj
```

Signing & Capabilities → your **paid** team. WeatherKit is in `Sources/Dynamo/Dynamo.entitlements`.

---

## Settings & shortcuts

**Settings** (gear in tray or menu bar): collapse delay, Hidden mode, display picker, widgets on/off + reorder, Peek duration, Peek delivery / haptics, external Peek bridge, Meeting options.

**Default hotkeys** (⌃⌥ = Control + Option):

| Shortcut | Action |
|----------|--------|
| ⌃⌥D | Show / expand notch |
| ⌃⌥P | Play / pause |
| ⌃⌥M | Mute |
| ⌃⌥S | Focus Shelf |
| ⌃⌥C | Focus Calendar |

**URL scheme:** `dynamo://show` · `mute` · `play` · `shelf` · `calendar` · `peek?title=…&subtitle=…`

---

## Architecture

- **`NotchWidgetPlugin`** — every tray widget; hosts never special-case by name  
- **Capabilities** via protocol cast: `NotchAmbientProviding`, `NotchSneakPeekProviding`, `FileDropAccepting`, …  
- **One folder per widget** under `Sources/Dynamo/Widgets/<Name>/`  
- **Data behind protocols** (mock vs real swap without UI changes)  
- **`NotchWindowController`** — collapsed ↔ expanded; peeks/HUD are overlays, not extra expand states  
- **`PeekNotificationCenter`** — delivery policy (queue); **`NotchSneakPeekController`** — presentation  
- **`NotchTheme`** + **`NotchIconButtonStyle`** — shared chrome; first-click-safe on nonactivating `NSPanel`  
- **`NotchGeometry`** — collapsed size from real notch cutout; expanded size aspect-adaptive  

**SPM vs Xcode:** `Package.swift` = sources + CI; `project.yml` → signed `.app` with entitlements for WeatherKit. Both stay.

---

## Weather (WeatherKit)

Native `WeatherService` — no REST keys. Requires the **Xcode app target** and a **paid team**.

- Location: Core Location, or set a city in **Settings → Weather**  
- Attribution: Apple “Weather” mark + legal link (WeatherKit terms)

If no paid team, Weather soft-fails; other widgets still work. Optional future free providers (e.g. NWS, OpenWeatherMap) can swap behind `WeatherProvider`.

---

## Notarization & release

Optional tooling (no credentials in repo):

| Script | Role |
|--------|------|
| `scripts/package-app.sh` | Ad-hoc `dist/Dynamo.app` |
| `scripts/notarize.sh` | Developer ID + notary + staple |
| `scripts/make-dmg.sh` | DMG with Applications symlink |
| `scripts/release-local.sh` | Package → optional notary → DMG |
| `.github/workflows/release.yml` | Tag `v*` → CI archive / notary / DMG |

See script headers and workflow for env vars / secrets. WeatherKit public builds should export from the **Xcode** Developer ID path, not ad-hoc package alone.

---

## Smoke test

After packaging:

```bash
open dist/Dynamo.app
```

Then walk **[docs/SMOKE_TEST.md](docs/SMOKE_TEST.md)** and **[docs/PRODUCTION_READINESS.md](docs/PRODUCTION_READINESS.md)**.

Quick checks:

1. One process from `dist/Dynamo.app` only  
2. Hover notch → tray expands; active tab labeled  
3. Media: play/pause first-click; Amplify red↔green; skip Peek with art-colored EQ  
4. Calendar **New** → create event  
5. Checklist → add reminder (Tomorrow)  
6. Battery → Low / Auto power chips  
7. Focus → Meeting → duck + notes; Leave  
8. `open 'dynamo://peek?title=Test&subtitle=Bridge'`  

---

## Project layout

```
Sources/Dynamo/
  App/              AppDelegate, Settings
  Notch/            Panel, geometry, Peek presentation
  Plugins/          Widget protocols + registry
  Support/          Focus, Meeting, PeekNotificationCenter, hotkeys, URLs
  System/           Volume, HUD, launch at login
  Theme/            NotchTheme, EQ, chrome
  Widgets/          One folder per widget
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
| 5–6 | Stability, resource audits, transport reliability |
| 7 | Focus/Meeting, Sports, System Health, battery intelligence, Reminders → Checklist, hotkeys, process-tap EQ |
| **0.5.x** | Adaptive width, power modes, in-notch event create, Amplify, Peek notification center, lighter timers, pressable Amplify control |

Older phase detail lives in git history and [CHANGELOG.md](CHANGELOG.md).

---

## Known limitations

- **WeatherKit** needs paid team + Xcode-signed app  
- **Power modes** may open Battery Settings if `pmset` is blocked  
- **Sports** uses an undocumented free ESPN feed; polls while Dynamo runs  
- **Amplify** is Dolby-like *intent* via Music EQ only (presence/cinema/impact) — not system volume, not a licensed Dolby stack. Spotify has no scriptable EQ.  
- **Peek** delivers Dynamo’s alerts only — not other apps’ Notification Center  
- Automated UI tests remain thin relative to surface area  

---

## License

MIT — see [LICENSE](LICENSE).
