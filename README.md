# Dynamo

macOS notch widget dock — a better-architected, better-designed alternative to NotchDock and Boring Notch.

Dynamo turns the MacBook notch into an interactive widget tray with a plugin architecture so widgets are cheap to add or remove.

## Status

| Area | State |
|------|--------|
| Notch window engine (collapsed / expanded) | **Live** |
| Plugin architecture (`NotchWidgetPlugin`) | **Live** |
| Media Controls widget | **Live** (MediaRemote + AppleScript fallback) |
| Calendar widget | **Live** (EventKit; permission-gated) |
| Clipboard / Snippets | **Live** (history + pinned, Application Support JSON) |
| Checklist | **Live** (Application Support JSON) |
| Stocks | **Live** (Finnhub; needs local API key) |
| Settings (reorder / toggle) | **Live** (UserDefaults, instant tray update) |
| Visual polish (vibrancy, theme, spring) | **Live** |

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

Or open `Package.swift` in Xcode and run the `Dynamo` scheme (⌘R).

Calendar access is requested on first launch. Grant it under **System Settings → Privacy & Security → Calendars** if prompted.

## Architecture principles

- **Every widget conforms to `NotchWidgetPlugin`.** Hosts never special-case a widget by name.
- **One folder per widget** under `Sources/Dynamo/Widgets/<Name>/`.
- **External data sources sit behind a small protocol** (e.g. `NowPlayingProvider`, `CalendarProvider`, `StockQuoteProvider`) so mock and real implementations swap without touching UI.
- **Two-state hover model** only: `NotchWindowController.isExpanded`. No intermediate expansion states.
- **Shared `NotchTheme`** for spacing, type, color roles, and spring motion; panel uses `NSVisualEffectView` vibrancy.

## Architecture decision: Swift Package vs `.xcodeproj` app target

**Decision (current): stay a Swift Package executable.**

Reasons:

- Faster iteration and a single `Package.swift` source of truth.
- Info.plist is embedded via a linker section (`__TEXT,__info_plist`) so usage-description keys work without a full app bundle.
- No paid distribution / notarization path yet, so a formal bundle identifier workflow is optional.

**Revisit when any of these become true:** shipping a proper app icon and versioned `.app`, notarization, a multi-window Settings experience that fights SPM packaging, or entitlements that need a real app target. Conversion is nontrivial churn; don't do it preemptively.

## Stocks API key setup (Finnhub)

**Why Finnhub:** free tier is ~60 calls/minute — enough for a 60s refresh of a small watchlist. Alpha Vantage free is ~25 calls/day (too tight). Twelve Data free is 8/min and 800/day (usable, but Finnhub is more headroom).

1. Register at [finnhub.io/register](https://finnhub.io/register) and copy your free API key.
2. Store it **outside git** in one of these places:
   - File: `~/Library/Application Support/Dynamo/finnhub_api_key` (single line, no quotes), or
   - Environment variable: `FINNHUB_API_KEY=...` when launching Dynamo.
3. Relaunch Dynamo. Default watchlist is `AAPL`, `MSFT`, `GOOGL`; edit it from the expanded Stocks widget.

Never commit the key. `.gitignore` already excludes `Secrets.local.swift`, `.env*`, and `*.local.json`.

## Next steps (post this phase)

- Optional: convert to a proper `.app` / Xcode project when distributing.
- Optional: MediaRemoteAdapter helper for macOS 15.4+ entitlement edge cases if AppleScript fallback is insufficient.
- Optional: drag-to-reorder checklist items in the expanded tray.
- Optional: app icon, launch-at-login, Sparkle updates.

`MockNowPlayingProvider` remains in the tree for previews/tests; the app wires `MediaRemoteNowPlayingProvider` at launch.

## License

MIT — see [LICENSE](LICENSE).
