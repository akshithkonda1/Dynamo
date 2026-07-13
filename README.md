# Dynamo

macOS notch widget dock — a better-architected, better-designed alternative to NotchDock and Boring Notch.

Dynamo turns the MacBook notch into an interactive widget tray with a plugin architecture so widgets are cheap to add or remove.

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

Calendar access is requested on first launch. Grant it under **System Settings → Privacy & Security → Calendars** if prompted. Location (for Weather) is requested the same way — or set a location manually in Settings.

## Architecture principles

- **Every widget conforms to `NotchWidgetPlugin`.** Hosts never special-case a widget by name.
- **Optional capabilities** (e.g. `FileDropAccepting`) are discovered via protocol cast on the registry — still no name switches.
- **One folder per widget** under `Sources/Dynamo/Widgets/<Name>/`.
- **External data sources sit behind a small protocol** so mock and real implementations swap without touching UI.
- **Two-state hover model** for the tray: `NotchWindowController.isExpanded`, driven by an `NSTrackingArea` on the notch (not a global mouse-moved monitor). Hidden↔Peek (top-edge proximity) and transient overlays (System HUD, now-playing sneak peek — both via `presentForOverlay()`/`overlayDidHide()`) are separate layers stacked on top — not extra expansion states.
- **Shared `NotchTheme`** for spacing, type, color roles, and spring motion; panel uses `NSVisualEffectView` vibrancy.
- **Collapsed size is fixed to notch geometry** (`NotchGeometry`), never driven by widget content — a `collapsedView()` must fit within the notch, not push the panel wider. The width is derived from the screen's `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` (the real cutout), with an approximate fallback.

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

**Still deferred:** notarization + a DMG release pipeline (now *possible* since
a paid account exists, but out of scope for the WeatherKit pass) and an app
icon asset catalog.

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

## Next steps (post Phase 3)

- Optional: event-driven peek — let a starting meeting or a severe-weather alert
  peek the notch further or glow, layered on top of the proximity gesture
- Optional: notarization + DMG release pipeline (now possible with a paid account)
- Optional: MediaRemoteAdapter helper process for macOS 15.4+ edge cases
- Optional: AirDrop share action from File Shelf
- Optional: app icon asset catalog
- Optional: webcam mirror widget

## License

MIT — see [LICENSE](LICENSE).
