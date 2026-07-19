import Foundation

/// Stub provider used until a real MediaRemote-backed implementation is wired.
@MainActor
final class MockNowPlayingProvider: NowPlayingProvider {
    private(set) var current: NowPlayingInfo = NowPlayingInfo(
        title: "Midnight City",
        artist: "M83",
        album: "Hurry Up, We're Dreaming",
        isPlaying: true,
        artworkData: nil,
        playlistName: "Favorites",
        sourceApp: .music,
        elapsed: 42,
        duration: 244
    )
    var onChange: ((NowPlayingInfo) -> Void)?

    private let catalog: [NowPlayingInfo] = [
        NowPlayingInfo(title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming", isPlaying: true, artworkData: nil, playlistName: "Favorites", sourceApp: .music, elapsed: 0, duration: 244),
        NowPlayingInfo(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", isPlaying: true, artworkData: nil, playlistName: "Favorites", sourceApp: .music, elapsed: 0, duration: 200),
        NowPlayingInfo(title: "Weightless", artist: "Marconi Union", album: "Weightless", isPlaying: true, artworkData: nil, playlistName: "Sleep", sourceApp: .music, elapsed: 0, duration: 480)
    ]
    private var index = 0

    func start() { publish() }
    func stop() {}

    func togglePlayPause() {
        current.isPlaying.toggle()
        publish()
    }

    func nextTrack() {
        index = (index + 1) % catalog.count
        var next = catalog[index]
        next.isPlaying = current.isPlaying
        current = next
        publish()
    }

    func previousTrack() {
        index = (index - 1 + catalog.count) % catalog.count
        var prev = catalog[index]
        prev.isPlaying = current.isPlaying
        current = prev
        publish()
    }

    func openConnectedApp() {}
    func availablePlaylists() -> [String] { ["Favorites", "Sleep", "Driving"] }
    func playPlaylist(named name: String) {
        current.playlistName = name
        publish()
    }

    func seek(to elapsed: TimeInterval) {
        current.elapsed = min(max(0, elapsed), max(current.duration, 0))
        publish()
    }

    private func publish() { onChange?(current) }
}
