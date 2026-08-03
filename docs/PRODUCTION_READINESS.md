# Dynamo 1.0.0 — Production readiness (minus Weather)

**Date:** 2026-08-03  
**Ship vehicle:** `dist/Dynamo.app` only (single daily driver)  
**Scope:** Production daily driver **without Weather / WeatherKit**

## Verdict

**SHIP** for production use on the author’s Mac (ad-hoc signed `dist/Dynamo.app`), with Weather deliberately excluded.

Not App Store / notarized multi-Mac distribution until Developer ID + notarization secrets are configured.

## Production surface (enabled)

| Area | Status | Notes |
|------|--------|--------|
| Single-instance daily driver | ✅ | `dist/Dynamo.app` wins; strays terminated |
| Notch expand/collapse + tray | ✅ | Adaptive width, labeled active tab |
| Media transport + ambient EQ | ✅ | Process tap + peek aurora; transport under scrubber |
| Media Amplify | ✅ | EQ-only (no volume fader); Presence/Cinema/Impact |
| Calendar read + create | ✅ | EventKit + in-notch composer |
| Reminders R/W | ✅ | Checklist + due peeks |
| Battery + power modes | ✅ | Low / Auto / High via pmset |
| Focus + Meeting companion | ✅ | Notes, duck, smart enter/leave |
| Sports scores | ✅ | Free ESPN CDN |
| System Health | ✅ | Local score + deep links |
| Shelf + Webcam | ✅ | Drop shelf; camera only while tab open |
| Peek notification center | ✅ | Queue + DynamoNotificationAPI |
| System notification mirror | ✅ | usernoted store; may need Full Disk Access |
| Permissions Settings | ✅ | Full catalog Core / Optional |
| Packaging | ✅ | `scripts/package-app.sh` ad-hoc signed |

## Explicitly out of production scope

| Area | Status | Notes |
|------|--------|--------|
| **Weather widget** | ❌ disabled | Not registered; prefs stripped of `weather` |
| WeatherKit / Location | ❌ not required | Needs paid team + Xcode export |
| Developer ID notarization | ⏳ optional | Gatekeeper on other Macs |
| App Store | ⏳ optional | Privacy labels + review |

## Smoke checklist (production)

1. Only one process: `dist/Dynamo.app`  
2. No Weather tab in tray / Settings widgets  
3. Media play/pause first-click; Amplify green/red (volume unchanged)  
4. Calendar New → create event  
5. Checklist → add reminder  
6. Battery power mode chips  
7. Focus → Meeting → Leave  
8. Peek: `open 'dynamo://notify?title=Test&subtitle=Prod'`  
9. Settings → Permissions lists core grants  

## Architecture invariants

- Widgets never special-cased by name in hosts (protocol discovery).  
- Weather omitted only at registration / settings strip — no host name switches beyond production exclude list.  
- Peek presentation ≠ delivery policy.  
- Meeting never auto-joins calls.
