import Foundation

// MARK: - DynamoMediaRemoteHelper
//
// A tiny, fully standalone helper binary that reads Now Playing info from
// Apple's private MediaRemote.framework and streams it to stdout as
// line-delimited JSON.
//
// **Why this exists as a separate process:** starting with macOS 15.4, some
// sandboxed / non-`com.apple.*` processes receive empty payloads from
// MediaRemote when calling it in-process (see
// `MediaRemoteNowPlayingProvider`'s doc comment in the main target). A
// freshly spawned, short-lived helper binary sometimes succeeds where the
// long-running host app process doesn't — the same technique community
// notch-dock adapters use. This is a workaround for undocumented,
// version-dependent private-framework behavior, not a guaranteed fix, and
// deliberately does not share source with the main target's provider — it's
// meant to be a minimal, dependency-free binary on its own.
//
// Protocol: one JSON object per line on stdout, emitted whenever MediaRemote
// reports a change. No input is read; the helper runs until killed.

// MARK: - MediaRemote private framework bridging

private typealias MRMediaRemoteGetNowPlayingInfo =
    @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
private typealias MRMediaRemoteRegisterForNowPlayingNotifications =
    @convention(c) (DispatchQueue) -> Void
private typealias MRMediaRemoteGetNowPlayingApplicationIsPlaying =
    @convention(c) (DispatchQueue, @escaping @convention(block) (ObjCBool) -> Void) -> Void

struct HelperPayload: Codable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var artworkBase64: String?
}

final class MediaRemoteHelper {
    private var frameworkHandle: UnsafeMutableRawPointer?
    private var getNowPlayingInfo: MRMediaRemoteGetNowPlayingInfo?
    private var getIsPlaying: MRMediaRemoteGetNowPlayingApplicationIsPlaying?
    private var observers: [NSObjectProtocol] = []

    private var pollTimer: Timer?

    func run() -> Never {
        loadFramework()
        registerForNotifications()
        refresh()
        // Poll as a safety net — some players don't always emit notifications
        // into a non-com.apple helper process.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.run()
        exit(0) // unreachable; RunLoop.main.run() never returns on its own
    }

    private func loadFramework() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW) else {
            logError("failed to dlopen MediaRemote: \(String(cString: dlerror()))")
            exit(1)
        }
        frameworkHandle = handle
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlayingInfo = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingInfo.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            getIsPlaying = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingApplicationIsPlaying.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            let register = unsafeBitCast(sym, to: MRMediaRemoteRegisterForNowPlayingNotifications.self)
            register(DispatchQueue.main)
        }
        guard getNowPlayingInfo != nil else {
            logError("MRMediaRemoteGetNowPlayingInfo symbol not found")
            exit(1)
        }
    }

    private func registerForNotifications() {
        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
        ]
        for name in names {
            let token = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
            observers.append(token)
        }
    }

    private func refresh() {
        guard let getNowPlayingInfo else { return }
        getNowPlayingInfo(DispatchQueue.main) { [weak self] cfDict in
            guard let self else { return }
            guard let dict = cfDict as NSDictionary? else {
                self.emit(HelperPayload(title: "", artist: "", album: "", isPlaying: false, artworkBase64: nil))
                return
            }
            let title = (dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String) ?? ""
            let artist = (dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? ""
            let album = (dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String) ?? ""
            let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
            let artworkData = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
            let artworkBase64 = artworkData?.base64EncodedString()

            if let getIsPlaying = self.getIsPlaying {
                getIsPlaying(DispatchQueue.main) { [weak self] playing in
                    self?.emit(HelperPayload(
                        title: title, artist: artist, album: album,
                        isPlaying: playing.boolValue,
                        artworkBase64: artworkBase64
                    ))
                }
            } else {
                self.emit(HelperPayload(
                    title: title, artist: artist, album: album,
                    isPlaying: rate > 0,
                    artworkBase64: artworkBase64
                ))
            }
        }
    }

    private func emit(_ payload: HelperPayload) {
        guard let data = try? JSONEncoder().encode(payload),
              let line = String(data: data, encoding: .utf8)
        else { return }
        print(line)
        fflush(stdout)
    }

    private func logError(_ message: String) {
        FileHandle.standardError.write("DynamoMediaRemoteHelper: \(message)\n".data(using: .utf8) ?? Data())
    }
}

let helper = MediaRemoteHelper()
helper.run()
