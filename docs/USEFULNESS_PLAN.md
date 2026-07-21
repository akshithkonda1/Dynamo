# Dynamo — usefulness plan

How Dynamo earns a permanent place in the menu bar: **save steps, reduce context switches, stay quiet when it should.**

Daily driver: `~/Documents/Dynamo/dist/Dynamo.app` · Branch: `feat/phases-a-e-polish`

---

## North star

> The notch is a **command surface** for the next 30 seconds of your day — not a dashboard you have to manage.

| Principle | Practice |
|-----------|----------|
| Zero travel | Hotkeys + tray beat opening apps |
| Context-aware | Meeting Mode, ambient priority, battery LPM |
| Local-first | No accounts required for core value |
| Quiet by default | Peeks only when useful; suppress in meetings |

---

## Already useful (shipped)

| Capability | Why it matters |
|------------|----------------|
| Media + system volume in notch | Control playback without leaving the flow |
| Calendar Now/Soon + New event | Next meeting visible; compose in one click |
| Clipboard history + pins | Reuse text without ⌘-tab to Notes |
| Checklist with progress | Tiny todos without another app |
| File Shelf drop zone | Stash files mid-drag |
| Webcam / Continuity Camera | Quick mirror without Photo Booth |
| Battery health + Low Power | Stretch charge; local drain model |
| Ambient clock → Clock.app | Time + open Clock |
| **Meeting Mode** | Quiet peeks while event is Now |
| **Global hotkeys** | ⌃⌥D/P/M/S/C without opening the menu |

---

## Usefulness roadmap

### Tier A — Do next (1–2 weeks)

| ID | Feature | User outcome | Effort |
|----|---------|--------------|--------|
| **U1** | **True Shelf stash** | Dropped files copied into App Support; survive source delete | M |
| **U2** | **Focus Calendar / Media hotkeys polish** | Status bar docs + conflict notice if register fails | S |
| **U3** | **Clipboard images** | Screenshots land in history; pin/copy | M |
| **U4** | **Meeting Mode ambient** | Optional: dim music ambient during Now events | S |
| **U5** | **“Open today in Calendar”** | One chip from ambient calendar | S |

### Tier B — High leverage (2–6 weeks)

| ID | Feature | User outcome |
|----|---------|--------------|
| **U6** | **App Intents / Shortcuts** | “Show Dynamo”, “Mute”, “Shelf” from Shortcuts & Siri |
| **U7** | **Output device picker** | Switch speakers / AirPods from Media |
| **U8** | **Reminder complete from notch** | Check off due reminder without Reminders.app |
| **U9** | **Multi-display follow cursor** | Notch on the screen you’re using |
| **U10** | **Do Not Disturb sync** | Align Meeting Mode with Focus (read-only or soft) |

### Tier C — Differentiators (later)

| ID | Feature | User outcome |
|----|---------|--------------|
| **U11** | **Critical notification bridge** | Allowlisted apps peek only (mail/calendar VIP) |
| **U12** | **Local AI assist** | Summarize next meeting / clipboard (opt-in, SpaceXAI) |
| **U13** | **Plugin packs** | Community widgets without forking Dynamo |
| **U14** | **Notarized releases** | One-click install for others |

---

## Suggested delivery stack

```
PR 1  Meeting Mode + hotkeys          ← this pass
PR 2  Shelf stash copies + drag-out
PR 3  Clipboard images + paste plain
PR 4  App Intents
PR 5  Media output device picker
```

---

## Metrics of “useful” (manual smoke)

Weekly, if any item fails, prioritize a fix over new chrome:

- [ ] ⌃⌥D expands notch from any app  
- [ ] During a live calendar event, track-change peeks stay quiet (Meeting Mode on)  
- [ ] Critical weather / LPM still surface  
- [ ] Drop file → Shelf has it after source moves  
- [ ] Battery Low Power toggles OS state  
- [ ] Single `Dynamo` process after second open  

---

## Explicit non-goals (stay useful, not bloated)

- Full email / chat / browser in the notch  
- Always-on camera or mic  
- Cloud sync for core widgets  
- Cloning every competitor feature before U1–U5 ship  

---

## Decision log

| Choice | Why |
|--------|-----|
| Hotkeys = Control+Option | Avoids ⌘ collisions with system/apps |
| Meeting Mode default **on** | Prefer quiet; user can disable |
| History on-device only | Trust + offline usefulness |
| Plan lives in `Docs/` | Ship with the product, not only chat |
