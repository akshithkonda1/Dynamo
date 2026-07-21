# Dynamo — feature roadmap

Visual polish ships continuously. This plan sequences **new capabilities** by user value and engineering risk. Daily driver remains `~/Documents/Dynamo/dist/Dynamo.app`.

---

## Principles

1. **Notch-first** — features must earn space in the island; no cluttered chrome.
2. **Protocol plugins** — new widgets register; hosts never hard-code names.
3. **Privacy by default** — camera/mic only while the tab is open; no background telemetry.
4. **One PR per theme** when possible (or a short stack).

---

## Now (polish — done / in flight)

| Item | Status |
|------|--------|
| Glass scrim, cards, tray live dots | Done |
| Ambient clock / weather / media priority | Done |
| Continuity Camera | Done |
| Collapse delay 5–10s | Done |
| No top transport strip (media stays in Media tab) | Done |
| Refined glass + clock under tray | This pass |

---

## Near-term (next 2–4 weeks)

### F1 — Focus Mode (“Meeting Mode”)
When Calendar event is **Now**:
- Suppress non-critical sneak peeks (track changes, weather minor)
- Optional dim of ambient music art
- Toggle in Settings → General

**Why:** Dynamo becomes meeting-aware without another SaaS.

### F2 — Global hotkeys
| Shortcut | Action |
|----------|--------|
| ⌃⌥D | Show / expand notch |
| ⌃⌥P | Play / Pause |
| ⌃⌥M | Mute |
| ⌃⌥S | Focus Shelf |

Uses `MASShortcut` or `Carbon` hotkeys; Settings list + conflict detect.

### F3 — Drop Stack polish
- Stash **copies** into Application Support (true pocket, not aliases only)
- Drag-out as file promise
- Optional “AirDrop last item” from menu bar

### F4 — Smart Clipboard
- Image + file URL history (not just text)
- Pin with color tags
- “Paste as plain” / snippet expansion (opt-in)

### F5 — Media superpowers
- Scrub remaining-time ring on ambient art
- Favorite playlist star
- Device output picker (speakers / AirPods) via Core Audio

---

## Mid-term (1–2 months)

### F6 — Themes
- Light / dark / auto glass intensity
- Accent color (violet / blue / mono)
- Reduced motion preference

### F7 — Multi-display intelligence
- Follow cursor screen
- Per-display notch metrics cache
- External monitor “floating island” mode (no physical notch)

### F8 — Notifications bridge (opt-in)
- Mirror **critical** macOS notifications into sneak peeks
- App allowlist only; never full notification dump

### F9 — AI assist (SpaceXAI / local)
- “Summarize next meeting”
- “Draft reply from clipboard”
- Fully opt-in; no key required for core app

### F10 — Widgets marketplace (local packs)
- JSON + Swift plugin packs in `~/Library/Application Support/Dynamo/Plugins`
- Sandboxed JS or SwiftPM dynamic libraries later

---

## Stretch (later)

| Idea | Notes |
|------|--------|
| Touch Bar / Stream Deck | Same quick-action bus as menu |
| iOS companion | Continuity Camera already; remote clipboard |
| Shortcuts app | App Intents for expand / mute / shelf |
| DMG + notarize | `scripts/release-local.sh` path |
| Sparkle updates | Stable channel only |

---

## Suggested PR stack

```
PR-A  polish: glass + chrome (this)
PR-B  feat: meeting mode + peek policy
PR-C  feat: global hotkeys
PR-D  feat: shelf stash copies + drag-out
PR-E  feat: media device picker + ambient ring progress
```

---

## Acceptance for any new feature

- [ ] Works with single-instance `dist/Dynamo.app`
- [ ] First-click on nonactivating panel
- [ ] Collapse delay respected
- [ ] No tray order hard-coding (except Shelf · Webcam pin cluster)
- [ ] Smoke test checklist line in `Docs/SMOKE_TEST.md`
- [ ] CI green on PR

---

## Explicit non-goals (for now)

- Full browser / chat client in the notch  
- Always-on camera  
- Cloud account for core widgets  
- Cloning every Boring Notch feature at once  
