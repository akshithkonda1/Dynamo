# Dynamo

macOS notch widget dock — a better-architected, better-designed alternative to NotchDock and Boring Notch, built on the same "Dynamic Island for the notch" concept and pushed hard toward daily productivity and general usefulness rather than pure visual mimicry.

Dynamo turns the MacBook notch into an interactive widget tray with a plugin architecture so widgets are cheap to add or remove.

**This is a personal daily-driver project, not a packaged release.** That shapes several real decisions documented below: prefer free/no-cost data sources and native Apple frameworks where one exists, accept a well-understood trade-off (an undocumented but free feed, a manual permission tap) over adding cost or complexity, and treat notarization/paid-team signing as optional infrastructure to enable later rather than a blocker now.

Originally scoped to a handful of core widgets (Media, Calendar, Clipboard, Checklist), the tray has grown to 11 registered widgets plus several background systems (Focus modes, Meeting Mode, global hotkeys, a `dynamo://` URL scheme). See **Phase 7 onward** below for everything added since Phase 6.1 — Phases 1–6.1 are the original build-out and stability audits; nothing in this file is fictional or aspirational, it's all read from the current `Sources/` tree.

## Widgets (11, currently registered in `AppDelegate.bootstrap()`)

Media · Calendar · Clipboard · Checklist (now a Reminders front-end) ·
Weather · Battery · Focus · Sports · System Health · Shelf · Webcam.

Plus background systems that aren't tray tabs themselves: Meeting Mode
(layered on Focus), global hotkeys, the `dynamo://` URL scheme, and the Peek
Bridge. See **Phase 7** in the status history below for what each new one
does and why.

## Status

### Phase 1 — foundation & core widgets

| Area | State |
|------|--------|
| Notch window engine (collapsed / expanded) | **Live** |
| Plugin architecture (`NotchWidgetPlugin`) | **Live** |
| Media Controls | **Live** (MediaRemote + AppleScript fallback) |
| Calendar | **Live** (EventKit) |
| Clipboard / Snippets | **Live** |
| Checklist | **Live** (with drag reorder) |
| ~~Stocks~~ | Removed in Phase 3 — replaced by the Weather widget |
| Settings (reorder / toggle) | **Live** |
| Visual polish (vibrancy, theme, spring) | **Live** |

### Phase 2 — productization & Boring Notch parity gaps

| Area | State |
|------|--------|
| Battery widget | **Live** (IOKit power sources) |
| File Shelf | **Live** (drop files on notch; open / reveal / clear) |
| Volume & brightness HUD | **Live** (media-key triggered notch meter) |
| Launch at Login | **Live** (SMAppService; best with packaged `.app`) |
| Ad-hoc `.app` packaging | **Live** (`scripts/package-app.sh`) |
| ~~AI assistant (xAI Grok)~~ | Removed in Phase 3 — didn't earn its tray slot |

### Phase 3 — WeatherKit & peek-a-boo

| Area | State |
|------|--------|
| Xcode app target + WeatherKit signing (XcodeGen) | **Live** (`project.yml`; resolves the old build-wrapper decision) |
| Weather widget (WeatherKit + CoreLocation) | **Live** (auto-location or manual city, today's H/L, severe-weather alerts, Apple attribution) |
| Per-widget Settings (`WidgetSettingsProviding`) | **Live** (generic — Settings never names a widget) |
| Peek-a-boo Hidden mode | **Live** (opt-in; top-edge `NSTrackingArea` sensor reveals the notch, retreats after a short delay) |
| Collapsed state hugs the physical notch | **Live** (`NotchGeometry`: collapsed panel sized to `safeAreaInsets` height + the real cutout width from `auxiliaryTop*Area`, so it disappears into the notch at rest; HUD widens Dynamic-Island style) |
| Settings window redesign | **Live** (larger, scrollable, card-sectioned — General / Widgets / per-widget config all visible at once) |
| Now-playing notch (Boring Notch–style) | **Live** (idle: album art + dancing-bars visualizer either side of the camera when playing, via a generic `NotchAmbientProviding` capability; expanded: wider ~640pt welcoming media player) |
| Now-playing sneak peek | **Live** (brief title/artist pill on track change, via a generic `NotchSneakPeekProviding` capability; reuses the volume/brightness HUD's transient-overlay mechanic) |
| Frontend polish pass | **Live** (removed dead `collapsedView()` across every widget; unified all widgets onto `NotchTheme` color/type tokens; shared `NotchIconButtonStyle` hover+press treatment on every utility button and the tray selector row) |

### Phase 4 — event-driven peek & beyond

| Area | State |
|------|--------|
| Event-driven peek: meeting reminder | **Live** (Calendar peeks ~5 min before a non-all-day event starts, once per event) |
| Event-driven peek: severe weather | **Live** (Weather peeks on a new severe/extreme alert — `.critical` emphasis: warning-colored glow, longer dwell time) |
| AirDrop share action (File Shelf) | **Live** (per-item share button via `NSSharingService(named: .sendViaAirDrop)`) |
| Webcam mirror widget | **Live** (`AVCaptureSession` + `AVCaptureVideoPreviewLayer`; camera runs only while the Webcam tab is actually visible — started/stopped by the view's appear/disappear, never by app launch or plugin registration) |
| App icon asset catalog | **Live** (`Assets.xcassets/AppIcon.appiconset` for the Xcode target + `AppIcon.icns` for `package-app.sh`'s ad-hoc build; **placeholder artwork** — a dark rounded-square with a notch silhouette and an accent spark, not a design pass) |
| MediaRemoteAdapter helper process | **Live** (`DynamoMediaRemoteHelper` — multi-path discovery, live publish, auto-restart; embedded by Xcode postbuild + `package-app.sh`; verified present in packaged `.app`) |
| Notarization + DMG release pipeline | **Live, needs your Apple Developer credentials** (`scripts/release-local.sh`, `notarize.sh`, `make-dmg.sh`, `.github/workflows/release.yml`) |
| Reminders peeks | **Superseded** — restored in Phase 6.1 via a dedicated reminders-only `EKEventStore` inside `LocalCalendarDatabaseProvider`, living in the Calendar tab. Phase 7 moved Reminders out of Calendar entirely and merged it into the Checklist widget instead (see **Phase 7 — Checklist becomes a Reminders front-end** below); `CalendarProvider` no longer has any reminders properties. |
| Multi-display picker | **Live** (Settings → General → Display for notch) |
| App icon | **Live** (regenerated notch/island mark for asset catalog + `.icns`) |

### Phase 5 — stability, consistency & resource efficiency

A dedicated audit pass, not a feature pass. Every timer, poll loop, monitor
token, and notification registration in the app was re-read end to end to
separate real leaks/waste from patterns that only look concerning at a glance.

| Area | State |
|------|--------|
| Leaked global event monitor (`SystemHUDController`) | **Fixed** — `NSEvent.addGlobalMonitorForEvents`'s return value was previously discarded, so `teardown()` could never remove it; the volume/brightness key monitor leaked for the life of the process. Token is now captured and removed alongside the local monitor. |
| Dead notification registration (`MediaRemoteNowPlayingProvider`) | **Fixed** — every MediaRemote notification name was registered on both `DistributedNotificationCenter` and plain `NotificationCenter`. MediaRemote only ever posts distributed (poster is Music/Spotify, a different process), so the local registration was a permanent no-op doubling observer bookkeeping. Removed. |
| Redundant SQLite connections (`ChatDatabaseMessagesProvider`) | **Fixed** — `refresh()` opened and closed three separate connections to `chat.db` per poll tick (conversations, messages, latest-incoming). Now one connection shared across all three queries per cycle. Poll interval also raised 5s → 10s, still well below Calendar's 60s / Battery's 30s, against a database another process is actively writing to. |
| Retain-cycle sweep | **Checked, none found** — every `Timer.scheduledTimer` and `DispatchWorkItem` closure in the codebase already captures `self` weakly. |
| Clipboard poll (`ClipboardStore`, 0.5s) | **Reviewed, unchanged** — already cheap (`NSPasteboard.changeCount` comparison; real work only fires on an actual change). |
| Weather location fetch (`WeatherKitWeatherProvider`) | **Reviewed, unchanged** — one-shot `requestLocation()`, not continuous tracking. |
| Webcam capture teardown (`WebcamCaptureController`) | **Reviewed, unchanged** — `AVCaptureSession.stopRunning()` already releases the real (camera hardware) resource on view disappearance. |
| Checklist item growth (`ChecklistStore`) | **Reviewed, intentionally left uncapped** — unlike Clipboard (20-item cap) and Shelf (24-item cap), checklist items are explicit user-authored to-dos with no implicit expiry. Silently evicting old ones would be data loss, a worse outcome than the unbounded (and in practice small) growth of a personal to-do list. |

### Phase 6 — post-merge bug sweep

A second pass after the Calendar/Music/Permissions rewrite (real Calendar
database reads, absolute play/pause, scrubbable timeline, playlist switching,
remembered permissions) landed and the Messages widget was removed.

| Area | State |
|------|--------|
| Redundant Spotify artwork fetches (`AppleScriptMedia`) | **Fixed** — before a track's artwork finished its async fetch, every ~1s poll re-issued both the AppleScript "artwork url" query and a fresh network download for the same image. Now guarded by an in-flight set (`pendingSpotifyArtworkKeys`) so only one fetch runs per track. |
| Unbounded helper-process restart loop (`MediaRemoteHelperProcess`) | **Fixed** — a helper binary that crashed immediately on every launch would relaunch every 2s forever. Now gives up after 5 consecutive crashes that each ran under 3s, falling back to the existing MediaRemote/AppleScript tiers for the rest of the session. |
| Tray-row first click (`TrayIconButton` in `NotchContentView`) | **Fixed** — the widget-switcher and Settings-gear buttons used `Image` + `.onTapGesture`, the exact pattern the codebase's own transport-button fix already identified as unreliable on a nonactivating panel ("first click focuses, second click presses"). Converted to a real `Button` with the shared `.notchIcon` style, consistent with the transport row. |
| Full calendar DB copy every 30s (`LocalCalendarDatabaseProvider`) | **Fixed** — `refresh()` unconditionally copied the entire `Calendar.sqlitedb` (+ WAL/SHM) to a temp file every poll tick regardless of whether Calendar had written anything. Now compares an mtime+size fingerprint of the source (including the `-wal` sidecar, since WAL-mode writes land there first) and reuses the existing snapshot when unchanged. A cheap open/close read-check still runs every cycle regardless, so a Full-Disk-Access revocation is still caught within one tick — only the expensive full-file copy is skipped, not the permission check. |
| Reminders status corrected in this README | **Fixed** — see the Phase 4 entry above; it claimed live EventKit reminders that the current default provider doesn't produce. |

### Phase 6.1 — Reminders due-date peeks (restored, then superseded)

`NSRemindersUsageDescription` / `NSRemindersFullAccessUsageDescription` were
already declared in `Info.plist` from before Phase 6 disconnected reminders —
this wired the feature back up properly rather than leaving the strings
orphaned.

**Historical — this table describes Phase 6.1's implementation, not current
behavior.** Phase 7 replaced this whole approach; see **Phase 7 — Checklist
becomes a Reminders front-end** below for what's actually live today.

| Area | State (as of Phase 6.1, now superseded) |
|------|--------|
| Reminders access | `LocalCalendarDatabaseProvider` gained a second, reminders-only `EKEventStore` (`requestRemindersAccess()`), entirely separate from Calendar's own file-based access. A Calendar-DB read failure no longer cleared already-fetched reminders and vice versa — they were independent `CalendarProvider` properties (`authorizationState` vs `remindersAuthState`) with independent failure/retry paths. |
| No-launch-prompt guarantee | `refresh()` only ever called the passive `EKEventStore.authorizationStatus(for: .reminder)` (never prompted); the real system dialog fired only from `requestRemindersAccess()`, wired to an explicit "Allow Reminders" button in the Calendar tab's expanded view. |
| Settings visibility | Added `.reminders` to `PermissionsStore`'s `DynamoPermission` enum. |

### Phase 7 — Focus & Meeting Mode

A background system, not a widget: it changes how the rest of the tray
behaves rather than adding its own tray tab (the Focus **widget** below is a
thin front-end onto it).

| Area | State |
|------|--------|
| `FocusController` | **Live** — a singleton owning one of four modes (`.normal` / `.dynamic` / `.trueFocus` / `.meeting`), persisted via `UserDefaults`. Everything else in this section reads its current mode; nothing about it is AI-driven. |
| `FocusQuietMonitor` | **Live** — uses `ProcessInfo.isLowPowerModeEnabled` as an honest, documented **proxy** for "Focus is probably on," because macOS does not expose a public API for actual Focus/Do Not Disturb status. Peeks go quieter while the proxy is active. No private APIs, no plist scraping. |
| `FocusAgendaEngine` ("True Focus" mode) | **Live** — builds a daily agenda purely from Calendar + Reminders + local Checklist items already available to the app, and fires prep/end-of-block peeks roughly 30 minutes before and after each block. No external scheduling service involved. |
| `DynamicCompanion` ("Dynamic" mode) | **Live** — deterministic, rule-based nudges: a next-event pulse every ~45 minutes, an overdue-reminder peek, and a one-shot "coding tool is frontmost → checklist nudge" using a small bundle-ID allowlist. Zero AI, zero heuristics beyond simple thresholds. |
| Meeting Mode (`FocusController.meeting` + `MeetingMode` facade) | **Live** — the old standalone `MeetingMode` type is now a thin facade delegating to `FocusController`, kept for call-site compatibility. |
| `MeetingSpeechCapture` | **Live, opt-in, mic active only while listening** — on-device-preferred `SFSpeechRecognizer` (`requiresOnDeviceRecognition = true` where supported) over an `AVAudioEngine` tap. Nothing is transcribed unless a meeting is actively being captured. |
| `MeetingNotesStore` | **Live** — meeting notes persist as local-only JSON in Application Support. No network calls anywhere in this path. |
| `MeetingTalkCoach` | **Live** — local, keyword-based "what to say next" suggestions (standup / 1:1 / interview / demo playbooks). Not a model call — a lookup table. |
| `MeetingVolumeDucker` | **Live** — saves the current system volume and ducks it to a target level (default 25%) for the duration of a meeting, restoring it afterward. |
| `CallSessionProbe` | **Live** — polls `NSWorkspace.runningApplications` every ~2s against an allowlist of FaceTime/Zoom/Teams/Skype/Webex bundle IDs to *suggest* Meeting Mode. It never auto-joins a call or changes mode without you confirming. |

### Phase 7 — Sports, System Health & Battery Intelligence

Three new widgets, all read-only with respect to the system (System Health
and Battery can *suggest* actions — open System Settings, confirm a restart —
but never act without you clicking through).

**Sports** — `SportsPlugin` / `SportsStore` / `ESPNScoreboardClient`.
Follows multiple leagues, aggregates live scores, supports category filters.
Data comes from ESPN's public scoreboard feed
(`site.api.espn.com/apis/site/v2/sports/{path}/scoreboard`) — an
**undocumented but free, no-API-key** endpoint. This was a deliberate choice,
not an oversight: Dynamo is a personal project with a hard preference for
zero-cost data sources, and **Apple does not publish a developer-facing
Sports/live-scores API or framework** — the "Apple Sports" app is not backed
by anything third-party macOS software can call. Given that constraint,
ESPN's free feed is close to the only zero-cost option, and the UI is upfront
about it (the subtitle says "free ESPN feed," not something implying an
official partnership). The one known trade-off worth naming plainly: the
background poll timer starts at plugin registration (app launch), not gated
to "Sports tab open" the way Webcam's camera capture is — so it polls in the
background for as long as Dynamo runs, unlike the on/off pattern used
elsewhere in the tray. Accepted for now given the endpoint is free either way;
worth revisiting if ESPN ever rate-limits or the polling cost becomes worth
gating.

**System Health** — `SystemHealthPlugin` / `MacHealthModel` /
`SoftwareUpdateProvider` / `MacHealthActions`. A weekly, locally-generated
report (0–100 composite score) from read-only system metrics: disk free
(`attributesOfFileSystem`), uptime (`sysctlbyname("kern.boottime")`), thermal
state (`ProcessInfo.thermalState`), memory pressure (raw
`host_statistics64`/Mach calls), and pending Apple software updates (shelling
out to `/usr/sbin/softwareupdate -l`, polled every 12h with a 30-minute
minimum cooldown between checks). Every remediation is a deep link — System
Settings, Activity Monitor, a restart-confirmation dialog — never an
automatic install or forced restart.

**Battery Intelligence** — `BatteryHealthModel` / `BatteryHistoryStore` /
`BatteryPowerMode`. A composite battery-health score from IOKit hardware
capacity plus a local drain-rate history (capped at 2,500 samples, sampled no
more than every 4 minutes), with a linear-fit drain/charge-rate prediction —
all computed on-device; no data leaves the Mac. `BatteryPowerMode` reads and
toggles system Low Power Mode via `pmset -b/-a lowpowermode` (no `sudo`
needed for your own power source) and offers an opt-in-by-default policy to
auto-enable Low Power Mode at ≤20% battery.

### Phase 7 — Checklist becomes a Reminders front-end

Supersedes Phase 6.1's Calendar-tab Reminders integration above — Reminders
now lives entirely under Checklist, with full read/write access rather than
peeks-only.

| Area | State |
|------|--------|
| Dual composer (`DraftTarget`) | **Live** — Checklist's compose UI is a segmented control: `.reminders` (default) or `.local`. New items go to whichever is selected. |
| `RemindersProvider` | **Live** — a full read/write EventKit integration (create, complete, uncomplete, update title, set due date, delete) on its own `EKEventStore`, separate from Calendar's. Polls every 30s and also observes `.EKEventStoreChanged` for near-immediate updates; in-flight fetches are properly cancelled via `cancelFetchRequest` rather than left to race. |
| Old Calendar-tab reminders path | **Removed** — `CalendarProvider` no longer declares `dueReminders` or `remindersAuthState` at all; that surface moved here wholesale. |

### Phase 7 — Automation & external control

| Area | State |
|------|--------|
| Global hotkeys (`GlobalHotKeys`) | **Live** — real Carbon `RegisterEventHotKey`/`InstallEventHandler`, not a global `NSEvent` monitor (consistent with the anti-polling discipline elsewhere in this codebase). Default bindings: ⌃⌥D show, ⌃⌥P play/pause, ⌃⌥M mute, ⌃⌥S focus Shelf, ⌃⌥C focus Calendar. Registration conflicts are reported rather than silently swallowed. |
| `dynamo://` URL scheme (`DynamoURLRouter`) | **Live** — `dynamo://show`, `mute`, `play`, `shelf`, `calendar`, `peek?title=…&subtitle=…`. Handled in `AppDelegate.application(_:open:)`. |
| Peek Bridge (`PeekBridge`) | **Live, opt-in, off by default** — lets an external script or Shortcut post a peek via `DistributedNotificationCenter` (`com.akshithkonda.Dynamo.externalPeek`) or the `dynamo://peek` URL. Must be explicitly enabled in Settings → General; nothing listens until you turn it on. |

### Phase 7 — Audio-reactive visuals

| Area | State |
|------|--------|
| `MusicAudioSampler` | **Live on macOS 14.2+, gracefully degrades below it** — real-time 36-band FFT spectrum analysis plus beat/BPM onset detection, sourced from the actual playing app's audio (Music, Spotify, browsers, Discord, Slack, etc.) via Core Audio process taps (`CATapDescription`, `AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice`) — a macOS 14.2 API. Runs a ~60fps analysis loop on its own `DispatchQueue` with adaptive gain control. On older systems the visualizer falls back to a static state with a plain "Needs macOS 14.2+ for live audio" message rather than a crash or a fake animation. Because process taps share the same TCC gate as microphone recording, this requests mic permission (`AVCaptureDevice.requestAccess(for: .audio)`) even though it never records — worth knowing before you wonder why Dynamo asks for the microphone. |
| `AudioOutputController` | **Live** — enumerates Core Audio output devices and sets `kAudioHardwarePropertyDefaultOutputDevice`; surfaced as an output-device picker in the Media widget. |
| Supporting visual layer (`AuroraEqualizerView`, `CoverArtPalette`, `DynamicChrome`, `MediaPeekPulse`, `NotchChrome`) | **Live** — cover-art-derived color palette, chrome/pulse treatments for the now-playing peek and ambient view. |

## Requirements

- macOS 13+ (macOS 14.2+ additionally unlocks the live audio-reactive equalizer via Core Audio process taps — see *Phase 7 — Audio-reactive visuals*; on older macOS it degrades gracefully to a static state instead of failing)
- Xcode 15+ (or a recent Xcode beta) with the macOS SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to generate the app project
- **A paid Apple Developer membership, only if you want the Weather widget** — WeatherKit is not available to Personal Teams. This isn't a hard requirement of the project: Dynamo is a personal, unreleased daily driver, so paying for a developer account purely to unlock one widget isn't assumed. If a paid account gets set up anyway (for unrelated reasons), Weather stays on WeatherKit; otherwise the plan is to swap it for a free, key-light alternative (see *Weather setup*). Every other widget runs ad-hoc / self-signed with no paid account at all.

## Build & run

There are two build paths, by design (see the architecture note below).

**1. Xcode app target (required for the Weather widget / WeatherKit).**

```bash
brew install xcodegen
xcodegen generate          # reads project.yml → Dynamo.xcodeproj (git-ignored)
open Dynamo.xcodeproj
```

In Xcode → **Signing & Capabilities**: enable **Automatically manage signing**
and select your **paid** team. The WeatherKit capability is carried by
`Sources/Dynamo/Dynamo.entitlements`; Xcode registers the App ID service for
you. Then build & run (⌘R).

**2. Swift Package (fast source-only iteration / CI, no WeatherKit at runtime).**

```bash
# If you use an Xcode beta outside /Applications:
export DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer

swift build
.build/debug/Dynamo
```

The bare SPM binary compiles every widget but runs without entitlements, so the
Weather widget can't fetch live data from it — use the Xcode target for that.

### Packaged `.app` (Launch at Login, non-WeatherKit ad-hoc runs)

```bash
./scripts/package-app.sh          # release
./scripts/package-app.sh debug    # debug
open dist/Dynamo.app
```

The script produces an ad-hoc signed `dist/Dynamo.app` — good for Launch at
Login and every widget **except** Weather (ad-hoc signing can't carry the
WeatherKit entitlement; build the Xcode target for that).

Calendar may need **Full Disk Access** (Dynamo reads Calendar.app’s database read-only). Location (for Weather) is requested on first use — or set a location manually in Settings.

## Architecture principles

- **Every widget conforms to `NotchWidgetPlugin`.** Hosts never special-case a widget by name.
- **Optional capabilities** (e.g. `FileDropAccepting`) are discovered via protocol cast on the registry — still no name switches.
- **One folder per widget** under `Sources/Dynamo/Widgets/<Name>/`.
- **External data sources sit behind a small protocol** so mock and real implementations swap without touching UI.
- **Two-state hover model** for the tray: `NotchWindowController.isExpanded`, driven by an `NSTrackingArea` on the notch (not a global mouse-moved monitor). Hidden↔Peek (top-edge proximity) and transient overlays (System HUD, now-playing sneak peek — both via `presentForOverlay()`/`overlayDidHide()`) are separate layers stacked on top — not extra expansion states.
- **Shared `NotchTheme`** for spacing, type, color roles, and spring motion; panel uses `NSVisualEffectView` vibrancy.
- **Shared `NotchIconButtonStyle`** (`.buttonStyle(.notchIcon(...))`) for every small utility button (delete, pin, reveal, clear, transport, refresh) — one hover-highlight + press-scale treatment, not each widget hand-rolling its own.
- **Collapsed size is fixed to notch geometry** (`NotchGeometry`), never driven by widget content — an `ambientView()` (see `NotchAmbientProviding`) must fit within the notch, not push the panel wider. The width is derived from the screen's `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` (the real cutout), with an approximate fallback.

## Architecture decision: Swift Package vs `.xcodeproj` app target — **resolved**

The original note flagged "entitlements that need a real Xcode app target" as
the trigger to revisit staying a pure Swift Package. **WeatherKit is that
trigger**, so as of Phase 3 there is a real Xcode app target.

**Decision (current): both, with clear roles.**

- **`project.yml` (XcodeGen) → `Dynamo.xcodeproj`** is the shippable target. It
  produces a properly signed `.app` bundle that carries `Info.plist` and
  `Sources/Dynamo/Dynamo.entitlements` (WeatherKit) — something the old linker
  `-sectcreate __TEXT __info_plist` trick could never do for an *entitlement*.
  The generated `.xcodeproj` is git-ignored and regenerated from the spec.
- **`Package.swift`** stays as the single source of truth for the source list,
  used for fast `swift build` compile checks and CI. The `-sectcreate` linker
  flag has been retired now that a real bundle exists.

**Now resolved too:** notarization + a DMG release pipeline, and an app icon
asset catalog — both landed in Phase 4 (see below).

## Weather setup (WeatherKit)

The Weather widget uses Apple's **WeatherKit** through the native Swift API
(`WeatherService.shared.weather(for:)`) — no REST/JWT keys to manage. It does
require the **Xcode app target** and a **paid Apple Developer team** (see
*Build & run*), because WeatherKit is entitlement-gated.

- **Location:** automatic via CoreLocation by default — grant *Location* on
  first launch. Prefer not to share location, or want a different place? Set a
  city in **Settings → Weather**; Dynamo geocodes the name to coordinates and
  never touches CoreLocation.
- **Expanded view:** current conditions, today's high/low, and any severe-weather
  alerts.
- **Attribution:** Apple's "Weather" mark and a legal link appear in the expanded
  panel. This is a **hard requirement** of the WeatherKit terms, not a polish item.

**Why Weather replaced Stocks:** the same tray slot now leans on a first-party,
key-free Apple framework instead of a third-party quote API that needed a
manually-provisioned Finnhub key.

**Open decision — WeatherKit's future is tied to an unrelated purchase, not
to this project.** A paid Apple Developer membership is being considered for
a separate project; if that happens, it covers every app under the same
membership and Weather keeps WeatherKit at no extra cost. If it doesn't
happen, Weather is not worth paying $99/year for on its own, and the plan is
to swap the provider behind `WeatherProvider` for a free alternative —
candidates being the US National Weather Service (`api.weather.gov`, free,
no key, official, but US-only) or OpenWeatherMap (free tier, worldwide,
needs an API key). Nothing about this is decided or implemented; it's called
out here so it isn't lost.

## Notarization & DMG releases

Three pieces, none of which carry any credentials — they're tooling that
activates once **you** supply your own Apple Developer Program certificate and
notary credentials:

- **`scripts/notarize.sh`** — re-signs an ad-hoc `package-app.sh` build with a
  `Developer ID Application` identity, submits it to Apple's notary service,
  and staples the ticket. Reads `DEVELOPER_ID_IDENTITY` plus either a notary
  API key (`NOTARY_KEY_ID`/`NOTARY_ISSUER_ID`/`NOTARY_KEY_PATH`) or an Apple ID
  + app-specific password (`NOTARY_APPLE_ID`/`NOTARY_TEAM_ID`/`NOTARY_APP_PASSWORD`)
  from your environment. Note: the ad-hoc build has no WeatherKit entitlement
  (see *Build & run*) — for a release with a working Weather widget, notarize
  an `.app` exported from the Xcode target instead (`xcodebuild -exportArchive`
  with `method: developer-id`), which is what the CI workflow below does.
- **`scripts/make-dmg.sh`** — packages a built `.app` into a `.dmg` with a
  drag-to-`/Applications` symlink, via `hdiutil` (no third-party tools needed).
- **`.github/workflows/release.yml`** — the full automated pipeline: builds the
  Xcode target, imports a Developer ID certificate from repo secrets into a
  temporary CI keychain, archives, exports, notarizes, staples, packages the
  DMG, and attaches it to a GitHub Release. Fires on `v*` tags. Requires these
  **repository secrets** (Settings → Secrets and variables → Actions) —
  without them the workflow simply fails at the signing step, nothing
  insecure or silently degraded:

  | Secret | What it is |
  |---|---|
  | `DEVELOPER_ID_CERTIFICATE_P12` | base64 of your exported `Developer ID Application` cert (`base64 -i cert.p12 \| pbcopy`) |
  | `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the password set when exporting it |
  | `DEVELOPER_ID_TEAM_ID` | your 10-character Apple Developer Team ID |
  | `NOTARY_APPLE_ID` | Apple ID email for `notarytool` |
  | `NOTARY_APP_PASSWORD` | an app-specific password (generate at appleid.apple.com) |

**Unverified, like everything else Apple-credential-shaped in this repo:**
written and pushed from an environment with no macOS, Xcode, or Apple account
access. The individual steps mirror Apple's own documented codesign-import /
archive / notarytool flow — treat the first real tag push as the test.

## Smoke test

After building, run through **[docs/SMOKE_TEST.md](docs/SMOKE_TEST.md)** before treating a build as daily-driver ready.

- WeatherKit / paid-team signing can be soft-failed when testing ad-hoc builds.
- Calendar may need Full Disk Access for the local database path; grant only if events don’t load.

## Local release (DMG)

```bash
# Ad-hoc package + DMG (no notary credentials required):
./scripts/release-local.sh --skip-notary

# Full Developer ID re-sign + notarize + DMG (needs env vars — see scripts/notarize.sh):
export DEVELOPER_ID_IDENTITY="Developer ID Application: …"
export NOTARY_APPLE_ID=… NOTARY_TEAM_ID=… NOTARY_APP_PASSWORD=…
./scripts/release-local.sh
```

WeatherKit-signed public releases should use the Xcode export path / GitHub Actions workflow with your paid team secrets.

## Next steps (post Phase 7)

- Open decision: keep WeatherKit (if a paid Developer account materializes for
  another project) or swap Weather to a free provider like `api.weather.gov` /
  OpenWeatherMap — see *Weather setup* above. Not urgent; the widget works
  today.
- Known, accepted trade-off: Sports polls ESPN's free scoreboard feed on an
  unconditional background timer from app launch rather than gated to
  "Sports tab open." Left as-is for now since the feed is free regardless of
  poll rate; worth revisiting only if that changes.
- Test coverage is thin relative to the codebase's size (one test file across
  ~19k lines of source) — the widest gap for anyone treating this as
  production-ready rather than a personal daily driver.
- Optional: further icon polish by a designer (the current one is a generated placeholder)
- Optional: more event sources (e.g. Focus / Screen Time — no stable public API for either as of this writing)
- Optional: MediaRemoteAdapter helper process verification on a real Mac —
  confirm the `project.yml` postbuild script actually copies and signs the
  binary into `Contents/MacOS/`
- Optional: paid-team WeatherKit cold-start verification, if WeatherKit stays (left alone by design for now)

## License

MIT — see [LICENSE](LICENSE).
