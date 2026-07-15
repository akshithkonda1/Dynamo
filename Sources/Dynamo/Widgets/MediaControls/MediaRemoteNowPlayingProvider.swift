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

/// Real now-playing source backed by Apple's private `MediaRemote.framework`.
///
/// Same approach used by Boring Notch / MediaRemoteAdapter-style clients:
/// dynamic `dlopen` + function pointers — there is no public API.
///
/// **Tested against:** macOS 15.x / 26.x toolchains (Xcode 27 beta). Behavior of
/// private frameworks can shift between OS releases. Starting with macOS 15.4,
/// some sandboxed / non-`com.apple.*` processes receive empty payloads from
/// MediaRemote when called in-process. When that happens this provider tries,
/// in order: (1) the `DynamoMediaRemoteHelper` standalone process — a fresh
/// process sometimes succeeds where the long-running host doesn't — then
/// (2) AppleScript for Music and Spotify, so now-playing info and
/// play/pause/skip still work for the common players either way.
///
/// Nothing outside this file (and the construction site in `AppDelegate`)
/// should need to change when swapping providers — UI talks only to
/// `NowPlayingProvider`.
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

    /// Third fallback tier, tried before AppleScript when in-process
    /// MediaRemote is empty. See `MediaRemoteHelperProcess`'s doc comment.
    private let helperProcess = MediaRemoteHelperProcess()
    private var latestHelperInfo: NowPlayingInfo?

    // Function types matching MediaRemote private C API (ObjC blocks via @convention(block)).
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
        refresh()
        // Light poll as a safety net for players that don't emit every change.
        // Interval is long enough not to thrash; notifications remain primary.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
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
    }

    /// No-ops if the helper binary isn't bundled in this build — see
    /// `MediaRemoteHelperProcess.isAvailable`.
    private func startHelperProcess() {
        guard helperProcess.isAvailable else {
            NSLog("Dynamo: MediaRemote helper binary not found — using in-process + AppleScript only")
            return
        }
        helperProcess.onPayload = { [weak self] payload in
            guard let self else { return }
            let info = NowPlayingInfo(
                title: payload.title.isEmpty ? NowPlayingInfo.empty.title : payload.title,
                artist: payload.artist,
                album: payload.album,
                isPlaying: payload.isPlaying,
                artworkData: payload.artworkBase64.flatMap { Data(base64Encoded: $0) }
            )
            self.latestHelperInfo = info
            // Publish live from the helper when it has real media — don't wait
            // for the in-process path to fail. This is the whole point of the
            // helper on macOS 15.4+ where in-process MediaRemote is often empty.
            if info.title != NowPlayingInfo.empty.title, !info.title.isEmpty {
                self.publish(info)
            }
        }
        helperProcess.start()
    }

    /// Diagnostics for Settings / smoke tests.
    var isHelperAvailable: Bool { helperProcess.isAvailable }
    var helperPath: String? { helperProcess.resolvedPath }

    func togglePlayPause() {
        if send(MRCommand.togglePlayPause) { scheduleRefresh(); return }
        AppleScriptMedia.shared.togglePlayPause()
        scheduleRefresh()
    }

    func nextTrack() {
        if send(MRCommand.nextTrack) { scheduleRefresh(); return }
        AppleScriptMedia.shared.nextTrack()
        scheduleRefresh()
    }

    func previousTrack() {
        if send(MRCommand.previousTrack) { scheduleRefresh(); return }
        AppleScriptMedia.shared.previousTrack()
        scheduleRefresh()
    }

    // MARK: - Framework loading

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
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
        ]
        for name in names {
            let center = DistributedNotificationCenter.default()
            let token = center.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            observers.append(token)

            let local = NotificationCenter.default.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            observers.append(local)
        }
    }

    // MARK: - Refresh

    private func scheduleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        guard let getNowPlayingInfo else {
            applyAppleScriptFallback()
            return
        }

        getNowPlayingInfo(DispatchQueue.main) { [weak self] cfDict in
            Task { @MainActor in
                guard let self else { return }
                guard let cfDict = cfDict as NSDictionary? else {
                    self.applyAppleScriptFallback()
                    return
                }
                let info = self.parse(cfDict)
                if info.title == NowPlayingInfo.empty.title || info.title.isEmpty {
                    self.applyAppleScriptFallback()
                    return
                }
                // Optionally refine isPlaying via dedicated call.
                if let getPlaying = self.getNowPlayingApplicationIsPlaying {
                    getPlaying(DispatchQueue.main) { [weak self] playing in
                        Task { @MainActor in
                            guard let self else { return }
                            var refined = info
                            refined.isPlaying = playing.boolValue
                            self.publish(refined)
                        }
                    }
                } else {
                    self.publish(info)
                }
            }
        }
    }

    private func parse(_ dict: NSDictionary) -> NowPlayingInfo {
        // MediaRemote keys are CFString constants; use the well-known string values.
        let title = (dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String)
            ?? (dict["title"] as? String)
            ?? ""
        let artist = (dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String)
            ?? (dict["artist"] as? String)
            ?? ""
        let album = (dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String)
            ?? (dict["album"] as? String)
            ?? ""
        let artwork = (dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data)
            ?? (dict["artworkData"] as? Data)
        let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue
            ?? (dict["playbackRate"] as? NSNumber)?.doubleValue
            ?? 0
        return NowPlayingInfo(
            title: title.isEmpty ? "Not Playing" : title,
            artist: artist,
            album: album,
            isPlaying: rate > 0,
            artworkData: artwork
        )
    }

    private func applyAppleScriptFallback() {
        if let helperInfo = latestHelperInfo, helperInfo.title != NowPlayingInfo.empty.title {
            publish(helperInfo)
        } else if let scripted = AppleScriptMedia.shared.currentInfo() {
            publish(scripted)
        } else if current != .empty {
            // Keep last known unless we know nothing is playing.
            publish(.empty)
        } else {
            publish(.empty)
        }
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

// MARK: - AppleScript fallback (Music / Spotify)

/// Best-effort control for the two most common players when MediaRemote
/// returns empty (notably post-macOS 15.4 entitlement tightening).
@MainActor
final class AppleScriptMedia {
    static let shared = AppleScriptMedia()

    private init() {}

    func currentInfo() -> NowPlayingInfo? {
        if let music = infoFromMusic(), music.title != "Not Playing" { return music }
        if let spotify = infoFromSpotify(), spotify.title != "Not Playing" { return spotify }
        return nil
    }

    func togglePlayPause() {
        run("tell application \"System Events\" to key code 49 using {command down, option down}")
        // Prefer targeting the frontmost media app if known.
        if isRunning("Music") {
            run("tell application \"Music\" to playpause")
        } else if isRunning("Spotify") {
            run("tell application \"Spotify\" to playpause")
        }
    }

    func nextTrack() {
        if isRunning("Music") {
            run("tell application \"Music\" to next track")
        } else if isRunning("Spotify") {
            run("tell application \"Spotify\" to next track")
        }
    }

    func previousTrack() {
        if isRunning("Music") {
            run("tell application \"Music\" to previous track")
        } else if isRunning("Spotify") {
            run("tell application \"Spotify\" to previous track")
        }
    }

    private func infoFromMusic() -> NowPlayingInfo? {
        guard isRunning("Music") else { return nil }
        let script = """
        tell application "Music"
            if player state is stopped then return "|||false"
            set t to name of current track
            set a to artist of current track
            set al to album of current track
            set p to (player state is playing)
            return t & "|" & a & "|" & al & "|" & p
        end tell
        """
        return parsePipeResult(runReturning(script))
    }

    private func infoFromSpotify() -> NowPlayingInfo? {
        guard isRunning("Spotify") else { return nil }
        let script = """
        tell application "Spotify"
            if player state is stopped then return "|||false"
            set t to name of current track
            set a to artist of current track
            set al to album of current track
            set p to (player state is playing)
            return t & "|" & a & "|" & al & "|" & p
        end tell
        """
        return parsePipeResult(runReturning(script))
    }

    private func parsePipeResult(_ raw: String?) -> NowPlayingInfo? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return nil }
        let title = parts[0]
        if title.isEmpty { return .empty }
        return NowPlayingInfo(
            title: title,
            artist: parts[1],
            album: parts[2],
            isPlaying: parts[3].lowercased().contains("true"),
            artworkData: nil
        )
    }

    private func isRunning(_ appName: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.localizedName == appName || $0.bundleIdentifier?.contains(appName.lowercased()) == true
        }
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
