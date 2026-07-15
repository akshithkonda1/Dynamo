# Run Dynamo and actually *see* it

## Status on this machine (verified)

| Check | Result |
|-------|--------|
| Code tree | `~/Documents/Dynamo` and `~/Dynamo` both on `main` |
| Build | `swift build` + `./scripts/package-app.sh debug` succeed |
| Process | Launches; MediaRemote helper starts |
| On-screen window | **Yes** — CGWindow at top center (~160×28, layer 25) hugging the notch |
| Dock icon | **None** (by design: `LSUIElement` / menu-bar app) |

Nothing major is missing for a basic visual render. The collapsed UI is intentionally tiny so it disappears into the MacBook notch — easy to think “nothing rendered.”

---

## Fastest path to render (today)

```bash
export DEVELOPER_DIR=/Users/akshithkonda/Downloads/Xcode-beta.app/Contents/Developer
cd ~/Documents/Dynamo

./scripts/package-app.sh debug
open dist/Dynamo.app
```

Then:

1. **Menu bar (top-right)** — look for the **notch / rectangle** template icon (Dynamo).  
2. Click it → **Show Notch** (forces expand if you can’t find the strip).  
3. Or **hover the top-center of the built-in display** (the physical notch) to expand.  
4. **Settings…** from the same menu opens the real settings window.

### What you should see when expanded

Tray icons for: Media · Calendar · Clipboard · Checklist · Weather · Battery · Shelf · Webcam · Messages  
(Some tabs need permissions; empty/error states still *render*.)

---

## What’s required vs optional for full fidelity

### Required to “see the app” (you already have this)

- [x] Xcode / CLT SDK (you have **Xcode-beta** at `~/Downloads/Xcode-beta.app`)
- [x] `swift build` toolchain
- [x] Packaged `.app` with helper binary
- [x] A screen (built-in Retina with real notch geometry is ideal)

### Optional for *feature* completeness (does not block render)

| Feature | Missing until you… |
|---------|---------------------|
| **Live Weather** | Paid Apple Developer team + `xcodegen generate` + Xcode Signing (WeatherKit entitlement). Ad-hoc still shows the Weather *UI* with an error/empty state. |
| **Calendar events / meeting peeks** | Grant **Calendars** (and **Reminders** for due peeks). |
| **Messages threads / reply** | Grant **Full Disk Access** to this exact `Dynamo.app`, quit/relaunch; first reply needs **Automation → Messages**. |
| **Webcam** | Grant **Camera** when the Webcam tab is opened. |
| **Location weather** | Grant **Location**, or set a city in Settings → Weather. |
| **Launch at Login** | Toggle in Settings (works best with the packaged `.app`). |
| **Notarized DMG for others** | Developer ID + notary credentials (`scripts/release-local.sh`). Not needed for local use. |

### Not required

- Full Xcode project (SPM package path is enough to render)
- Accessibility (only needed if something *else* scripts Dynamo)
- Internet (except Weather/Stocks-era APIs — Weather needs Apple’s service when signed)

---

## Xcode run path (optional, for WeatherKit later)

```bash
cd ~/Documents/Dynamo
xcodegen generate
open Dynamo.xcodeproj
```

In Xcode: select **Dynamo** scheme → your team under Signing → ⌘R.

---

## If it looks like nothing is there

| Symptom | Cause | Fix |
|---------|--------|-----|
| No Dock icon | Accessory app | Use **menu bar** icon |
| No strip at top | Collapsed into notch (~28pt tall) | Menu → **Show Notch**, or hover top-center |
| Completely gone | Hidden mode on | Menu → uncheck **Hidden mode**, or move cursor to top edge |
| Wrong screen | Multi-monitor | Settings → **Display for notch** |
| Old Stocks/AI build | Stale `~/Dynamo` from Phase 2 | Use `Documents/Dynamo` on `main` (synced) |
| Gatekeeper block | First open of ad-hoc app | Right-click → Open, or `xattr -cr dist/Dynamo.app` |

---

## Confirm it’s drawing (debug)

With Dynamo running:

```bash
# Should list a Dynamo window near top-center
# (use Activity Monitor → Dynamo → Sample, or CG window list)
ps aux | grep 'Dynamo.app/Contents/MacOS/Dynamo$' | grep -v grep
```

On this Mac we already measured:

```text
bounds ≈ { X: 560, Y: 1, Width: 160, Height: 28 }  // 1280-wide built-in, notch-sized
```

That **is** the rendered collapsed notch.
