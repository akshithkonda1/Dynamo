import AppKit
import Foundation

/// Reliable Music / Spotify control and now-playing via AppleScript.
@MainActor
final class AppleScriptMedia {
    static let shared = AppleScriptMedia()

    static let musicBundle = "com.apple.Music"
    static let spotifyBundle = "com.spotify.client"
    private static let sep = "\u{001F}"

    private var artworkCache: [String: Data] = [:]
    private var lastArtworkKey: String?
    /// Track keys with a Spotify artwork fetch already in flight — without
    /// this, every ~1s poll before the async fetch completes re-issues both
    /// the AppleScript "artwork url" query and a fresh network request for
    /// the same image, piling up redundant Apple Events + downloads for as
    /// long as the fetch is slow to land.
    private var pendingSpotifyArtworkKeys: Set<String> = []
    private var playlistCache: [String] = []
    private var playlistCacheAt: Date?

    private init() {}

    enum Player {
        case music
        case spotify
    }

    // MARK: - Now playing

    func currentInfo() -> NowPlayingInfo? {
        let music = infoFromMusic()
        let spotify = infoFromSpotify()

        if let music, music.isPlaying {
            return music.withArtwork(fetchArtworkIfNeeded(for: music, player: .music))
        }
        if let spotify, spotify.isPlaying {
            return musicWithSpotifyArt(spotify)
        }
        if let music, music.title != NowPlayingInfo.empty.title {
            return music.withArtwork(fetchArtworkIfNeeded(for: music, player: .music))
        }
        if let spotify, spotify.title != NowPlayingInfo.empty.title {
            return musicWithSpotifyArt(spotify)
        }
        return nil
    }

    func preferredPlayer() -> Player? {
        let music = infoFromMusic()
        let spotify = infoFromSpotify()
        if let music, music.isPlaying { return .music }
        if let spotify, spotify.isPlaying { return .spotify }
        if isRunning(bundleID: Self.musicBundle) { return .music }
        if isRunning(bundleID: Self.spotifyBundle) { return .spotify }
        return nil
    }

    // MARK: - Transport

    /// Absolute play/pause (not `playpause` toggle) so dual-firing or stale
    /// state can't cancel itself out.
    func setPlaying(_ shouldPlay: Bool) {
        guard let player = preferredPlayer() ?? fallbackPlayer() else { return }
        switch player {
        case .music:
            run(shouldPlay
                ? "tell application id \"\(Self.musicBundle)\" to play"
                : "tell application id \"\(Self.musicBundle)\" to pause")
        case .spotify:
            run(shouldPlay
                ? "tell application id \"\(Self.spotifyBundle)\" to play"
                : "tell application id \"\(Self.spotifyBundle)\" to pause")
        }
    }

    func togglePlayPause() {
        // Fallback when caller doesn't know desired state — still prefer absolute
        // commands from current player state when we can read it.
        if let info = currentInfo() {
            setPlaying(!info.isPlaying)
            return
        }
        guard let player = preferredPlayer() ?? fallbackPlayer() else { return }
        switch player {
        case .music:
            run("tell application id \"\(Self.musicBundle)\" to playpause")
        case .spotify:
            run("tell application id \"\(Self.spotifyBundle)\" to playpause")
        }
    }

    /// True when Music or Spotify is the intended transport target.
    var hasScriptablePlayer: Bool {
        preferredPlayer() != nil || fallbackPlayer() != nil
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

    // MARK: - Open app / reveal track

    /// Activate Music or Spotify and reveal the current track (and its playlist context in Music).
    func openConnectedApp() {
        switch preferredPlayer() ?? fallbackPlayer() {
        case .music:
            // reveal current track jumps Library/playlist UI to that song.
            run("""
            tell application id "\(Self.musicBundle)"
                activate
                try
                    reveal current track
                end try
            end tell
            """)
        case .spotify:
            run("""
            tell application id "\(Self.spotifyBundle)"
                activate
            end tell
            """)
        case .none:
            // Default to Music if nothing is known.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.musicBundle) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Playlists (Music)

    /// User playlists from Music.app (cached ~30s).
    func musicPlaylists() -> [String] {
        guard isRunning(bundleID: Self.musicBundle) else { return playlistCache }
        if let at = playlistCacheAt, Date().timeIntervalSince(at) < 30, !playlistCache.isEmpty {
            return playlistCache
        }
        let script = """
        tell application id "\(Self.musicBundle)"
            try
                set names to name of every user playlist
                set AppleScript's text item delimiters to "\(Self.sep)"
                set out to names as text
                set AppleScript's text item delimiters to ""
                return out
            on error
                return ""
            end try
        end tell
        """
        guard let raw = runReturning(script), !raw.isEmpty else {
            return playlistCache
        }
        let names = raw.components(separatedBy: Self.sep)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "Music" && $0 != "Music Videos" }
        playlistCache = names
        playlistCacheAt = Date()
        return names
    }

    func playPlaylist(named name: String) {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        switch preferredPlayer() ?? fallbackPlayer() ?? .music {
        case .music:
            run("""
            tell application id "\(Self.musicBundle)"
                try
                    play user playlist "\(escaped)"
                on error
                    try
                        play playlist "\(escaped)"
                    end try
                end try
            end tell
            """)
        case .spotify:
            // Spotify has no stable "play playlist by name" without URIs.
            run("tell application id \"\(Self.spotifyBundle)\" to activate")
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
        // IMPORTANT: do not use short AppleScript locals like `st` — Music’s
        // dictionary treats `st` as reserved ("Expected expression but found st"),
        // which silently broke now-playing metadata while transport still worked.
        let script = """
        tell application id "\(Self.musicBundle)"
            try
                set playerStateText to (player state as string)
                if playerStateText is "stopped" then return ""
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set isPlayingFlag to (playerStateText is "playing")
                set playlistName to ""
                try
                    set playlistName to name of current playlist
                end try
                set elapsedSeconds to player position
                set durationSeconds to duration of current track
                return trackName & "\(s)" & trackArtist & "\(s)" & trackAlbum & "\(s)" & isPlayingFlag & "\(s)" & playlistName & "\(s)" & elapsedSeconds & "\(s)" & durationSeconds
            on error
                return ""
            end try
        end tell
        """
        return parse(runReturning(script), source: .music)
    }

    private func infoFromSpotify() -> NowPlayingInfo? {
        guard isRunning(bundleID: Self.spotifyBundle) else { return nil }
        let s = Self.sep
        let script = """
        tell application id "\(Self.spotifyBundle)"
            try
                set playerStateText to (player state as string)
                if playerStateText is "stopped" then return ""
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set isPlayingFlag to (playerStateText is "playing")
                set elapsedSeconds to player position
                set durationSeconds to (duration of current track) / 1000
                return trackName & "\(s)" & trackArtist & "\(s)" & trackAlbum & "\(s)" & isPlayingFlag & "\(s)" & "" & "\(s)" & elapsedSeconds & "\(s)" & durationSeconds
            on error
                return ""
            end try
        end tell
        """
        return parse(runReturning(script), source: .spotify)
    }

    /// Absolute seek in seconds for Music / Spotify.
    func seek(to elapsed: TimeInterval) {
        let clamped = max(0, elapsed)
        // AppleScript reals need a plain decimal form.
        let value = String(format: "%.3f", clamped)
        switch preferredPlayer() ?? fallbackPlayer() {
        case .music:
            run("tell application id \"\(Self.musicBundle)\" to set player position to \(value)")
        case .spotify:
            run("tell application id \"\(Self.spotifyBundle)\" to set player position to \(value)")
        case .none:
            break
        }
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
        if let last = lastArtworkKey, last != key {
            artworkCache.removeValue(forKey: last)
            pendingSpotifyArtworkKeys.remove(last)
        }
        lastArtworkKey = key

        switch player {
        case .music:
            // Synchronous, in-process (no network) — safe to just re-run each poll.
            if let data = fetchMusicArtworkData(), !data.isEmpty {
                artworkCache[key] = data
                return data
            }
            return nil
        case .spotify:
            // Async — only kick off one fetch per track, not one per poll tick.
            guard !pendingSpotifyArtworkKeys.contains(key) else { return nil }
            pendingSpotifyArtworkKeys.insert(key)
            fetchSpotifyArtworkData(for: key)
            return nil
        }
    }

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
        let payload = result.data
        if !payload.isEmpty { return payload }
        if result.numberOfItems > 0, let item = result.atIndex(1) {
            let nested = item.data
            if !nested.isEmpty { return nested }
        }
        return nil
    }

    /// Fires the AppleScript + network round trip for `key` exactly once;
    /// caller (`fetchArtworkIfNeeded`) guards re-entry via `pendingSpotifyArtworkKeys`.
    /// Always clears that guard when the fetch resolves, so a transient
    /// failure (Spotify mid-transition, a network hiccup) gets retried on a
    /// later poll instead of leaving artwork permanently stuck as "pending".
    private func fetchSpotifyArtworkData(for key: String) {
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
        else {
            pendingSpotifyArtworkKeys.remove(key)
            return
        }

        Task { [weak self] in
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            await MainActor.run {
                guard let self else { return }
                self.pendingSpotifyArtworkKeys.remove(key)
                guard let data, !data.isEmpty, self.lastArtworkKey == key else { return }
                self.artworkCache[key] = data
            }
        }
    }

    private func parse(_ raw: String?, source: MediaPlayerApp) -> NowPlayingInfo? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: Self.sep)
        guard parts.count >= 4 else { return nil }
        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let playlist = parts.count >= 5 ? parts[4].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let elapsed = parts.count >= 6 ? Double(parts[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        let duration = parts.count >= 7 ? Double(parts[6].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        return NowPlayingInfo(
            title: title,
            artist: parts[1],
            album: parts[2],
            isPlaying: parts[3].lowercased().contains("true"),
            artworkData: nil,
            playlistName: playlist.isEmpty ? nil : playlist,
            sourceApp: source,
            elapsed: max(0, elapsed),
            duration: max(0, duration)
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
        if error != nil {
            rememberAutomationFailure(for: source)
            return nil
        }
        rememberAutomationSuccess(for: source)
        return result.stringValue
    }

    private func run(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil {
            rememberAutomationFailure(for: source)
        } else {
            rememberAutomationSuccess(for: source)
        }
    }

    private func rememberAutomationSuccess(for source: String) {
        if source.contains(Self.musicBundle) || source.contains("Music") {
            PermissionsStore.shared.recordGranted(.automationMusic)
        }
        if source.contains(Self.spotifyBundle) || source.contains("Spotify") {
            PermissionsStore.shared.recordGranted(.automationSpotify)
        }
    }

    private func rememberAutomationFailure(for source: String) {
        // Only mark denied when the error is likely a TCC denial, not "app not running".
        if source.contains(Self.musicBundle) || source.contains("Music") {
            if PermissionsStore.shared.status(for: .automationMusic) == .notDetermined {
                // Leave notDetermined until OS probe / success.
                return
            }
        }
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
