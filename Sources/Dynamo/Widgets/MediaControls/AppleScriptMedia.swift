import AppKit
import Foundation

/// Reliable Music / Spotify control and now-playing via AppleScript.
/// Used when private MediaRemote is empty or transport commands no-op
/// (common on macOS 15.4+ for non-`com.apple.*` hosts).
@MainActor
final class AppleScriptMedia {
    static let shared = AppleScriptMedia()

    private static let musicBundle = "com.apple.Music"
    private static let spotifyBundle = "com.spotify.client"
    /// Field separator that won't appear in track metadata.
    private static let sep = "\u{001F}"

    /// Cache artwork by track key so we don't re-pull JPEG data every poll.
    private var artworkCache: [String: Data] = [:]
    private var lastArtworkKey: String?

    private init() {}

    // MARK: - Now playing

    /// Prefer the player that is actively playing; otherwise any paused track.
    /// Includes album art when available (Music artwork / Spotify artwork URL).
    func currentInfo() -> NowPlayingInfo? {
        let music = infoFromMusic()
        let spotify = infoFromSpotify()

        if let music, music.isPlaying { return music.withArtwork(fetchArtworkIfNeeded(for: music, player: .music)) }
        if let spotify, spotify.isPlaying { return musicWithSpotifyArt(spotify) }
        if let music, music.title != NowPlayingInfo.empty.title {
            return music.withArtwork(fetchArtworkIfNeeded(for: music, player: .music))
        }
        if let spotify, spotify.title != NowPlayingInfo.empty.title {
            return musicWithSpotifyArt(spotify)
        }
        return nil
    }

    /// Which scriptable player should receive transport commands.
    func preferredPlayer() -> Player? {
        let music = infoFromMusic()
        let spotify = infoFromSpotify()
        if let music, music.isPlaying { return .music }
        if let spotify, spotify.isPlaying { return .spotify }
        if isRunning(bundleID: Self.musicBundle) { return .music }
        if isRunning(bundleID: Self.spotifyBundle) { return .spotify }
        return nil
    }

    enum Player {
        case music
        case spotify
    }

    // MARK: - Transport

    func togglePlayPause() {
        switch preferredPlayer() {
        case .music:
            run("tell application id \"\(Self.musicBundle)\" to playpause")
        case .spotify:
            run("tell application id \"\(Self.spotifyBundle)\" to playpause")
        case .none:
            if isRunning(bundleID: Self.musicBundle) {
                run("tell application id \"\(Self.musicBundle)\" to playpause")
            } else if isRunning(bundleID: Self.spotifyBundle) {
                run("tell application id \"\(Self.spotifyBundle)\" to playpause")
            }
        }
    }

    func nextTrack() {
        switch preferredPlayer() ?? fallbackPlayer() {
        case .music: run("tell application id \"\(Self.musicBundle)\" to next track")
        case .spotify: run("tell application id \"\(Self.spotifyBundle)\" to next track")
        case .none: break
        }
    }

    func previousTrack() {
        switch preferredPlayer() ?? fallbackPlayer() {
        case .music: run("tell application id \"\(Self.musicBundle)\" to previous track")
        case .spotify: run("tell application id \"\(Self.spotifyBundle)\" to previous track")
        case .none: break
        }
    }

    private func fallbackPlayer() -> Player? {
        if isRunning(bundleID: Self.musicBundle) { return .music }
        if isRunning(bundleID: Self.spotifyBundle) { return .spotify }
        return nil
    }

    // MARK: - Metadata

    private func infoFromMusic() -> NowPlayingInfo? {
        guard isRunning(bundleID: Self.musicBundle) else { return nil }
        let s = Self.sep
        let script = """
        tell application id "\(Self.musicBundle)"
            try
                set st to player state as string
                if st is "stopped" then return ""
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set p to (st is "playing")
                return t & "\(s)" & a & "\(s)" & al & "\(s)" & p
            on error
                return ""
            end try
        end tell
        """
        return parse(runReturning(script))
    }

    private func infoFromSpotify() -> NowPlayingInfo? {
        guard isRunning(bundleID: Self.spotifyBundle) else { return nil }
        let s = Self.sep
        let script = """
        tell application id "\(Self.spotifyBundle)"
            try
                set st to player state as string
                if st is "stopped" then return ""
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set p to (st is "playing")
                return t & "\(s)" & a & "\(s)" & al & "\(s)" & p
            on error
                return ""
            end try
        end tell
        """
        return parse(runReturning(script))
    }

    private func musicWithSpotifyArt(_ info: NowPlayingInfo) -> NowPlayingInfo {
        info.withArtwork(fetchArtworkIfNeeded(for: info, player: .spotify))
    }

    // MARK: - Artwork

    private func trackKey(_ info: NowPlayingInfo) -> String {
        "\(info.title)|\(info.artist)|\(info.album)"
    }

    private func fetchArtworkIfNeeded(for info: NowPlayingInfo, player: Player) -> Data? {
        let key = trackKey(info)
        if let cached = artworkCache[key] { return cached }

        // Drop previous track's art from memory if we jumped tracks.
        if let last = lastArtworkKey, last != key {
            artworkCache.removeValue(forKey: last)
        }
        lastArtworkKey = key

        let data: Data?
        switch player {
        case .music:
            data = fetchMusicArtworkData()
        case .spotify:
            data = fetchSpotifyArtworkData()
        }
        if let data, !data.isEmpty {
            artworkCache[key] = data
            return data
        }
        return nil
    }

    /// Music exposes artwork as a JPEG picture descriptor via AppleScript.
    private func fetchMusicArtworkData() -> Data? {
        let script = """
        tell application id "\(Self.musicBundle)"
            try
                if (count of artworks of current track) < 1 then return
                return data of artwork 1 of current track
            on error
                return
            end try
        end tell
        """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        let result = appleScript.executeAndReturnError(&error)
        if error != nil { return nil }

        // JPEG picture / TIFF / raw data — `data` is non-optional on NSAppleEventDescriptor.
        let payload = result.data
        if !payload.isEmpty { return payload }
        if result.numberOfItems > 0, let item = result.atIndex(1) {
            let nested = item.data
            if !nested.isEmpty { return nested }
        }
        return nil
    }

    /// Spotify exposes an HTTPS artwork URL — download async and fill the cache
    /// for the next poll (never block the main actor with a semaphore).
    private func fetchSpotifyArtworkData() -> Data? {
        let script = """
        tell application id "\(Self.spotifyBundle)"
            try
                return artwork url of current track as string
            on error
                return ""
            end try
        end tell
        """
        guard let urlString = runReturning(script)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty,
              let url = URL(string: urlString)
        else { return nil }

        // Kick off download; return nil this pass — cache hits on the next refresh.
        let key = lastArtworkKey
        Task { [weak self] in
            let data = await Task.detached {
                try? Data(contentsOf: url)
            }.value
            guard let data, !data.isEmpty else { return }
            await MainActor.run {
                guard let self, let key, self.lastArtworkKey == key else { return }
                self.artworkCache[key] = data
            }
        }
        return nil
    }

    private func parse(_ raw: String?) -> NowPlayingInfo? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: Self.sep)
        guard parts.count >= 4 else { return nil }
        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return NowPlayingInfo(
            title: title,
            artist: parts[1],
            album: parts[2],
            isPlaying: parts[3].lowercased().contains("true"),
            artworkData: nil
        )
    }

    private func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    @discardableResult
    private func runReturning(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    private func run(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}

private extension NowPlayingInfo {
    func withArtwork(_ data: Data?) -> NowPlayingInfo {
        guard let data, !data.isEmpty else { return self }
        var copy = self
        copy.artworkData = data
        return copy
    }
}
