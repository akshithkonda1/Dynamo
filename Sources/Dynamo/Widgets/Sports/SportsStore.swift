import Foundation

@MainActor
final class SportsStore: ObservableObject {
    static let shared = SportsStore()

    @Published private(set) var eventsByLeague: [SportsLeague: [SportsEvent]] = [:]
    @Published private(set) var liveAllEvents: [SportsEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?
    @Published var browseMode: SportsBrowseMode = .league(.nba)
    @Published var categoryFilter: SportsCategory = .all
    @Published var followOnly = false
    @Published var follow = SportsFollowList(teamNames: [])

    private let client = ESPNScoreboardClient()
    private var timer: Timer?
    private let followKey = "dynamo.sports.follow"
    private let leagueKey = "dynamo.sports.selectedLeague"
    private let cacheDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Dynamo/SportsCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var lastScores: [String: String] = [:]
    private var lastStatus: [String: SportsEventStatus] = [:]
    var onScorePeek: ((NotchSneakPeek) -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: followKey),
           let decoded = try? JSONDecoder().decode(SportsFollowList.self, from: data) {
            follow = decoded
        }
        if let raw = UserDefaults.standard.string(forKey: leagueKey),
           let league = SportsLeague(rawValue: raw) {
            browseMode = .league(league)
            loadCache(for: league)
        } else {
            loadCache(for: .nba)
        }
    }

    var selectedLeague: SportsLeague? {
        if case .league(let l) = browseMode { return l }
        return nil
    }

    func start() {
        refreshCurrent()
        // Warm a few high-traffic boards in background.
        Task { await prefetchCore() }
        let t = Timer(timeInterval: 35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCurrent() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func selectLiveAll() {
        browseMode = .liveAll
        refreshCurrent()
    }

    func select(_ league: SportsLeague) {
        browseMode = .league(league)
        UserDefaults.standard.set(league.rawValue, forKey: leagueKey)
        if eventsByLeague[league] == nil {
            loadCache(for: league)
        }
        refreshCurrent()
    }

    func refreshCurrent() {
        switch browseMode {
        case .liveAll:
            refreshLiveAll()
        case .league(let league):
            refresh(league: league)
        }
    }

    func refresh(league: SportsLeague) {
        isLoading = true
        lastError = nil
        Task {
            let events = await client.fetchEvents(league: league)
            await MainActor.run {
                self.eventsByLeague[league] = Array(events.prefix(56))
                self.isLoading = false
                self.lastUpdated = Date()
                if events.isEmpty {
                    self.lastError = self.eventsByLeague[league]?.isEmpty == false ? nil : "No games in window"
                } else {
                    self.lastError = nil
                }
                self.saveCache(events, league: league)
                self.detectChanges(events)
            }
        }
    }

    func refreshLiveAll() {
        isLoading = true
        lastError = nil
        Task {
            let events = await client.fetchLiveAcross(SportsLeague.liveAggregateLeagues)
            await MainActor.run {
                self.liveAllEvents = events
                self.isLoading = false
                self.lastUpdated = Date()
                self.lastError = events.isEmpty ? "No live games right now" : nil
                self.detectChanges(events)
            }
        }
    }

    private func prefetchCore() async {
        let core: [SportsLeague] = [.nba, .nfl, .nhl, .mlb, .epl]
        for league in core {
            let events = await client.fetchEvents(league: league)
            await MainActor.run {
                if !events.isEmpty {
                    self.eventsByLeague[league] = Array(events.prefix(40))
                    self.saveCache(events, league: league)
                }
            }
        }
    }

    var currentEvents: [SportsEvent] {
        let base: [SportsEvent]
        switch browseMode {
        case .liveAll:
            base = liveAllEvents
        case .league(let league):
            base = eventsByLeague[league] ?? []
        }
        if followOnly {
            return base.filter { isFollowed($0) }
        }
        return base
    }

    var liveEvents: [SportsEvent] { currentEvents.filter { $0.status == .live } }
    var upcomingEvents: [SportsEvent] {
        currentEvents.filter { $0.status == .scheduled || $0.status == .delayed }
    }
    var finalEvents: [SportsEvent] { currentEvents.filter { $0.status == .final } }

    var liveCount: Int { liveEvents.count }

    var globalLiveCount: Int {
        let fromCache = eventsByLeague.values.flatMap { $0 }.filter(\.isLive)
        let merged = Dictionary(uniqueKeysWithValues: (fromCache + liveAllEvents).map { ($0.id, $0) })
        return merged.count
    }

    var liveFollowed: SportsEvent? {
        let pool = eventsByLeague.values.flatMap { $0 } + liveAllEvents
        if let f = pool.first(where: { $0.isLive && isFollowed($0) }) { return f }
        if case .league(let l) = browseMode {
            return (eventsByLeague[l] ?? []).first(where: \.isLive)
        }
        return liveAllEvents.first
    }

    var nextFollowedScheduled: SportsEvent? {
        guard !follow.teamNames.isEmpty else { return nil }
        let pool = eventsByLeague.values.flatMap { $0 } + liveAllEvents
        return pool
            .filter { ($0.status == .scheduled || $0.status == .delayed) && isFollowed($0) }
            .min(by: { ($0.startDate ?? Date.distantFuture) < ($1.startDate ?? Date.distantFuture) })
    }

    var chipLeagues: [SportsLeague] {
        categoryFilter.leagues(includingAggregate: true)
    }

    func isFollowed(_ event: SportsEvent) -> Bool {
        guard !follow.teamNames.isEmpty else { return false }
        let names = follow.teamNames
        let home = event.homeName.lowercased()
        let away = event.awayName.lowercased()
        let ha = event.homeAbbrev?.lowercased() ?? ""
        let aa = event.awayAbbrev?.lowercased() ?? ""
        return names.contains { t in
            home.contains(t) || away.contains(t) || ha == t || aa == t
        }
    }

    func toggleFollow(teamName: String) {
        let key = teamName.lowercased()
        if let idx = follow.teamNames.firstIndex(of: key) {
            follow.teamNames.remove(at: idx)
        } else {
            follow.teamNames.append(key)
        }
        if let data = try? JSONEncoder().encode(follow) {
            UserDefaults.standard.set(data, forKey: followKey)
        }
        objectWillChange.send()
    }

    private func detectChanges(_ events: [SportsEvent]) {
        for ev in events {
            let scoreKey = "\(ev.homeScore ?? "-")-\(ev.awayScore ?? "-")"
            let prevScore = lastScores[ev.id]
            let prevStatus = lastStatus[ev.id]
            lastScores[ev.id] = scoreKey
            lastStatus[ev.id] = ev.status

            guard isFollowed(ev) else { continue }

            if prevStatus == .scheduled, ev.status == .live {
                onScorePeek?(NotchSneakPeek(
                    systemImage: ev.league.systemImage,
                    title: "\(ev.displayAway) @ \(ev.displayHome)",
                    subtitle: "Live · \(ev.league.title)",
                    urgency: .high,
                    detail: ev.statusText
                ))
                continue
            }

            guard let prevScore, prevScore != scoreKey else { continue }
            if FocusController.shared.isMeetingActive { continue }
            let title = "\(ev.displayAway) \(ev.awayScore ?? "") – \(ev.homeScore ?? "") \(ev.displayHome)"
            onScorePeek?(NotchSneakPeek(
                systemImage: ev.league.systemImage,
                title: title,
                subtitle: ev.isLive ? "Score · \(ev.league.title)" : "Final · \(ev.league.title)",
                urgency: .normal,
                detail: ev.statusText
            ))
        }
    }

    private func cacheURL(for league: SportsLeague) -> URL {
        cacheDir.appendingPathComponent("\(league.rawValue).json")
    }

    private func saveCache(_ events: [SportsEvent], league: SportsLeague) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: cacheURL(for: league), options: .atomic)
    }

    private func loadCache(for league: SportsLeague) {
        let url = cacheURL(for: league)
        guard let data = try? Data(contentsOf: url),
              let events = try? JSONDecoder().decode([SportsEvent].self, from: data)
        else { return }
        eventsByLeague[league] = events
    }
}
