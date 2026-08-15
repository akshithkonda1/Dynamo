# Dynamo 1.0.1 — Production readiness (no Weather)

**Date:** 2026-08-15  
**Ship vehicle:** `dist/Dynamo.app` only (single daily driver)  
**Scope:** Production daily driver **without Weather / WeatherKit** — **World Clock** is the free replacement.

## Verdict

**SHIP** for production use on the author’s Mac (ad-hoc signed `dist/Dynamo.app`), with Weather deliberately excluded and replaced by World Clock.

Not App Store / notarized multi-Mac distribution until Developer ID + notarization secrets are configured.

## Production surface (enabled)

| Area | Status | Notes |
|------|--------|--------|
| Single-instance daily driver | ✅ | `dist/Dynamo.app` wins; strays terminated |
| Notch expand/collapse + tray | ✅ | Snappier springs; adaptive width; Preferences gear |
| Media transport + ambient EQ | ✅ | Process tap + peek aurora; transport under scrubber |
| Media Amplify | ✅ | EQ-only; Feel & alerts + notch control |
| Calendar read + create | ✅ | EventKit + in-notch composer |
| Reminders R/W | ✅ | Checklist + due peeks |
| Battery + power modes | ✅ | Low / Auto / High via pmset |
| Focus + Meeting companion | ✅ | Notes, duck, smart enter/leave |
| **World Clock** | ✅ | Free multi-city clocks; no network |
| Sports scores | ✅ | Free ESPN CDN |
| System Health | ✅ | Local score + deep links |
| Shelf + Webcam | ✅ | Drop shelf; camera only while tab open |
| Peek notification center | ✅ | Queue + DynamoNotificationAPI |
| System notification mirror | ✅ | Faster poll; may need Full Disk Access |
| Preferences | ✅ | Feel & alerts, Amplify, permissions catalog |
| Packaging | ✅ | `scripts/package-app.sh` ad-hoc signed |

## Explicitly out of production scope

| Area | Status | Notes |
|------|--------|--------|
| **Weather widget** | ❌ disabled | Not registered; prefs stripped of `weather` |
| WeatherKit / Location | ❌ not required | Replaced by World Clock |
| Developer ID notarization | ⏳ optional | Gatekeeper on other Macs |
| App Store | ⏳ optional | Privacy labels + review |

## Weather replacement

| Need | Replacement |
|------|-------------|
| Glanceable ambient strip | World Clock ambient (up to 3 cities) |
| Expanded detail | Multi-city times + day/offset |
| Preferences | Clocks city toggles (up to 8) |
| APIs / team cost | None — system Time Zone database |

## Smoke checklist (production)

1. Only one process: `dist/Dynamo.app`  
2. No Weather tab; **Clocks** tab present  
3. Menu shows **Preferences** (not “Settings…”)  
4. Preferences → Feel & alerts → collapse delay + Amplify  
5. Media play/pause first-click; Amplify green/red (volume unchanged)  
6. Calendar New → create event  
7. Checklist → add reminder  
8. Battery power mode chips  
9. Focus → Meeting → Leave  
10. Peek: `open 'dynamo://notify?title=Test&subtitle=Prod'`  
11. Preferences → Permissions lists core grants  

## Architecture invariants

- Widgets never special-cased by name in hosts (protocol discovery).  
- Weather omitted only at registration / settings strip — no host name switches beyond production exclude list.  
- Peek presentation ≠ delivery policy.  
- Meeting never auto-joins calls.
