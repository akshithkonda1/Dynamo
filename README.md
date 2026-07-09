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
| Clipboard / Snippets | Not started |
| Checklist | Not started |
| Stocks | Not started |
| Settings (reorder / toggle) | Placeholder window only |
| Visual polish (vibrancy, theme, spring) | Not started |

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
- **External data sources sit behind a small protocol** (e.g. `NowPlayingProvider`, `CalendarProvider`) so mock and real implementations swap without touching UI.
- **Two-state hover model** only: `NotchWindowController.isExpanded`. No intermediate expansion states.

## Architecture decision: Swift Package vs `.xcodeproj` app target

**Decision (current): stay a Swift Package executable.**

Reasons:

- Faster iteration and a single `Package.swift` source of truth.
- Info.plist is embedded via a linker section (`__TEXT,__info_plist`) so usage-description keys work without a full app bundle.
- No paid distribution / notarization path yet, so a formal bundle identifier workflow is optional.

**Revisit when any of these become true:** shipping a proper app icon and versioned `.app`, notarization, a multi-window Settings experience that fights SPM packaging, or entitlements that need a real app target. Conversion is nontrivial churn; don't do it preemptively.

## Next steps

1. ~~Real Now Playing data via MediaRemote~~
2. Clipboard / Snippets widget
3. Checklist widget
4. Stocks widget (free-tier quote API + local API key)
5. Full Settings window (reorder + toggle, UserDefaults)
6. Visual polish pass (vibrancy, shared theme, spring animation)

`MockNowPlayingProvider` remains in the tree for previews/tests; the app wires `MediaRemoteNowPlayingProvider` at launch.

## License

MIT — see [LICENSE](LICENSE).
