import Foundation
import MusicKit

/// Enriches `NowPlayingInfo` with Apple Music catalog data, queue access,
/// and library actions. Acts as a pure additive layer — the existing
/// MediaRemote / AppleScript chain remains the source of truth for play state.
///
/// All methods are no-ops when authorization is denied or Spotify is playing.
@available(macOS 12.0, *)
@MainActor
final class MusicKitBridge: ObservableObject {
    static let shared = MusicKitBridge()

    @Published private(set) var authStatus: MusicAuthorization.Status = .notDetermined

    /// Latest catalog enrichment for the current track. Nil until first lookup completes.
    @Published private(set) var currentEnrichment: MusicKitEnrichment?

    /// Called by `MediaRemoteNowPlayingProvider` when enrichment arrives so it can re-merge.
    var onEnrichmentAvailable: (() -> Void)?

    private var enrichmentInFlight: String?   // trackKey currently being fetched

    private init() {}

    var isAuthorized: Bool { authStatus == .authorized }

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() async {
        guard authStatus == .notDetermined else { return }
        authStatus = await MusicAuthorization.request()
    }

    // MARK: - Catalog Enrichment

    /// Fetch genre, release year, explicit flag, high-res artwork URL, and upcoming
    /// queue for `trackKey = "\(title)\u{1}\(artist)\u{1}\(album)"`.
    /// Safe to call repeatedly — guards against duplicate in-flight requests.
    func enrich(title: String, artist: String, album: String, trackKey: String) async {
        guard isAuthorized, !title.isEmpty else { return }
        guard currentEnrichment?.trackKey != trackKey else { return }
        guard enrichmentInFlight != trackKey else { return }
        enrichmentInFlight = trackKey

        defer { if enrichmentInFlight == trackKey { enrichmentInFlight = nil } }

        var request = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [Song.self])
        request.limit = 5
        guard let response = try? await request.response() else { return }

        // Best match: prefer exact title AND artist; fall back to first result
        let candidate = response.songs.first(where: {
            $0.title.caseInsensitiveCompare(title) == .orderedSame
                && (artist.isEmpty || $0.artistName.localizedCaseInsensitiveContains(artist))
        }) ?? response.songs.first

        guard let song = candidate else { return }

        let year = song.releaseDate.map { Calendar.current.component(.year, from: $0) }
        let artworkURL = song.artwork?.url(width: 600, height: 600)
        let genre = song.genreNames.first(where: { $0 != "Music" })
        let explicit = song.contentRating == .explicit
        let upcoming = await fetchUpcomingTracks()

        let enrichment = MusicKitEnrichment(
            catalogID: song.id.rawValue,
            genre: genre,
            releaseYear: year,
            isExplicit: explicit,
            highResArtworkURL: artworkURL,
            upcomingTracks: upcoming,
            trackKey: trackKey
        )

        // Only publish if the track hasn't changed underneath us
        guard enrichmentInFlight == nil || enrichmentInFlight == trackKey else { return }
        currentEnrichment = enrichment
        onEnrichmentAvailable?()
    }

    // MARK: - Queue

    private func fetchUpcomingTracks() async -> [UpcomingTrackInfo] {
        guard isAuthorized else { return [] }

        return await withTaskGroup(of: [UpcomingTrackInfo].self) { group in
            group.addTask { await self.collectQueueEntries() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return []
            }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    private func collectQueueEntries() async -> [UpcomingTrackInfo] {
        let player = SystemMusicPlayer.shared
        var result: [UpcomingTrackInfo] = []
        var pastCurrent = false
        var count = 0

        guard let currentEntry = player.queue.currentEntry else { return [] }

        for await entry in player.queue.entries {
            if !pastCurrent {
                if entry.id == currentEntry.id { pastCurrent = true }
                continue
            }
            if let song = entry.item as? Song {
                result.append(UpcomingTrackInfo(
                    id: song.id.rawValue,
                    title: song.title,
                    artist: song.artistName,
                    artworkURL: song.artwork?.url(width: 160, height: 160),
                    albumTitle: song.albumTitle ?? ""
                ))
            }
            count += 1
            if count >= 5 { break }
        }
        return result
    }

    // MARK: - Library (Like / Add)

    /// Adds the track to the Apple Music library. Returns true if already in library or
    /// successfully added. Returns false when unauthorized or catalog lookup fails.
    func toggleLike(catalogID: String) async -> Bool {
        guard isAuthorized else { return false }
        let itemID = MusicItemID(catalogID)
        var lookup = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: itemID)
        lookup.limit = 1
        guard let response = try? await lookup.response(),
              let song = response.items.first else { return false }

        if await isInLibrary(catalogID: catalogID) { return true }
        try? await MusicLibrary.shared.add(song)
        return true
    }

    func isInLibrary(catalogID: String) async -> Bool {
        guard isAuthorized else { return false }
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, equalTo: MusicItemID(catalogID))
        request.limit = 1
        let response = try? await request.response()
        return response?.items.isEmpty == false
    }

    // MARK: - Transport (Apple Music only)

    func play() async {
        try? await SystemMusicPlayer.shared.play()
    }

    func pause() {
        SystemMusicPlayer.shared.pause()
    }

    func skipToNext() async {
        try? await SystemMusicPlayer.shared.skipToNextEntry()
    }

    func skipToPrevious() async {
        try? await SystemMusicPlayer.shared.skipToPreviousEntry()
    }
}

// MARK: - Enrichment result

/// Immutable snapshot of catalog data for one track.
struct MusicKitEnrichment {
    let catalogID: String
    let genre: String?
    let releaseYear: Int?
    let isExplicit: Bool
    let highResArtworkURL: URL?
    let upcomingTracks: [UpcomingTrackInfo]
    /// Matches `"\(title)\u{1}\(artist)\u{1}\(album)"` in provider chain.
    let trackKey: String
}
