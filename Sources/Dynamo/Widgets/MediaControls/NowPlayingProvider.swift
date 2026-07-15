import Foundation

/// Which scriptable player is currently providing now-playing info.
enum MediaPlayerApp: String, Equatable {
    case music
    case spotify
    case other
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

    static let empty = NowPlayingInfo(
        title: "Not Playing",
        artist: "",
        album: "",
        isPlaying: false,
        artworkData: nil,
        playlistName: nil,
        sourceApp: nil
    )
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

    /// Bring the connected player to the front and reveal the current track / playlist.
    func openConnectedApp()
    /// User playlists available for switching (Music). Empty if unavailable.
    func availablePlaylists() -> [String]
    /// Start playing the named playlist in the connected Music app.
    func playPlaylist(named name: String)
}

extension NowPlayingProvider {
    func openConnectedApp() {}
    func availablePlaylists() -> [String] { [] }
    func playPlaylist(named name: String) {}
}
