import Foundation

@MainActor
final class SportsStore: ObservableObject {
    static let shared = SportsStore()

    @Published private(set) var eventsByLeague: [SportsLeague: [SportsEvent]] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published var selectedLeague: SportsLeague = .nba
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

    private var lastScores: [String: String] = [:] // eventId -> "home-away"
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
        let t = Timer(timeInterval: 40, repeats: true) { [weak self] _ in
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
                    self.eventsByLeague[league] = events
                    self.isLoading = false
                    self.saveCache(events, league: league)
                    self.detectScoreChanges(events)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.lastError = error.localizedDescription
                    // Keep cache
                }
            }
        }
    }

    var currentEvents: [SportsEvent] {
        eventsByLeague[selectedLeague] ?? []
    }

    var liveFollowed: SportsEvent? {
        let all = eventsByLeague.values.flatMap { $0 }
        return all.first { ev in
            ev.isLive && isFollowed(ev)
        }
    }

    func isFollowed(_ event: SportsEvent) -> Bool {
        guard !follow.teamNames.isEmpty else { return false }
        let names = follow.teamNames
        let home = event.homeName.lowercased()
        let away = event.awayName.lowercased()
        return names.contains { home.contains($0) || away.contains($0) }
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

    private func detectScoreChanges(_ events: [SportsEvent]) {
        for ev in events {
            let scoreKey = "\(ev.homeScore ?? "-")-\(ev.awayScore ?? "-")"
            let prev = lastScores[ev.id]
            lastScores[ev.id] = scoreKey
            guard let prev, prev != scoreKey else { continue }
            guard isFollowed(ev) || follow.teamNames.isEmpty == false && isFollowed(ev) else { continue }
            // Only peek for followed teams.
            guard isFollowed(ev) else { continue }
            guard !FocusController.shared.isMeetingActive else { continue }
            let title = "\(ev.awayName) \(ev.awayScore ?? "") – \(ev.homeScore ?? "") \(ev.homeName)"
            onScorePeek?(NotchSneakPeek(
                systemImage: ev.league.systemImage,
                title: title,
                subtitle: ev.isLive ? "Score update · \(ev.league.title)" : "Final · \(ev.league.title)",
                urgency: ev.isLive ? .normal : .normal,
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
