import Foundation

@MainActor
final class SportsStore: ObservableObject {
    static let shared = SportsStore()

    @Published private(set) var eventsByLeague: [SportsLeague: [SportsEvent]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?
    @Published var selectedLeague: SportsLeague = .nba
    @Published var followOnly = false
    @Published var follow = SportsFollowList(teamNames: [])

    private let client = ESPNScoreboardClient()
    private var timer: Timer?
    private let followKey = "dynamo.sports.follow"
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
        loadCache(for: .nba)
    }

    func start() {
        refresh(league: selectedLeague)
        let t = Timer(timeInterval: 35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh(league: self.selectedLeague)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func select(_ league: SportsLeague) {
        selectedLeague = league
        if eventsByLeague[league] == nil {
            loadCache(for: league)
        }
        refresh(league: league)
    }

    func refresh(league: SportsLeague) {
        isLoading = true
        lastError = nil
        Task {
            do {
                let events = try await client.fetchEvents(league: league)
                await MainActor.run {
                    self.eventsByLeague[league] = Array(events.prefix(48))
                    self.isLoading = false
                    self.lastUpdated = Date()
                    self.saveCache(events, league: league)
                    self.detectChanges(events)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.lastError = "Scores unavailable"
                    // Keep cache visible
                }
            }
        }
    }

    var currentEvents: [SportsEvent] {
        let all = eventsByLeague[selectedLeague] ?? []
        if followOnly {
            return all.filter { isFollowed($0) }
        }
        return all
    }

    var liveEvents: [SportsEvent] { currentEvents.filter { $0.status == .live } }
    var upcomingEvents: [SportsEvent] {
        currentEvents.filter { $0.status == .scheduled || $0.status == .delayed }
    }
    var finalEvents: [SportsEvent] { currentEvents.filter { $0.status == .final } }

    var liveCount: Int {
        (eventsByLeague[selectedLeague] ?? []).filter(\.isLive).count
    }

    var liveFollowed: SportsEvent? {
        let all = eventsByLeague.values.flatMap { $0 }
        if let f = all.first(where: { $0.isLive && isFollowed($0) }) { return f }
        return (eventsByLeague[selectedLeague] ?? []).first(where: \.isLive)
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

            // Game went live
            if prevStatus == .scheduled, ev.status == .live {
                onScorePeek?(NotchSneakPeek(
                    systemImage: ev.league.systemImage,
                    title: "\(ev.displayAway) @ \(ev.displayHome)",
                    subtitle: "Tip-off · \(ev.league.title)",
                    urgency: .high,
                    detail: ev.statusText
                ))
                continue
            }

            guard let prevScore, prevScore != scoreKey else { continue }
            // Score change — quiet in Meeting for normal peeks
            if FocusController.shared.isMeetingActive { continue }
            let title = "\(ev.displayAway) \(ev.awayScore ?? "") – \(ev.homeScore ?? "") \(ev.displayHome)"
            onScorePeek?(NotchSneakPeek(
                systemImage: ev.league.systemImage,
                title: title,
                subtitle: ev.isLive ? "Score update · \(ev.league.title)" : "Final · \(ev.league.title)",
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
