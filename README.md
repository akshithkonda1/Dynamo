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
| Stocks | **Live** (Finnhub; local API key) |
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

## Requirements

- macOS 13+
- Xcode 15+ (or a recent Xcode beta) with the macOS SDK
- Ad-hoc / self-signing only — no paid Apple Developer account required

## Build & run

```bash
# If you use an Xcode beta outside /Applications:
export DEVELOPER_DIR=/path/to/Xcode-beta.app/Contents/Developer

swift build
.build/debug/Dynamo
```

### Packaged `.app` (recommended for Launch at Login)

```bash
./scripts/package-app.sh          # release
./scripts/package-app.sh debug    # debug
open dist/Dynamo.app
```

The script produces an ad-hoc signed `dist/Dynamo.app`. No paid Developer ID required.

Calendar access is requested on first launch. Grant it under **System Settings → Privacy & Security → Calendars** if prompted.

## Architecture principles

- **Every widget conforms to `NotchWidgetPlugin`.** Hosts never special-case a widget by name.
- **Optional capabilities** (e.g. `FileDropAccepting`) are discovered via protocol cast on the registry — still no name switches.
- **One folder per widget** under `Sources/Dynamo/Widgets/<Name>/`.
- **External data sources sit behind a small protocol** so mock and real implementations swap without touching UI.
- **Two-state hover model** only: `NotchWindowController.isExpanded`. System HUD is a separate temporary overlay, not a third expansion state.
- **Shared `NotchTheme`** for spacing, type, color roles, and spring motion; panel uses `NSVisualEffectView` vibrancy.

## Architecture decision: Swift Package vs `.xcodeproj` app target

**Decision (current): stay a Swift Package executable**, plus an optional packaging script that wraps the binary in an ad-hoc signed `.app`.

Reasons:

- Faster iteration and a single `Package.swift` source of truth.
- Info.plist is embedded via a linker section for bare-binary runs; the packaging script copies the same plist into `Contents/Info.plist`.
- No paid distribution / notarization path yet.

**Revisit when:** shipping a proper app icon asset catalog, notarization, or entitlements that need a real Xcode app target.

## Stocks API key setup (Finnhub)

**Why Finnhub:** free tier is ~60 calls/minute — enough for a 60s refresh of a small watchlist.

1. Register at [finnhub.io/register](https://finnhub.io/register) and copy your free API key.
2. Store it **outside git**:
   - File: `~/Library/Application Support/Dynamo/finnhub_api_key` (single line), or
   - Environment variable: `FINNHUB_API_KEY=...`
3. Relaunch Dynamo. Default watchlist: `AAPL`, `MSFT`, `GOOGL`.

## Next steps (post Phase 2)

- Optional: MediaRemoteAdapter helper process for macOS 15.4+ edge cases
- Optional: AirDrop share action from File Shelf
- Optional: app icon asset + DMG release pipeline
- Optional: webcam mirror widget
- Optional: notch width fine-tuning per display model

## License

MIT — see [LICENSE](LICENSE).
