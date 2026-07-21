import Foundation

/// Public ESPN CDN scoreboard (no API key). Shape can change — fail soft.
actor ESPNScoreboardClient {
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 20
        return URLSession(configuration: c)
    }()

    func fetchEvents(league: SportsLeague, date: Date = Date()) async throws -> [SportsEvent] {
        let day = Self.dayString(date)
        // site.api.espn.com/apis/site/v2/sports/{path}/scoreboard?dates=YYYYMMDD
        let path = league.espnPath
        var components = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/scoreboard")
        components?.queryItems = [URLQueryItem(name: "dates", value: day)]
        guard let url = components?.url else { return [] }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try parseScoreboard(data: data, league: league)
    }

    private func parseScoreboard(data: Data, league: SportsLeague) throws -> [SportsEvent] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let eventsJSON = root["events"] as? [[String: Any]] ?? []
        var out: [SportsEvent] = []

        for ev in eventsJSON {
            let id = (ev["id"] as? String) ?? UUID().uuidString
            let name = (ev["name"] as? String) ?? (ev["shortName"] as? String) ?? "Event"
            let dateStr = ev["date"] as? String
            let start = dateStr.flatMap { ISO8601DateFormatter().date(from: $0) }

            let statusObj = ev["status"] as? [String: Any]
            let typeObj = statusObj?["type"] as? [String: Any]
            let state = (typeObj?["state"] as? String)?.lowercased() ?? ""
            let completed = typeObj?["completed"] as? Bool ?? false
            let detail = (typeObj?["detail"] as? String) ?? (typeObj?["shortDetail"] as? String) ?? ""
            let status: SportsEventStatus
            if completed || state == "post" { status = .final }
            else if state == "in" { status = .live }
            else if state == "pre" { status = .scheduled }
            else { status = .other }

            var homeName = "Home"
            var awayName = "Away"
            var homeScore: String?
            var awayScore: String?
            var link: String?

            if let competitions = ev["competitions"] as? [[String: Any]],
               let comp = competitions.first {
                if let links = comp["links"] as? [[String: Any]] {
                    link = links.first?["href"] as? String
                }
                if let competitors = comp["competitors"] as? [[String: Any]] {
                    for c in competitors {
                        let team = c["team"] as? [String: Any]
                        let display = (team?["displayName"] as? String)
                            ?? (team?["shortDisplayName"] as? String)
                            ?? (team?["name"] as? String)
                            ?? "Team"
                        let score = c["score"] as? String
                        let homeAway = (c["homeAway"] as? String)?.lowercased()
                        if homeAway == "home" {
                            homeName = display
                            homeScore = score
                        } else {
                            awayName = display
                            awayScore = score
                        }
                    }
                }
            }

            // F1 / racing sometimes uses different competitor layout — keep name as headline.
            let headline: String?
            if league == .f1 {
                headline = detail.isEmpty ? name : "\(name) · \(detail)"
            } else {
                headline = nil
            }

            out.append(SportsEvent(
                id: "\(league.rawValue)-\(id)",
                league: league,
                name: name,
                detail: detail,
                status: status,
                homeName: homeName,
                awayName: awayName,
                homeScore: homeScore,
                awayScore: awayScore,
                statusText: detail,
                startDate: start,
                linkURL: link,
                headlineScore: headline
            ))
        }
        return out
    }

    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }
}
