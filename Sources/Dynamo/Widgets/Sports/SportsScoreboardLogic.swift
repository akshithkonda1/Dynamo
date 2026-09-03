import Foundation

/// Pure ESPN scoreboard merge + date key (US Eastern), so live scores don't freeze.
enum SportsScoreboardLogic {
    static let espnTimeZone = TimeZone(identifier: "America/New_York") ?? .current

    static func dayString(_ date: Date, timeZone: TimeZone = espnTimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    static func merge(_ batch: [SportsEvent], into combined: inout [String: SportsEvent]) {
        for ev in batch {
            if let existing = combined[ev.id] {
                combined[ev.id] = preferred(existing, ev)
            } else {
                combined[ev.id] = ev
            }
        }
    }

    static func preferred(_ existing: SportsEvent, _ incoming: SportsEvent) -> SportsEvent {
        var pick = existing

        if incoming.status == .live, existing.status != .live {
            pick = incoming
        } else if incoming.status == .final, existing.status == .live || existing.status == .scheduled {
            pick = incoming
        } else if existing.status == incoming.status {
            if incomingHasFresherScore(existing: existing, incoming: incoming) {
                pick = incoming
            }
        } else if existing.status != .live, statusRank(incoming.status) < statusRank(existing.status) {
            pick = incoming
        }

        return withFilledLogos(pick, other: pick.id == incoming.id ? existing : incoming)
    }

    private static func incomingHasFresherScore(existing: SportsEvent, incoming: SportsEvent) -> Bool {
        let e = existing.scoreLine
        let i = incoming.scoreLine
        if i != nil, e != i { return true }
        if i != nil, e == nil { return true }
        if incoming.statusText != existing.statusText, !incoming.statusText.isEmpty { return true }
        return false
    }

    private static func withFilledLogos(_ pick: SportsEvent, other: SportsEvent) -> SportsEvent {
        guard pick.homeLogoURL == nil || pick.awayLogoURL == nil else { return pick }
        return SportsEvent(
            id: pick.id,
            league: pick.league,
            name: pick.name,
            detail: pick.detail,
            status: pick.status,
            homeName: pick.homeName,
            awayName: pick.awayName,
            homeScore: pick.homeScore,
            awayScore: pick.awayScore,
            homeAbbrev: pick.homeAbbrev,
            awayAbbrev: pick.awayAbbrev,
            homeLogoURL: pick.homeLogoURL ?? other.homeLogoURL,
            awayLogoURL: pick.awayLogoURL ?? other.awayLogoURL,
            statusText: pick.statusText,
            startDate: pick.startDate,
            linkURL: pick.linkURL,
            headlineScore: pick.headlineScore,
            broadcast: pick.broadcast
        )
    }

    static func statusRank(_ s: SportsEventStatus) -> Int {
        switch s {
        case .live: return 0
        case .scheduled, .delayed: return 1
        case .other: return 2
        case .final: return 3
        }
    }
}
