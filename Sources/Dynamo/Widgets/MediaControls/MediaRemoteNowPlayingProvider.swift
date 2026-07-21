import AppKit
import Foundation

// MARK: - MediaRemote command IDs (private framework)

private enum MRCommand: UInt32 {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case stop = 3
    case nextTrack = 4
    case previousTrack = 5
}

/// Now-playing source with a layered strategy:
///
/// 1. **MediaRemote** (in-process) when it returns real metadata  
/// 2. **DynamoMediaRemoteHelper** subprocess (helps on macOS 15.4+)  
/// 3. **AppleScript** for Music (`com.apple.Music`) and Spotify  
///
/// Transport always dual-fires MediaRemote *and* AppleScript so play/pause/skip
/// work even when MRSendCommand returns success without controlling the player.
@MainActor
final class MediaRemoteNowPlayingProvider: NowPlayingProvider {
    private(set) var current: NowPlayingInfo = .empty
    var onChange: ((NowPlayingInfo) -> Void)?

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var getNowPlayingInfo: MRMediaRemoteGetNowPlayingInfo?
    private var sendCommand: MRMediaRemoteSendCommand?
    private var registerNotifications: MRMediaRemoteRegisterForNowPlayingNotifications?
    private var getNowPlayingApplicationIsPlaying: MRMediaRemoteGetNowPlayingApplicationIsPlaying?
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var isStarted = false

    private let helperProcess = MediaRemoteHelperProcess()
    private var latestHelperInfo: NowPlayingInfo?
    private var latestMRInfo: NowPlayingInfo?
    private var emptyStreak = 0

    private typealias MRMediaRemoteGetNowPlayingInfo =
        @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias MRMediaRemoteSendCommand =
        @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias MRMediaRemoteRegisterForNowPlayingNotifications =
        @convention(c) (DispatchQueue) -> Void
    private typealias MRMediaRemoteGetNowPlayingApplicationIsPlaying =
        @convention(c) (DispatchQueue, @escaping @convention(block) (ObjCBool) -> Void) -> Void

    func start() {
        guard !isStarted else { return }
        isStarted = true
        loadFramework()
        registerForNotifications()
        startHelperProcess()
        refreshAll()
        // MediaRemote notifications drive most updates; poll is a safety net.
        // 1.5s balances live transport with lower AppleScript / helper cost.
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func stop() {
        isStarted = false
        pollTimer?.invalidate()
        pollTimer = nil
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        if let frameworkHandle {
            dlclose(frameworkHandle)
            self.frameworkHandle = nil
        }
        getNowPlayingInfo = nil
        sendCommand = nil
        registerNotifications = nil
        getNowPlayingApplicationIsPlaying = nil
        helperProcess.stop()
        latestHelperInfo = nil
        latestMRInfo = nil
    }

    private func startHelperProcess() {
        guard helperProcess.isAvailable else {
            NSLog("Dynamo: MediaRemote helper not found — Music/Spotify via AppleScript")
            return
        }
        helperProcess.onPayload = { [weak self] payload in
            guard let self else { return }
            let info = Self.info(fromHelper: payload)
            self.latestHelperInfo = info
            self.publishBest()
        }
        helperProcess.start()
    }

    var isHelperAvailable: Bool { helperProcess.isAvailable }
    var helperPath: String? { helperProcess.resolvedPath }

    // MARK: - Transport

    func togglePlayPause() {
        // Desired end state (absolute). Dual-firing MediaRemote *and* AppleScript
        // `playpause` was toggling twice — play then immediately pause.
        let wantPlaying = !current.isPlaying
        var optimistic = current
        optimistic.isPlaying = wantPlaying
        // Always update the play/pause glyph; metadata may catch up a moment later.
        publish(optimistic)

        let scripted = AppleScriptMedia.shared
        if scripted.hasScriptablePlayer {
            // Music / Spotify: one absolute play/pause command only.
            scripted.setPlaying(wantPlaying)
        } else {
            // Browser / other now-playing: MediaRemote toggle only.
            _ = send(MRCommand.togglePlayPause)
        }
        scheduleRefresh(after: 0.15)
        scheduleRefresh(after: 0.45)
        scheduleRefresh(after: 1.0)
    }

    func nextTrack() {
        let scripted = AppleScriptMedia.shared
        if scripted.hasScriptablePlayer {
            scripted.nextTrack()
        } else {
            _ = send(MRCommand.nextTrack)
        }
        scheduleRefresh(after: 0.25)
        scheduleRefresh(after: 0.7)
    }

    func previousTrack() {
        let scripted = AppleScriptMedia.shared
        if scripted.hasScriptablePlayer {
            scripted.previousTrack()
        } else {
            _ = send(MRCommand.previousTrack)
        }
        scheduleRefresh(after: 0.25)
        scheduleRefresh(after: 0.7)
    }

    func openConnectedApp() {
        AppleScriptMedia.shared.openConnectedApp()
    }

    func availablePlaylists() -> [String] {
        AppleScriptMedia.shared.musicPlaylists()
    }

    func playPlaylist(named name: String) {
        AppleScriptMedia.shared.playPlaylist(named: name)
        scheduleRefresh(after: 0.4)
        scheduleRefresh(after: 1.0)
    }

    func seek(to elapsed: TimeInterval) {
        let duration = current.duration
        let target: TimeInterval
        if duration > 0 {
            target = min(max(0, elapsed), duration)
        } else {
            target = max(0, elapsed)
        }
        // Optimistic scrub so the bar doesn't snap back while AppleScript runs.
        var optimistic = current
        optimistic.elapsed = target
        if !Self.isEmpty(optimistic) {
            publish(optimistic)
        }
        if AppleScriptMedia.shared.hasScriptablePlayer {
            AppleScriptMedia.shared.seek(to: target)
        }
        scheduleRefresh(after: 0.2)
        scheduleRefresh(after: 0.6)
    }

    // MARK: - Framework

    private func loadFramework() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW) else {
            NSLog("Dynamo: failed to dlopen MediaRemote: %s", String(cString: dlerror()))
            return
        }
        frameworkHandle = handle

        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlayingInfo = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingInfo.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommand = unsafeBitCast(sym, to: MRMediaRemoteSendCommand.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            registerNotifications = unsafeBitCast(sym, to: MRMediaRemoteRegisterForNowPlayingNotifications.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            getNowPlayingApplicationIsPlaying = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingApplicationIsPlaying.self)
        }

        registerNotifications?(DispatchQueue.main)
    }

    private func registerForNotifications() {
        // MediaRemote posts these via DistributedNotificationCenter only —
        // the poster is whatever process actually owns "now playing" state
        // (e.g. Music.app, Spotify), a different process than Dynamo, and
        // plain NotificationCenter never delivers across processes. A local
        // registration for the same names would just be a no-op that never
        // fires; this codebase used to register both, unnecessarily.
        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            // Some systems post under shorter names:
            "MRMediaRemoteNowPlayingInfoDidChangeNotification",
            "MRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
        ]
        let center = DistributedNotificationCenter.default()
        for name in names {
            let token = center.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshAll() }
            }
            observers.append(token)
        }
    }

    // MARK: - Refresh / merge

    private func scheduleRefresh(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.refreshAll()
        }
    }

    private func refreshAll() {
        refreshMediaRemote()
        // AppleScript is cheap enough at 1 Hz and is the reliable path for Music.
        publishBest()
    }

    private func refreshMediaRemote() {
        guard let getNowPlayingInfo else { return }

        getNowPlayingInfo(DispatchQueue.main) { [weak self] cfDict in
            Task { @MainActor in
                guard let self else { return }
                guard let cfDict = cfDict as NSDictionary? else {
                    self.latestMRInfo = nil
                    self.publishBest()
                    return
                }
                var info = self.parse(cfDict)
                if Self.isEmpty(info) {
                    self.latestMRInfo = nil
                    self.publishBest()
                    return
                }
                if let getPlaying = self.getNowPlayingApplicationIsPlaying {
                    getPlaying(DispatchQueue.main) { [weak self] playing in
                        Task { @MainActor in
                            guard let self else { return }
                            info.isPlaying = playing.boolValue
                            self.latestMRInfo = info
                            self.publishBest()
                        }
                    }
                } else {
                    self.latestMRInfo = info
                    self.publishBest()
                }
            }
        }
    }

    /// Pick the richest non-empty source. Prefer playing over paused when tied.
    /// Merge artwork from any candidate that shares the same track identity.
    private func publishBest() {
        let scripted = AppleScriptMedia.shared.currentInfo()
        let candidates = [latestMRInfo, latestHelperInfo, scripted].compactMap { $0 }.filter { !Self.isEmpty($0) }

        guard var best = Self.pickBest(from: candidates) else {
            emptyStreak += 1
            // Don't flash "Not Playing" on a single empty poll (players lag after skip).
            if emptyStreak >= 3 {
                publish(.empty)
            }
            return
        }
        // If the winner lacks art, steal art from another source for the same track.
        if best.artworkData == nil {
            let key = Self.trackKey(best)
            if let art = candidates.first(where: { Self.trackKey($0) == key && $0.artworkData != nil })?.artworkData {
                best.artworkData = art
            } else if let art = candidates.first(where: { $0.artworkData != nil })?.artworkData,
                      candidates.contains(where: { Self.trackKey($0) == key }) {
                best.artworkData = art
            }
        }
        // Prefer playlist / sourceApp / timing from AppleScript when MR/helper omit them.
        if best.playlistName == nil {
            best.playlistName = candidates.first(where: { $0.playlistName != nil })?.playlistName
        }
        if best.sourceApp == nil {
            best.sourceApp = candidates.first(where: { $0.sourceApp != nil })?.sourceApp
                ?? (AppleScriptMedia.shared.preferredPlayer().map {
                    $0 == .music ? MediaPlayerApp.music : .spotify
                })
        }
        if best.duration <= 0 {
            best.duration = candidates.first(where: { $0.duration > 0 })?.duration ?? 0
        }
        if best.elapsed <= 0 {
            best.elapsed = candidates.first(where: { $0.elapsed > 0 })?.elapsed ?? best.elapsed
        }
        // When AppleScript has richer timing for the same track, prefer it.
        if let scripted,
           Self.trackKey(scripted) == Self.trackKey(best),
           scripted.duration > 0 {
            best.elapsed = scripted.elapsed
            best.duration = scripted.duration
        }
        // Keep previous art for a beat when the same track re-publishes without art.
        if best.artworkData == nil,
           Self.trackKey(best) == Self.trackKey(current),
           let prev = current.artworkData {
            best.artworkData = prev
        }
        emptyStreak = 0
        publish(best)
    }

    private static func trackKey(_ info: NowPlayingInfo) -> String {
        "\(info.title)\u{1}\(info.artist)\u{1}\(info.album)"
    }

    private static func pickBest(from candidates: [NowPlayingInfo]) -> NowPlayingInfo? {
        guard !candidates.isEmpty else { return nil }
        // Prefer playing tracks; among those, prefer ones with artwork.
        let playing = candidates.filter(\.isPlaying)
        let pool = playing.isEmpty ? candidates : playing
        return pool.max { a, b in
            let aScore = (a.artworkData != nil ? 4 : 0) + (a.isPlaying ? 2 : 0) + (a.artist.isEmpty ? 0 : 1)
            let bScore = (b.artworkData != nil ? 4 : 0) + (b.isPlaying ? 2 : 0) + (b.artist.isEmpty ? 0 : 1)
            return aScore < bScore
        }
    }

    private static func isEmpty(_ info: NowPlayingInfo) -> Bool {
        info.title.isEmpty || info.title == NowPlayingInfo.empty.title
    }

    private static func info(fromHelper payload: MediaRemoteHelperProcess.Payload) -> NowPlayingInfo {
        NowPlayingInfo(
            title: payload.title.isEmpty ? NowPlayingInfo.empty.title : payload.title,
            artist: payload.artist,
            album: payload.album,
            isPlaying: payload.isPlaying,
            artworkData: payload.artworkBase64.flatMap { Data(base64Encoded: $0) },
            playlistName: nil,
            sourceApp: .other,
            elapsed: 0,
            duration: 0
        )
    }

    private func parse(_ dict: NSDictionary) -> NowPlayingInfo {
        // Try both the full constant-style keys and short aliases used across OS versions.
        func string(_ keys: [String]) -> String {
            for key in keys {
                if let value = dict[key] as? String, !value.isEmpty { return value }
            }
            return ""
        }
        func number(_ keys: [String]) -> Double? {
            for key in keys {
                if let n = dict[key] as? NSNumber { return n.doubleValue }
                if let d = dict[key] as? Double { return d }
            }
            return nil
        }
        let title = string([
            "kMRMediaRemoteNowPlayingInfoTitle",
            "title",
            "Title"
        ])
        let artist = string([
            "kMRMediaRemoteNowPlayingInfoArtist",
            "artist",
            "Artist"
        ])
        let album = string([
            "kMRMediaRemoteNowPlayingInfoAlbum",
            "album",
            "Album"
        ])
        let artwork = (dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data)
            ?? (dict["artworkData"] as? Data)
        let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue
            ?? (dict["playbackRate"] as? NSNumber)?.doubleValue
            ?? 0
        // Elapsed/duration may be seconds or (on some builds) milliseconds.
        var elapsed = number([
            "kMRMediaRemoteNowPlayingInfoElapsedTime",
            "elapsedTime",
            "ElapsedTime"
        ]) ?? 0
        var duration = number([
            "kMRMediaRemoteNowPlayingInfoDuration",
            "duration",
            "Duration"
        ]) ?? 0
        if duration > 10_000 { duration /= 1000 }
        if elapsed > 10_000 { elapsed /= 1000 }
        return NowPlayingInfo(
            title: title.isEmpty ? NowPlayingInfo.empty.title : title,
            artist: artist,
            album: album,
            isPlaying: rate > 0,
            artworkData: artwork,
            playlistName: nil,
            sourceApp: .other,
            elapsed: max(0, elapsed),
            duration: max(0, duration)
        )
    }

    private func publish(_ info: NowPlayingInfo) {
        guard info != current else { return }
        current = info
        onChange?(info)
    }

    @discardableResult
    private func send(_ command: MRCommand) -> Bool {
        guard let sendCommand else { return false }
        return sendCommand(command.rawValue, nil)
    }
}
