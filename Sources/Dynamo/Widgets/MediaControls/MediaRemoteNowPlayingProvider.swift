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
        // AppleScript path needs a slightly snappier poll so transport feels live.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
        // Keep timer firing while scrolling UI / tracking runs.
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    func stop() {
        isStarted = false
        pollTimer?.invalidate()
        pollTimer = nil
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
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
        // Optimistic UI flip so the button feels instant.
        var optimistic = current
        if optimistic.title != NowPlayingInfo.empty.title {
            optimistic.isPlaying.toggle()
            publish(optimistic)
        }
        _ = send(MRCommand.togglePlayPause)
        AppleScriptMedia.shared.togglePlayPause()
        scheduleRefresh(after: 0.2)
        scheduleRefresh(after: 0.6)
    }

    func nextTrack() {
        _ = send(MRCommand.nextTrack)
        AppleScriptMedia.shared.nextTrack()
        scheduleRefresh(after: 0.25)
        scheduleRefresh(after: 0.7)
    }

    func previousTrack() {
        _ = send(MRCommand.previousTrack)
        AppleScriptMedia.shared.previousTrack()
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
        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            // Some systems post under shorter names:
            "MRMediaRemoteNowPlayingInfoDidChangeNotification",
            "MRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
        ]
        for name in names {
            let center = DistributedNotificationCenter.default()
            let token = center.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshAll() }
            }
            observers.append(token)

            let local = NotificationCenter.default.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshAll() }
            }
            observers.append(local)
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
        // Prefer playlist / sourceApp from AppleScript when MR/helper omit them.
        if best.playlistName == nil {
            best.playlistName = candidates.first(where: { $0.playlistName != nil })?.playlistName
        }
        if best.sourceApp == nil {
            best.sourceApp = candidates.first(where: { $0.sourceApp != nil })?.sourceApp
                ?? (AppleScriptMedia.shared.preferredPlayer().map {
                    $0 == .music ? MediaPlayerApp.music : .spotify
                })
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
            sourceApp: .other
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
        return NowPlayingInfo(
            title: title.isEmpty ? NowPlayingInfo.empty.title : title,
            artist: artist,
            album: album,
            isPlaying: rate > 0,
            artworkData: artwork,
            playlistName: nil,
            sourceApp: .other
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
