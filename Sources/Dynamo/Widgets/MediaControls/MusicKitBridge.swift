import Combine
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
    @Published private(set) var cachedPlaylistNames: [String] = []

    /// Called by `MediaRemoteNowPlayingProvider` when enrichment arrives so it can re-merge.
    var onEnrichmentAvailable: (() -> Void)?

    private var enrichmentInFlight: String?   // trackKey currently being fetched
    private var playerCancellables = Set<AnyCancellable>()
    private var observingPlayer = false

    private init() {}

    var isAuthorized: Bool { authStatus == .authorized }

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() async {
        authStatus = MusicAuthorization.currentStatus
        guard authStatus == .notDetermined else { return }
        authStatus = await MusicAuthorization.request()
        PermissionsStore.shared.refreshFromSystem()
        if isAuthorized {
            startObservingPlayer()
            Task { _ = await libraryPlaylistNames() }
        }
    }

    /// Subscribe to ApplicationMusicPlayer so queue and play state come from MusicKit.
    func startObservingPlayer() {
        guard !observingPlayer else { return }
        guard #available(macOS 14.0, *) else { return }
        observingPlayer = true
        let player = ApplicationMusicPlayer.shared
        player.state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.onEnrichmentAvailable?() }
            .store(in: &playerCancellables)
        player.queue.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.onEnrichmentAvailable?() }
            .store(in: &playerCancellables)
    }

    /// Live Music.app item from MusicKit. Nil when the player has no current entry.
    func playerNowPlaying() -> NowPlayingInfo? {
        guard #available(macOS 14.0, *) else { return nil }
        guard isAuthorized else { return nil }
        let player = ApplicationMusicPlayer.shared
        guard let entry = player.queue.currentEntry else { return nil }
        let playing = player.state.playbackStatus == .playing
        var album = ""
        var duration: TimeInterval = 0
        var catalogID: String?
        if case .song(let song) = entry.item {
            album = song.albumTitle ?? ""
            duration = song.duration ?? 0
            catalogID = song.id.rawValue
        }
        var info = NowPlayingInfo(
            title: entry.title,
            artist: entry.subtitle ?? "",
            album: album,
            isPlaying: playing,
            artworkData: nil,
            playlistName: nil,
            sourceApp: .music,
            elapsed: player.playbackTime,
            duration: duration
        )
        info.musicKitCatalogID = catalogID
        return info
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

        // Resolve Album Motion (animated cover) when Apple Music provides it.
        Task {
            await MusicMotionArtworkLoader.shared.resolve(
                catalogSongID: song.id.rawValue,
                title: title,
                artist: artist,
                album: album,
                trackKey: trackKey
            )
        }
    }

    // MARK: - Queue

    private func fetchUpcomingTracks() async -> [UpcomingTrackInfo] {
        guard #available(macOS 14.0, *) else { return [] }
        let entries = Array(ApplicationMusicPlayer.shared.queue.entries)
        func info(from entry: ApplicationMusicPlayer.Queue.Entry) -> UpcomingTrackInfo {
            var album = ""
            var art: URL?
            var catalog = entry.id
            if case .song(let song) = entry.item {
                album = song.albumTitle ?? ""
                art = song.artwork?.url(width: 120, height: 120)
                catalog = song.id.rawValue
            }
            return UpcomingTrackInfo(
                id: catalog,
                title: entry.title,
                artist: entry.subtitle ?? "",
                artworkURL: art,
                albumTitle: album
            )
        }
        guard let currentID = ApplicationMusicPlayer.shared.queue.currentEntry?.id else {
            return entries.prefix(8).map(info)
        }
        return entries.drop(while: { $0.id != currentID }).dropFirst().prefix(8).map(info)
    }

    // MARK: - Library

    func toggleLike(catalogID: String) async -> Bool {
        let currentlyIn = await isInLibrary(catalogID: catalogID)
        return currentlyIn
    }

    func isInLibrary(catalogID: String) async -> Bool {
        guard isAuthorized, !catalogID.isEmpty else { return false }
        guard #available(macOS 14.0, *) else { return false }
        do {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: MusicItemID(catalogID))
            let response = try await request.response()
            return response.items.contains { $0.id.rawValue == catalogID }
        } catch {
            return false
        }
    }

    func libraryPlaylistNames() async -> [String] {
        guard isAuthorized else { return [] }
        guard #available(macOS 14.0, *) else { return [] }
        do {
            let request = MusicLibraryRequest<Playlist>()
            let response = try await request.response()
            let names = response.items.map(\.name)
            cachedPlaylistNames = names
            return names
        } catch {
            return cachedPlaylistNames
        }
    }

    // MARK: - Transport (ApplicationMusicPlayer on macOS 14+)

    func play() async {
        guard #available(macOS 14.0, *) else { return }
        try? await ApplicationMusicPlayer.shared.play()
    }

    func pause() {
        guard #available(macOS 14.0, *) else { return }
        ApplicationMusicPlayer.shared.pause()
    }

    func skipToNext() async {
        guard #available(macOS 14.0, *) else { return }
        try? await ApplicationMusicPlayer.shared.skipToNextEntry()
    }

    func skipToPrevious() async {
        guard #available(macOS 14.0, *) else { return }
        try? await ApplicationMusicPlayer.shared.skipToPreviousEntry()
    }

    func seek(to elapsed: TimeInterval) {
        guard #available(macOS 14.0, *) else { return }
        ApplicationMusicPlayer.shared.playbackTime = max(0, elapsed)
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
