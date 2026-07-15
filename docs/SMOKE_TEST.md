# Dynamo smoke test checklist

Use this after a local build (Xcode target preferred) to confirm the app is usable day-to-day.  
**WeatherKit signing / paid-team provisioning is out of scope for this pass** — skip or soft-fail Weather live data if the build is ad-hoc.

**Decisions for this pass**

| Item | Decision |
|------|----------|
| WeatherKit / paid team signing | Leave alone for now |
| Messages Full Disk Access (FDA) | **Yes — enable and verify** |

Check boxes as you go. Prefer a cold launch each major section.

---

## 0. Pre-flight

- [ ] Working tree is `~/Documents/Dynamo` on `main` (not the older `~/Dynamo` Phase-2 tree)
- [ ] Build succeeds
  - Xcode: `xcodegen generate && open Dynamo.xcodeproj` → ⌘R, **or**
  - Ad-hoc: `./scripts/package-app.sh debug && open dist/Dynamo.app`
- [ ] Menu-bar Dynamo icon appears (accessory app — no Dock icon)
- [ ] Notch panel appears on the built-in display (or primary notched screen)

---

## 1. Notch shell

- [ ] Collapsed panel sits in / under the physical notch (not a random floating bar)
- [ ] Hover expands tray with spring motion
- [ ] Leaving the panel collapses it
- [ ] Expanded tray shows widget icons; selecting one swaps content without relaunch
- [ ] **Settings → General → Hidden mode (peek-a-boo)** (if enabled): panel hides until cursor hits the top edge, then peeks and retreats

---

## 2. Settings

- [ ] Menu bar → **Settings…** opens a real `NSWindow` (not the notch)
- [ ] Toggle a widget **off** → disappears from the tray immediately
- [ ] Toggle it **on** → returns immediately
- [ ] Drag-reorder widgets → tray icon order updates immediately
- [ ] **Display for notch** picker lists screens; choosing one repositions the tray
- [ ] Quit and relaunch → order + enabled set + display preference survive

---

## 3. Media Controls

- [ ] Packaged app contains `Contents/MacOS/DynamoMediaRemoteHelper` (`ls dist/Dynamo.app/Contents/MacOS/`)
- [ ] Start playback in Music or Spotify
- [ ] Collapsed / ambient notch shows now-playing presence (art and/or bars) when designed to
- [ ] Expanded: play/pause and skip control the player
- [ ] Track change produces a brief sneak-peek pill (title/artist)
- [ ] Volume keys show the notch volume HUD; brightness keys show brightness HUD (where readable)

---

## 4. Calendar + Reminders

- [ ] Grant **Calendars** (and **Reminders** if prompted)
- [ ] Expanded list shows upcoming events (or empty state)
- [ ] Due reminders appear under a Reminders section when present
- [ ] With a non-all-day event ~5 minutes out: notch peeks a meeting reminder once
- [ ] With a reminder due within ~5 minutes: notch peeks with checklist icon

---

## 5. Clipboard / Snippets

- [ ] Copy text system-wide → appears in history within ~1s
- [ ] Click history item → copied back to pasteboard
- [ ] Pin a snippet → survives history capping and relaunch
- [ ] Delete pin / clear history works

---

## 6. Checklist

- [ ] Add item, toggle done, delete
- [ ] Drag-reorder items
- [ ] Relaunch → order and check state persist

---

## 7. Weather *(soft — skip live data if ad-hoc / no WeatherKit team)*

- [ ] Widget present in tray (not Stocks)
- [ ] Settings → Weather: auto location **or** manual city
- [ ] **If WeatherKit-signed:** expanded shows temp, H/L, Apple Weather attribution
- [ ] **If ad-hoc only:** document failure mode (error / empty) without blocking the rest of the checklist
- [ ] Severe alert peek: only if an active alert exists (optional)

---

## 8. Battery

- [ ] MacBook: percent + charging state look plausible
- [ ] Desktop (no battery): sensible “no battery” / unavailable state, not a crash

---

## 9. File Shelf

- [ ] Drag a file onto the notch → appears in Shelf
- [ ] Open / Reveal in Finder work
- [ ] AirDrop share button presents share UI (device nearby optional)
- [ ] Clear / remove item works; paths pruned if file deleted (after refresh/relaunch)

---

## 10. Webcam

- [ ] Open Webcam tab → camera starts (macOS Camera permission if first time)
- [ ] Leave Webcam tab → camera stops (no green camera indicator left on)
- [ ] Quit app → camera off

---

## 11. Messages + Full Disk Access (**required this pass**)

Messages is intentionally enabled. FDA is required to read `~/Library/Messages/chat.db`.

### 11a. Grant Full Disk Access

- [ ] Expand **Messages** in the notch (or open **Settings → Messages**)
- [ ] If status is not granted: **Open Full Disk Access Settings** / **Open Privacy Settings**
- [ ] System Settings → Privacy & Security → **Full Disk Access**
- [ ] Enable **Dynamo** (or add `Dynamo.app` via + if missing)
  - Use the same binary you launched (Xcode build vs `dist/Dynamo.app` are different entries)
- [ ] **Quit and relaunch Dynamo** after toggling FDA (macOS often requires this)
- [ ] In Messages widget: **Check Again** → status **“Full Disk Access granted”**

### 11b. Read path

- [ ] Conversation chips appear (recent threads)
- [ ] Select a thread → bubbles show (incoming + outgoing)
- [ ] Empty database / no chats → calm empty state, not a crash
- [ ] Incoming message from someone else (while Dynamo running) → notch sneak peek with sender + preview

### 11c. Send path (Automation)

- [ ] Select a thread you own / a test contact
- [ ] Type a short reply and send
- [ ] First send: allow **Automation** for Dynamo → Messages when macOS prompts
- [ ] Message appears in Messages.app and in the notch thread after refresh
- [ ] Confirm Dynamo did **not** write message bodies into Application Support (only in-memory / chat.db remains source of truth)

### 11d. Safety / privacy (acceptance)

- [ ] Understood: FDA is whole-disk access, not Messages-only
- [ ] Understood: content is not persisted by Dynamo
- [ ] FDA can be revoked later in the same System Settings pane

---

## 12. Launch at Login *(optional)*

- [ ] Settings → Launch at Login on
- [ ] Log out/in or reboot → Dynamo starts (best with a real `.app` bundle)
- [ ] If status is “Requires approval”, complete Login Items approval in System Settings

---

## 13. Stability pass

- [ ] Enable all intended widgets; leave running 10+ minutes
- [ ] No beachball on hover expand/collapse
- [ ] No repeated permission dialogs every launch (after grants)
- [ ] Quit from menu bar cleanly

---

## Sign-off

| Field | Value |
|-------|--------|
| Date | |
| Build path | Xcode / package-app / other |
| macOS version | |
| Machine | MacBook / desktop |
| WeatherKit live data | Pass / soft-fail (ad-hoc) / N/A |
| Messages + FDA | Pass / Fail |
| Notes | |

---

## Quick FDA reference (Messages)

```
System Settings → Privacy & Security → Full Disk Access → Dynamo ON
→ Quit Dynamo → Relaunch → Messages tab → Check Again
```

Deep link from the app: **Open Privacy Settings** (Messages expanded view or Settings → Messages).
