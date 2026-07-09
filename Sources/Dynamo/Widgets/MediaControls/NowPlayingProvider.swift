import Foundation

/// Decouples Media Controls UI from *how* now-playing data is obtained.
/// Swap `MockNowPlayingProvider` for a real `MediaRemote` implementation
/// without touching any view code.
struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var artworkData: Data?

    static let empty = NowPlayingInfo(
        title: "Not Playing",
        artist: "",
        album: "",
        isPlaying: false,
        artworkData: nil
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
}
