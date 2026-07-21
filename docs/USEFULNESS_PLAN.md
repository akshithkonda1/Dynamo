# Dynamo — usefulness plan (Tier A · B · C)

Daily driver: `~/Documents/Dynamo/dist/Dynamo.app` · Branch: `feat/phases-a-e-polish`

## North star

> The notch is a **command surface** for the next 30 seconds — not a dashboard.

---

## Shipped in this epic

### Frontend predictability (W0)
- Single open path: `revealAndExpand()` (hover, hotkeys, menu, Settings)
- Matched chrome height + spring expand; first-click-friendly buttons

### Tier A
| ID | Feature | Status |
|----|---------|--------|
| A1 | **Shelf stash copies** into App Support | Done |
| A2 | Hotkey polish + conflict summary | Done |
| A3 | **Clipboard images** (screenshots) | Done |
| A4 | **Meeting Mode ambient dim** for music | Done |
| A5 | **Today** chip → Calendar | Done |

### Tier B
| ID | Feature | Status |
|----|---------|--------|
| B1 | **`dynamo://` URLs** (show/mute/play/shelf/calendar/peek) | Done |
| B2 | **Audio output device picker** in Media | Done |
| B3 | **Quiet peeks when LPM / Focus proxy** (optional) | Done |

### Tier C
| ID | Feature | Status |
|----|---------|--------|
| C1 | **Critical Peek bridge** (distributed notification + URL) | Done |

### Out of scope (by design)
- Local AI  
- Separate Reminders completer (reminders stay **with Calendar**)  
- Multi-display follow cursor  
- Plugin packs  
- Notarized releases  

---

## Hotkeys (⌃⌥)

| Keys | Action |
|------|--------|
| D | Show notch |
| P | Play/Pause |
| M | Mute |
| S | Shelf |
| C | Calendar |

## URLs

```
dynamo://show
dynamo://mute
dynamo://play
dynamo://shelf
dynamo://calendar
dynamo://peek?title=Hello&subtitle=World
```

Peek bridge must be enabled in Settings → General.

## Peek bridge (Shortcuts / scripts)

Distributed notification name: `com.akshithkonda.Dynamo.externalPeek`  
userInfo: `title` (required), `subtitle`, `critical` (default true).

---

## Smoke checklist (additions)

- [ ] Drop file → delete original → still opens from Shelf (Stashed)  
- [ ] Screenshot → Clipboard history shows image → copy works  
- [ ] Calendar **Today** opens today  
- [ ] Live meeting + music → ambient dimmed; track peeks quiet  
- [ ] Media → System Volume → switch output device  
- [ ] `open 'dynamo://show'` expands notch  
- [ ] Peek bridge on → `dynamo://peek?title=Test` shows pill  
- [ ] Single Dynamo process after relaunch  
