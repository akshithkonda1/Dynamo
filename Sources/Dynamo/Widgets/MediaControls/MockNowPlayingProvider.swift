import Foundation

/// Stub provider used until a real MediaRemote-backed implementation is wired.
@MainActor
final class MockNowPlayingProvider: NowPlayingProvider {
    private(set) var current: NowPlayingInfo = NowPlayingInfo(
        title: "Midnight City",
        artist: "M83",
        album: "Hurry Up, We're Dreaming",
        isPlaying: true,
        artworkData: nil
    )
    var onChange: ((NowPlayingInfo) -> Void)?

    private let catalog: [NowPlayingInfo] = [
        NowPlayingInfo(title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming", isPlaying: true, artworkData: nil),
        NowPlayingInfo(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", isPlaying: true, artworkData: nil),
        NowPlayingInfo(title: "Weightless", artist: "Marconi Union", album: "Weightless", isPlaying: true, artworkData: nil)
    ]
    private var index = 0

    func start() {
        publish()
    }

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

    private func publish() {
        onChange?(current)
    }
}
