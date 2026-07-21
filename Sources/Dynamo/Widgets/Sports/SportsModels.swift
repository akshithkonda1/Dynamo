import Foundation

enum SportsLeague: String, CaseIterable, Identifiable, Codable {
    case nba
    case nfl
    case mls
    case soccer
    case f1

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nba: return "NBA"
        case .nfl: return "NFL"
        case .mls: return "MLS"
        case .soccer: return "Soccer"
        case .f1: return "F1"
        }
    }

    var systemImage: String {
        switch self {
        case .nba: return "basketball.fill"
        case .nfl: return "football.fill"
        case .mls, .soccer: return "figure.soccer"
        case .f1: return "flag.checkered"
        }
    }

    /// Primary ESPN path (single-league chips).
    var espnPath: String {
        switch self {
        case .nba: return "basketball/nba"
        case .nfl: return "football/nfl"
        case .mls: return "soccer/usa.1"
        case .soccer: return "soccer/eng.1" // EPL primary; fan-out adds more
        case .f1: return "racing/f1"
        }
    }

    /// Extra free scoreboard paths merged for this chip (soccer breadth).
    var espnExtraPaths: [String] {
        switch self {
        case .soccer:
            return [
                "soccer/eng.1",
                "soccer/usa.1",
                "soccer/uefa.champions",
                "soccer/esp.1",
                "soccer/fifa.world"
            ]
        case .mls:
            return ["soccer/usa.1"]
        default:
            return [espnPath]
        }
    }
}

enum SportsEventStatus: String, Codable, Equatable {
    case scheduled
    case live
    case final
    case delayed
    case other

    var label: String {
        switch self {
        case .scheduled: return "Soon"
        case .live: return "Live"
        case .final: return "Final"
        case .delayed: return "Delay"
        case .other: return "—"
        }
    }

    var sectionTitle: String {
        switch self {
        case .live: return "Live"
        case .scheduled, .delayed: return "Upcoming"
        case .final: return "Final"
        case .other: return "Other"
        }
    }
}

struct SportsEvent: Identifiable, Equatable, Codable {
    let id: String
    let league: SportsLeague
    let name: String
    let detail: String
    let status: SportsEventStatus
    let homeName: String
    let awayName: String
    let homeScore: String?
    let awayScore: String?
    let homeAbbrev: String?
    let awayAbbrev: String?
    let homeLogoURL: String?
    let awayLogoURL: String?
    let statusText: String
    let startDate: Date?
    let linkURL: String?
    let headlineScore: String?
    let broadcast: String?

    var isLive: Bool { status == .live }

    var displayAway: String { awayAbbrev?.nilIfEmpty ?? awayName }
    var displayHome: String { homeAbbrev?.nilIfEmpty ?? homeName }
}

struct SportsFollowList: Codable, Equatable {
    var teamNames: [String]
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
