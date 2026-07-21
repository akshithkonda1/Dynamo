import Foundation

enum SportsLeague: String, CaseIterable, Identifiable, Codable {
    case nba
    case nfl
    case mls
    case soccer // FIFA / intl + top leagues via ESPN soccer scoreboard
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

    /// ESPN site/league path segment for scoreboard API.
    var espnPath: String {
        switch self {
        case .nba: return "basketball/nba"
        case .nfl: return "football/nfl"
        case .mls: return "soccer/usa.1"
        case .soccer: return "soccer/fifa.world"
        case .f1: return "racing/f1"
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
        case .scheduled: return "Scheduled"
        case .live: return "Live"
        case .final: return "Final"
        case .delayed: return "Delayed"
        case .other: return ""
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
    let statusText: String
    let startDate: Date?
    let linkURL: String?
    /// For F1 / non-matchup: single headline score line.
    let headlineScore: String?

    var isLive: Bool { status == .live }
}

struct SportsFollowList: Codable, Equatable {
    var teamNames: [String] // lowercase match against home/away
}
