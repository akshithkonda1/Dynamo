# Dynamo smoke test checklist

Use this after a local build to confirm the app is usable day-to-day.  
**WeatherKit signing / paid-team provisioning is out of scope for this pass** — skip or soft-fail Weather live data if the build is ad-hoc.

**Daily driver path:** `~/Documents/Dynamo/dist/Dynamo.app` only (kill older copies first).

---

## 0. Pre-flight

- [ ] Working tree is `~/Documents/Dynamo`
- [ ] Build succeeds: `./scripts/package-app.sh debug && open dist/Dynamo.app`
- [ ] Single process: `pgrep -x Dynamo` shows one PID
- [ ] Menu-bar Dynamo icon appears (accessory app — no Dock icon)
- [ ] Notch panel appears on the built-in / preferred display

---

## 1. Notch shell (Phases A / D)

- [ ] Collapsed panel sits in / under the physical notch
- [ ] Hover expands tray with spring motion; design tokens (cards, chips) look consistent
- [ ] Leaving the panel collapses after the Settings delay (default 10s)
- [ ] **Settings → General → Collapse after leaving notch**: try 3s / hover-only
- [ ] Tray trailing cluster: **Shelf · Webcam · Settings**
- [ ] Active tray tab is a brighter filled pill
- [ ] **Hidden mode**: panel hides until cursor hits the top edge

---

## 2. Ambient (Phase B)

- [ ] Music playing → collapsed ambient shows art + bars (+ remaining time if known)
- [ ] Music paused + meeting within ~60m → calendar ambient (title + “in Xm” / Now)
- [ ] Low battery (≤20%) when nothing else ambient → % + bolt/red tint
- [ ] Priority: media playing wins over calendar over battery

---

## 3. Settings IA (Phase E)

- [ ] Menu bar → **Settings…** opens a real `NSWindow`
- [ ] Sections present: **General · Appearance · Widgets · Permissions · About** (+ per-widget)
- [ ] Collapse delay picker works
- [ ] Display picker under Appearance repositions the tray
- [ ] Toggle / reorder widgets; quit + relaunch → prefs survive
- [ ] About shows dist path + Show Notch / Focus File Shelf quick actions

---

## 4. Menu quick actions (Phase D)

- [ ] **Show Notch** expands tray
- [ ] **Focus File Shelf** opens Shelf tab
- [ ] **Play/Pause** toggles current media
- [ ] **Mute / Unmute** toggles system mute

---

## 5. Media + volume (Phase C)

- [ ] Packaged app has `Contents/MacOS/DynamoMediaRemoteHelper`
- [ ] Expanded: transport, timeline scrub, playlist switch
- [ ] System Volume card always shows exact **percent** (matches menu-bar when set via UI scale)
- [ ] Empty state when nothing playing + Open Music/Spotify chip
- [ ] Track change sneak-peek pill

---

## 6. Calendar (Phase C)

- [ ] Events that have **ended** no longer appear
- [ ] **Now** / **Soon** chips for in-progress / &lt;30m events
- [ ] **+ New** / New event opens Calendar compose
- [ ] Click event opens it in Calendar.app

---

## 7. Webcam (Phase C)

- [ ] Tap mirror starts/stops camera (circle by default)
- [ ] Device menu when multiple cameras
- [ ] Zoom 1× / 1.5× / 2×
- [ ] Snap → clipboard; Freeze freezes frame

---

## 8. Shelf / Clipboard / Checklist

- [ ] Drop files onto notch or Shelf; **Add** picker works
- [ ] File size shown; drag-out / AirDrop / Reveal
- [ ] Clipboard: pin, delete history row, clear
- [ ] Checklist: progress `done/total`, always-visible add field

---

## 9. Battery / Weather

- [ ] Battery hero % + charging state; ambient when low/charging
- [ ] Weather H/L + symbol when available; calm empty state otherwise

---

## 10. Stability

- [ ] Second `open dist/Dynamo.app` → still one process
- [ ] First click on transport / mute works (nonactivating panel)
- [ ] No double volume HUD on media key
