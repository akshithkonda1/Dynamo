import Foundation

/// A single entry in the upcoming track queue as surfaced by MusicKit.
struct UpcomingTrackInfo: Equatable, Identifiable {
    let id: String          // MusicItemID.rawValue (stable across sessions)
    let title: String
    let artist: String
    let artworkURL: URL?    // High-res catalog artwork URL (load on demand)
    let albumTitle: String
}

/// Which scriptable player is currently providing now-playing info.
enum MediaPlayerApp: String, Equatable {
    case music
    case spotify
    case other
}

enum RepeatMode: Int, Equatable {
    case none = 0
    case one = 1
    case all = 2
}

/// Decouples Media Controls UI from *how* now-playing data is obtained.
struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var artworkData: Data?
    /// Active playlist / library container name when known (Music `current playlist`).
    var playlistName: String?
    /// App that owns this track (for open-in-app + playlist switching).
    var sourceApp: MediaPlayerApp?
    /// Playback position in seconds (0…duration).
    var elapsed: TimeInterval
    /// Track length in seconds (0 when unknown).
    var duration: TimeInterval
    var isShuffling: Bool = false
    var repeatMode: RepeatMode = .none

    // MARK: MusicKit enrichment (nil/default when MusicKit is unauthorized or Spotify is playing)
    var genre: String? = nil
    var releaseYear: Int? = nil
    var isExplicit: Bool = false
    var musicKitCatalogID: String? = nil
    var upcomingTracks: [UpcomingTrackInfo] = []
    var highResArtworkURL: URL? = nil

    static let empty = NowPlayingInfo(
        title: "Not Playing",
        artist: "",
        album: "",
        isPlaying: false,
        artworkData: nil,
        playlistName: nil,
        sourceApp: nil,
        elapsed: 0,
        duration: 0
    )

    var canSeek: Bool { duration > 0.5 }
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }
}

@MainActor
protocol NowPlayingProvider: AnyObject {
    var current: NowPlayingInfo { get }
    var onChange: ((NowPlayingInfo) -> Void)? { get set }

    func start()
    func stop()
    func togglePlayPause()
    func nextTrack()
    func previousTrack()
    func toggleShuffle()
    func toggleRepeat()

    /// Bring the connected player to the front and reveal the current track / playlist.
    func openConnectedApp()
    /// User playlists available for switching (Music). Empty if unavailable.
    func availablePlaylists() -> [String]
    /// Start playing the named playlist in the connected Music app.
    func playPlaylist(named name: String)
    /// Seek to an absolute position in the current track (seconds).
    func seek(to elapsed: TimeInterval)
}

extension NowPlayingProvider {
    func openConnectedApp() {}
    func availablePlaylists() -> [String] { [] }
    func playPlaylist(named name: String) {}
    func seek(to elapsed: TimeInterval) {}
    func toggleShuffle() {}
    func toggleRepeat() {}
}
