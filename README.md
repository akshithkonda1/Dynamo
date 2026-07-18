# Dynamo

macOS notch widget dock — a better-architected, better-designed alternative to NotchDock and Boring Notch.

Dynamo turns the MacBook notch into an interactive widget tray with a plugin architecture so widgets are cheap to add or remove.

**Current version: 0.4.0** (on `main`) — stability, Music/Spotify, Webcam mirror, day-driver UX. See [CHANGELOG.md](CHANGELOG.md) and [PR #5](https://github.com/akshithkonda1/Dynamo/pull/5).

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
| Messages widget | **Live — FDA expected** (reads `chat.db`, replies via AppleScript; Full Disk Access required) |
| Reminders peeks | **Live** (EventKit incomplete reminders due within ~5 min; listed under Calendar expanded view) |
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

## Requirements

- macOS 13+
- Xcode 15+ (or a recent Xcode beta) with the macOS SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to generate the app project
- **A paid Apple Developer membership** for the Weather widget — WeatherKit is not available to Personal Teams. Every other widget still runs ad-hoc / self-signed.

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

Calendar access is requested on first launch. Grant it under **System Settings → Privacy & Security → Calendars** if prompted. Location (for Weather) is requested the same way — or set a location manually in Settings. Messages needs Full Disk Access, which has no in-app request flow — see "Messages setup" below before enabling that widget.

## Architecture principles

- **Every widget conforms to `NotchWidgetPlugin`.** Hosts never special-case a widget by name.
- **Optional capabilities** (e.g. `FileDropAccepting`) are discovered via protocol cast on the registry — still no name switches.
- **One folder per widget** under `Sources/Dynamo/Widgets/<Name>/`.
- **External data sources sit behind a small protocol** so mock and real implementations swap without touching UI.
- **Two-state hover model** for the tray: `NotchWindowController.isExpanded`, driven by an `NSTrackingArea` on the notch (not a global mouse-moved monitor). Hidden↔Peek (top-edge proximity) and transient overlays (System HUD, now-playing sneak peek — both via `presentForOverlay()`/`overlayDidHide()`) are separate layers stacked on top — not extra expansion states.
- **Shared `NotchTheme`** for spacing, type, color roles, and spring motion; panel uses `NSVisualEffectView` vibrancy.
- **Externally-sourced sensitive data is never persisted by Dynamo.** Messages content is re-read from Messages.app's own database on each poll and held only in memory — no local copy in `AppSupportStore`. (Contrast with Clipboard/Checklist/Shelf, which persist happily because that's data the user created *in* Dynamo.)
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

## Messages setup — Full Disk Access (enabled by design)

The Messages widget is registered in the default tray. **Full Disk Access is
required and expected** if you use it. Grant FDA via System Settings (or the
in-app “Open Privacy Settings” button), then quit and relaunch Dynamo.

The Messages widget reads recent iMessage/SMS conversations and lets you
reply, all from the notch. **Understand what it does:**

- **It reads `~/Library/Messages/chat.db` directly** — Messages.app's own
  local SQLite database — read-only, via `ChatDatabaseMessagesProvider`.
  This is the same technique a number of established, non–App-Store Mac
  utilities use; it is not a private/hidden trick, just reading a file you own.
- **It requires Full Disk Access** (System Settings → Privacy & Security →
  Full Disk Access → add Dynamo), because `chat.db` sits behind that
  protection. **This is the broadest permission macOS has** — it grants
  access to your entire filesystem, not just Messages. There is no API for
  Dynamo to request this for you or to scope it down to just this one file;
  granting it is a deliberate action only you can take, and you can revoke it
  at any time in the same System Settings pane. The widget's expanded view
  and its Settings panel both surface the current status and a button that
  jumps straight to that Settings pane.
- **Replies are sent by scripting Messages.app via AppleScript**
  (`MessagesSendService`, `tell application "Messages" to send ... to chat id
  ...`) — the exact same pattern this app already uses to control Music and
  Spotify (`AppleScriptMedia`), and the same sanctioned automation surface
  Apple has shipped in Messages.app's own scripting dictionary for years. The
  recipient receives a completely ordinary message; nothing about delivery is
  different from typing it into Messages.app yourself. macOS will prompt for
  **Automation** access (System Settings → Privacy & Security → Automation)
  the first time you actually send a reply — that prompt is the OS, not Dynamo.
- **Nothing is persisted.** Unlike Clipboard/Checklist/Shelf, message content
  is never written to Dynamo's own storage — it's re-read from chat.db on
  each ~5s poll and held only in memory. The source of truth stays exactly
  where you already trust it.
- **Event-driven peek:** a new incoming message (from anyone, not just the
  open conversation) briefly peeks the notch with the sender and preview text,
  the same mechanic as the Calendar/Weather peeks.

**Unverified like the rest of this app's newest work** — written and pushed
from a Linux environment with no macOS, no Messages.app, and no real chat.db
to test against. The chat.db schema is stable but entirely
Apple-undocumented, and message-text storage changed around macOS Ventura
(many rows now store an archived `NSAttributedString` in `attributedBody`
instead of plain `text`, which this implementation decodes — see the doc
comment in `ChatDatabaseMessagesProvider.swift`). Treat the exact SQL and
column semantics as best-effort against a community-documented, not
Apple-documented, format, and verify against your own Messages history before
relying on it.

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
- **Messages + Full Disk Access is in-scope:** grant FDA, relaunch, verify read + reply. FDA is intentional for this feature (whole-disk access; revoke anytime in System Settings).

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

## Next steps (post Phase 5)

- Optional: paid-team WeatherKit cold-start verification (left alone by design for now)
- Optional: further icon polish by a designer (the current one is a generated placeholder)
- Optional: more event sources (e.g. Focus / Screen Time, a Reminders due date)
- Optional: MediaRemoteAdapter helper process verification on a real Mac —
  confirm the `project.yml` postbuild script actually copies and signs the
  binary into `Contents/MacOS/`
- Optional: multi-display picker for which screen hosts the notch panel

## License

MIT — see [LICENSE](LICENSE).
