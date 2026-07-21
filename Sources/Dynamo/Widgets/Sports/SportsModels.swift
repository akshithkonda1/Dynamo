import Foundation

/// Major leagues / competitions backed by free ESPN scoreboard paths.
enum SportsLeague: String, CaseIterable, Identifiable, Codable {
    // US majors
    case nba
    case wnba
    case nfl
    case nhl
    case mlb
    case ncaaf
    case ncaab
    // Soccer
    case mls
    case epl
    case laliga
    case seriea
    case bundesliga
    case ligue1
    case ucl
    case uel
    case soccer // multi-path “world soccer” bundle
    // Other
    case f1
    case pga
    case tennis
    case ufc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nba: return "NBA"
        case .wnba: return "WNBA"
        case .nfl: return "NFL"
        case .nhl: return "NHL"
        case .mlb: return "MLB"
        case .ncaaf: return "NCAAF"
        case .ncaab: return "NCAAB"
        case .mls: return "MLS"
        case .epl: return "EPL"
        case .laliga: return "LaLiga"
        case .seriea: return "Serie A"
        case .bundesliga: return "Bundesliga"
        case .ligue1: return "Ligue 1"
        case .ucl: return "UCL"
        case .uel: return "UEL"
        case .soccer: return "Soccer+"
        case .f1: return "F1"
        case .pga: return "PGA"
        case .tennis: return "Tennis"
        case .ufc: return "UFC"
        }
    }

    var shortTitle: String {
        switch self {
        case .bundesliga: return "Bund"
        case .seriea: return "SerieA"
        case .laliga: return "LaLiga"
        case .soccer: return "World"
        default: return title
        }
    }

    var systemImage: String {
        switch self {
        case .nba, .wnba, .ncaab: return "basketball.fill"
        case .nfl, .ncaaf: return "football.fill"
        case .nhl: return "hockey.puck.fill"
        case .mlb: return "baseball.fill"
        case .mls, .epl, .laliga, .seriea, .bundesliga, .ligue1, .ucl, .uel, .soccer:
            return "figure.soccer"
        case .f1: return "flag.checkered"
        case .pga: return "figure.golf"
        case .tennis: return "tennis.racket"
        case .ufc: return "figure.boxing"
        }
    }

    var category: SportsCategory {
        switch self {
        case .nba, .wnba, .nfl, .nhl, .mlb, .ncaaf, .ncaab: return .us
        case .mls, .epl, .laliga, .seriea, .bundesliga, .ligue1, .ucl, .uel, .soccer: return .soccer
        case .f1, .pga, .tennis, .ufc: return .world
        }
    }

    /// Primary ESPN site path under /apis/site/v2/sports/
    var espnPath: String {
        switch self {
        case .nba: return "basketball/nba"
        case .wnba: return "basketball/wnba"
        case .nfl: return "football/nfl"
        case .nhl: return "hockey/nhl"
        case .mlb: return "baseball/mlb"
        case .ncaaf: return "football/college-football"
        case .ncaab: return "basketball/mens-college-basketball"
        case .mls: return "soccer/usa.1"
        case .epl: return "soccer/eng.1"
        case .laliga: return "soccer/esp.1"
        case .seriea: return "soccer/ita.1"
        case .bundesliga: return "soccer/ger.1"
        case .ligue1: return "soccer/fra.1"
        case .ucl: return "soccer/uefa.champions"
        case .uel: return "soccer/uefa.europa"
        case .soccer: return "soccer/eng.1"
        case .f1: return "racing/f1"
        case .pga: return "golf/pga"
        case .tennis: return "tennis/atp"
        case .ufc: return "mma/ufc"
        }
    }

    /// Extra free paths merged for multi-competition chips.
    var espnExtraPaths: [String] {
        switch self {
        case .soccer:
            return [
                "soccer/eng.1", "soccer/esp.1", "soccer/ita.1", "soccer/ger.1", "soccer/fra.1",
                "soccer/usa.1", "soccer/uefa.champions", "soccer/uefa.europa",
                "soccer/fifa.world", "soccer/ned.1", "soccer/por.1"
            ]
        case .tennis:
            return ["tennis/atp", "tennis/wta"]
        case .pga:
            return ["golf/pga", "golf/lpga"]
        case .ncaaf:
            return ["football/college-football"]
        case .ncaab:
            return ["basketball/mens-college-basketball", "basketball/womens-college-basketball"]
        default:
            return [espnPath]
        }
    }

    /// Leagues polled for the “All Live” aggregate.
    static var liveAggregateLeagues: [SportsLeague] {
        [.nba, .wnba, .nfl, .nhl, .mlb, .mls, .epl, .ucl, .ncaaf, .ncaab, .f1, .ufc]
    }
}

enum SportsCategory: String, CaseIterable, Identifiable {
    case all
    case us
    case soccer
    case world

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .us: return "US"
        case .soccer: return "Soccer"
        case .world: return "More"
        }
    }

    func leagues(includingAggregate: Bool) -> [SportsLeague] {
        switch self {
        case .all:
            // Curated chip order for the full list.
            return [
                .nba, .nfl, .nhl, .mlb, .wnba, .ncaaf, .ncaab,
                .epl, .mls, .ucl, .laliga, .seriea, .bundesliga, .ligue1, .uel, .soccer,
                .f1, .pga, .tennis, .ufc
            ]
        case .us:
            return [.nba, .nfl, .nhl, .mlb, .wnba, .ncaaf, .ncaab]
        case .soccer:
            return [.epl, .mls, .ucl, .laliga, .seriea, .bundesliga, .ligue1, .uel, .soccer]
        case .world:
            return [.f1, .pga, .tennis, .ufc]
        }
    }
}

/// Special selection for multi-league live feed (not a SportsLeague raw path).
enum SportsBrowseMode: Equatable {
    case liveAll
    case league(SportsLeague)
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

    var scoreLine: String? {
        if let a = awayScore, let h = homeScore { return "\(a)–\(h)" }
        return nil
    }
}

struct SportsFollowList: Codable, Equatable {
    var teamNames: [String]
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
