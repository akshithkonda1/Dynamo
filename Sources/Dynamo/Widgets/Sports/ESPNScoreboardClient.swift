import Foundation

/// Public ESPN CDN scoreboard (no API key). Multi-day + multi-path fan-out.
actor ESPNScoreboardClient {
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 28
        c.httpAdditionalHeaders = [
            "User-Agent": "Dynamo/1.0 (macOS; scoreboard)",
            "Accept": "application/json"
        ]
        return URLSession(configuration: c)
    }()

    /// Fetch a 3-day window (yesterday…tomorrow) and merge unique events.
    func fetchEvents(league: SportsLeague, around date: Date = Date()) async -> [SportsEvent] {
        let cal = Calendar.current
        let days: [Date] = [
            cal.date(byAdding: .day, value: -1, to: date) ?? date,
            date,
            cal.date(byAdding: .day, value: 1, to: date) ?? date
        ]
        let paths = Array(Set(league.espnExtraPaths))

        var combined: [String: SportsEvent] = [:]

        await withTaskGroup(of: [SportsEvent].self) { group in
            for path in paths {
                for day in days {
                    group.addTask {
                        await self.fetchScoreboard(path: path, league: league, date: day)
                    }
                }
                group.addTask {
                    await self.fetchScoreboard(path: path, league: league, date: nil)
                }
            }
            for await batch in group {
                merge(batch, into: &combined)
            }
        }

        return sortEvents(Array(combined.values))
    }

    /// Parallel live-ish fetch across several leagues (All Live).
    func fetchLiveAcross(_ leagues: [SportsLeague]) async -> [SportsEvent] {
        var combined: [String: SportsEvent] = [:]
        await withTaskGroup(of: [SportsEvent].self) { group in
            for league in leagues {
                group.addTask {
                    // Prefer undated + today for speed.
                    var out: [SportsEvent] = []
                    out += await self.fetchScoreboard(path: league.espnPath, league: league, date: nil)
                    out += await self.fetchScoreboard(path: league.espnPath, league: league, date: Date())
                    return out.filter(\.isLive)
                }
            }
            for await batch in group {
                merge(batch, into: &combined)
            }
        }
        return sortEvents(Array(combined.values))
    }

    private func merge(_ batch: [SportsEvent], into combined: inout [String: SportsEvent]) {
        for ev in batch {
            if let existing = combined[ev.id] {
                if existing.status != .live, ev.status == .live {
                    combined[ev.id] = ev
                } else if existing.homeLogoURL == nil, ev.homeLogoURL != nil {
                    combined[ev.id] = ev
                }
            } else {
                combined[ev.id] = ev
            }
        }
    }

    private func sortEvents(_ events: [SportsEvent]) -> [SportsEvent] {
        events.sorted { lhs, rhs in
            let lo = statusRank(lhs.status)
            let ro = statusRank(rhs.status)
            if lo != ro { return lo < ro }
            let ld = lhs.startDate ?? .distantFuture
            let rd = rhs.startDate ?? .distantFuture
            return ld < rd
        }
    }

    private func statusRank(_ s: SportsEventStatus) -> Int {
        switch s {
        case .live: return 0
        case .scheduled, .delayed: return 1
        case .other: return 2
        case .final: return 3
        }
    }

    private func fetchScoreboard(path: String, league: SportsLeague, date: Date?) async -> [SportsEvent] {
        var components = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/scoreboard")
        if let date {
            components?.queryItems = [URLQueryItem(name: "dates", value: Self.dayString(date))]
        }
        guard let url = components?.url else { return [] }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            return parseScoreboard(data: data, league: league)
        } catch {
            return []
        }
    }

    private func parseScoreboard(data: Data, league: SportsLeague) -> [SportsEvent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let eventsJSON = root["events"] as? [[String: Any]] ?? []
        var out: [SportsEvent] = []

        for ev in eventsJSON {
            let rawID = (ev["id"] as? String) ?? UUID().uuidString
            let id = "\(league.rawValue)-\(rawID)"
            let name = (ev["name"] as? String) ?? (ev["shortName"] as? String) ?? "Event"
            let start = Self.parseISO(ev["date"] as? String)

            let statusObj = ev["status"] as? [String: Any]
            let typeObj = statusObj?["type"] as? [String: Any]
            let state = (typeObj?["state"] as? String)?.lowercased() ?? ""
            let completed = typeObj?["completed"] as? Bool ?? false
            let detail = (typeObj?["detail"] as? String)
                ?? (typeObj?["shortDetail"] as? String)
                ?? ""
            let status: SportsEventStatus
            if completed || state == "post" { status = .final }
            else if state == "in" { status = .live }
            else if state == "pre" { status = .scheduled }
            else { status = .other }

            var homeName = "Home"
            var awayName = "Away"
            var homeScore: String?
            var awayScore: String?
            var homeAbbrev: String?
            var awayAbbrev: String?
            var homeLogo: String?
            var awayLogo: String?
            var link: String?
            var broadcast: String?

            if let competitions = ev["competitions"] as? [[String: Any]],
               let comp = competitions.first {
                if let links = comp["links"] as? [[String: Any]] {
                    link = links.first?["href"] as? String
                }
                if let broadcasts = comp["broadcasts"] as? [[String: Any]] {
                    let names = broadcasts.compactMap { $0["names"] as? [String] }.flatMap { $0 }
                    if let first = names.first { broadcast = first }
                }
                if broadcast == nil,
                   let geo = comp["geoBroadcasts"] as? [[String: Any]],
                   let media = geo.first?["media"] as? [String: Any],
                   let short = media["shortName"] as? String {
                    broadcast = short
                }

                if let competitors = comp["competitors"] as? [[String: Any]] {
                    // Golf / racing / MMA often rank-ordered competitors.
                    if league == .f1 || league == .pga || league == .ufc || league == .tennis {
                        let parsed = parseRankedCompetitors(competitors)
                        if let first = parsed.first {
                            awayName = first.name
                            awayScore = first.score
                            awayAbbrev = first.abbrev
                            awayLogo = first.logo
                        }
                        if parsed.count > 1 {
                            homeName = parsed[1].name
                            homeScore = parsed[1].score
                            homeAbbrev = parsed[1].abbrev
                            homeLogo = parsed[1].logo
                        } else {
                            homeName = detail.isEmpty ? league.title : detail
                        }
                    } else {
                        for c in competitors {
                            let parsed = parseCompetitor(c)
                            let homeAway = (c["homeAway"] as? String)?.lowercased()
                            if homeAway == "home" {
                                homeName = parsed.name
                                homeScore = parsed.score
                                homeAbbrev = parsed.abbrev
                                homeLogo = parsed.logo
                            } else {
                                awayName = parsed.name
                                awayScore = parsed.score
                                awayAbbrev = parsed.abbrev
                                awayLogo = parsed.logo
                            }
                        }
                    }
                }
            }

            let headline: String?
            switch league {
            case .f1, .pga, .ufc, .tennis:
                headline = detail.isEmpty ? name : "\(name) · \(detail)"
            default:
                headline = nil
            }

            out.append(SportsEvent(
                id: id,
                league: league,
                name: name,
                detail: detail,
                status: status,
                homeName: homeName,
                awayName: awayName,
                homeScore: homeScore,
                awayScore: awayScore,
                homeAbbrev: homeAbbrev,
                awayAbbrev: awayAbbrev,
                homeLogoURL: homeLogo,
                awayLogoURL: awayLogo,
                statusText: detail,
                startDate: start,
                linkURL: link,
                headlineScore: headline,
                broadcast: broadcast
            ))
        }
        return out
    }

    private struct ParsedCompetitor {
        var name: String
        var score: String?
        var abbrev: String?
        var logo: String?
    }

    private func parseCompetitor(_ c: [String: Any]) -> ParsedCompetitor {
        let team = c["team"] as? [String: Any]
        let athlete = c["athlete"] as? [String: Any]
        let display = (team?["displayName"] as? String)
            ?? (team?["shortDisplayName"] as? String)
            ?? (athlete?["displayName"] as? String)
            ?? (c["name"] as? String)
            ?? "Team"
        let abbrev = team?["abbreviation"] as? String
        let logo = team?["logo"] as? String
            ?? (team?["logos"] as? [[String: Any]])?.first?["href"] as? String
            ?? athlete?["headshot"] as? String
        let score = c["score"] as? String
            ?? (c["linescores"] as? [[String: Any]])?.last.flatMap { $0["value"] as? NSNumber }?.stringValue
        return ParsedCompetitor(name: display, score: score, abbrev: abbrev, logo: logo)
    }

    private func parseRankedCompetitors(_ competitors: [[String: Any]]) -> [ParsedCompetitor] {
        competitors
            .sorted {
                let o0 = ($0["order"] as? Int) ?? ($0["order"] as? NSNumber)?.intValue ?? 99
                let o1 = ($1["order"] as? Int) ?? ($1["order"] as? NSNumber)?.intValue ?? 99
                return o0 < o1
            }
            .map { parseCompetitor($0) }
    }

    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    private static func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}
