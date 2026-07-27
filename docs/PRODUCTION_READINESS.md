# Dynamo 0.5.1 — Production readiness

**Date:** 2026-07-27  
**Ship vehicle:** `dist/Dynamo.app` only (single daily driver)

## Verdict

**Conditional SHIP** for personal / early production use on the author’s Mac.  
Not yet general App Store / wide beta without the HOLD items below.

## What is production-ready

| Area | Status | Notes |
|------|--------|--------|
| Single-instance daily driver | ✅ | `dist/Dynamo.app` wins; strays terminated |
| Notch expand/collapse + tray | ✅ | Adaptive width, labeled active tab |
| Media transport + ambient EQ | ✅ | Process tap + peek aurora |
| Media Amplify | ✅ | Volume boost + Music EQ profiles |
| Calendar read + create | ✅ | EventKit full access + in-notch composer |
| Reminders R/W | ✅ | Create / complete / delete + due peeks |
| Battery metrics + power modes | ✅ | IOKit + pmset Low/Auto/High |
| Focus modes + Meeting companion | ✅ | Speech notes, duck, smart enter/leave |
| Sports scores | ✅ | Free ESPN CDN |
| **Peek as notification center** | ✅ | Queue, coalesce, haptics, history, external bridge |
| Packaging | ✅ | `scripts/package-app.sh` ad-hoc signed |

## Notification delivery (Peek takeover)

- All Dynamo-originated alerts route through `PeekNotificationCenter`.
- Queue + id coalescing; media/critical preempt.
- Haptics on deliver; optional critical sound.
- External: `dynamo://peek?title=…` + `com.akshithkonda.Dynamo.externalPeek`.
- Meeting Mode still quiets low/normal peeks.
- **Does not** intercept other apps’ Notification Center banners (macOS does not allow that without private APIs). Dynamo replaces *its own* system-banner path with Peek.

## HOLD / before wide release

1. **Hardened codesign + notarization** for Gatekeeper on other Macs (`scripts/notarize.sh` exists; needs Developer ID).
2. **pmset power modes** may fail without admin / Battery Settings — UX fallback exists.
3. **WeatherKit** needs paid Apple team signing for real weather in Xcode target.
4. **Automated UI tests** for tray/peek/meeting are thin — rely on manual smoke.
5. **Accessibility** audit (VoiceOver labels on tray chips, peeks).
6. **Privacy nutrition labels** if App Store: calendar, reminders, mic, speech, camera, location, audio.
7. **Crash/telemetry** optional opt-in not present (by design for local-first).

## Smoke checklist (manual)

1. Launch only `dist/Dynamo.app` — one process.
2. Expand notch — tray labels + width OK.
3. Media play → ambient + skip peek (aurora).
4. Amplify On → volume lifts; Off restores.
5. Calendar **New** → create event → appears in list.
6. Checklist add reminder with due 1h → complete works.
7. Battery Low/Auto chips change mode (or open Settings).
8. Focus → Meeting → duck + notes; Leave restores volume.
9. Calendar event in 15m → Peek; battery ≤20% → Peek.
10. `open 'dynamo://peek?title=Test&subtitle=Bridge'` → Peek.

## Architecture invariants

- Widgets never special-cased by name in hosts (protocol discovery).
- Peek presentation ≠ delivery policy (`NotchSneakPeekController` vs `PeekNotificationCenter`).
- Meeting never auto-joins calls; companion only.
