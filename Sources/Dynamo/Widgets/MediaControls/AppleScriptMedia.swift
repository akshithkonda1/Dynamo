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

    private init() {}

    // MARK: - Now playing

    /// Prefer the player that is actively playing; otherwise any paused track.
    func currentInfo() -> NowPlayingInfo? {
        let music = infoFromMusic()
        let spotify = infoFromSpotify()

        if let music, music.isPlaying { return music }
        if let spotify, spotify.isPlaying { return spotify }
        if let music, music.title != NowPlayingInfo.empty.title { return music }
        if let spotify, spotify.title != NowPlayingInfo.empty.title { return spotify }
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

    // MARK: - Transport (always target a real app — never media keys)

    func togglePlayPause() {
        switch preferredPlayer() {
        case .music:
            run("tell application id \"\(Self.musicBundle)\" to playpause")
        case .spotify:
            run("tell application id \"\(Self.spotifyBundle)\" to playpause")
        case .none:
            // Last resort: try Music then Spotify without requiring a known track.
            if isRunning(bundleID: Self.musicBundle) {
                run("tell application id \"\(Self.musicBundle)\" to playpause")
            } else if isRunning(bundleID: Self.spotifyBundle) {
                run("tell application id \"\(Self.spotifyBundle)\" to playpause")
            }
        }
    }

    func nextTrack() {
        switch preferredPlayer() ?? (isRunning(bundleID: Self.musicBundle) ? .music : isRunning(bundleID: Self.spotifyBundle) ? .spotify : nil) {
        case .music:
            run("tell application id \"\(Self.musicBundle)\" to next track")
        case .spotify:
            run("tell application id \"\(Self.spotifyBundle)\" to next track")
        case .none:
            break
        }
    }

    func previousTrack() {
        switch preferredPlayer() ?? (isRunning(bundleID: Self.musicBundle) ? .music : isRunning(bundleID: Self.spotifyBundle) ? .spotify : nil) {
        case .music:
            run("tell application id \"\(Self.musicBundle)\" to previous track")
        case .spotify:
            run("tell application id \"\(Self.spotifyBundle)\" to previous track")
        case .none:
            break
        }
    }

    // MARK: - Per-app queries

    private func infoFromMusic() -> NowPlayingInfo? {
        guard isRunning(bundleID: Self.musicBundle) else { return nil }
        // Music: paused still has a current track; only "stopped" is empty.
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
        if let error {
            // Automation not granted yet — silent; UI still works once user allows.
            NSLog("Dynamo AppleScript read error: %@", error.description)
            return nil
        }
        return result.stringValue
    }

    private func run(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("Dynamo AppleScript command error: %@", error.description)
        }
    }
}
