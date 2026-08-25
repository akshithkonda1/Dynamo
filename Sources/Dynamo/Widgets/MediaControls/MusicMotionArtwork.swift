import AVFoundation
import Foundation
import MusicKit

/// Resolves **Apple Music Album Motion** (animated cover) URLs when the catalog
/// provides them. Falls back to nil → UI shows static artwork.
///
/// Uses MusicKit’s authenticated `MusicDataRequest` against the Apple Music API
/// (same entitlement as catalog search — not a third-party API). Parses
/// `editorialVideo` / motion artwork HLS links when present.
@available(macOS 12.0, *)
@MainActor
final class MusicMotionArtworkLoader: ObservableObject {
    static let shared = MusicMotionArtworkLoader()

    @Published private(set) var motionURL: URL?
    @Published private(set) var trackKey: String = ""

    private var inFlight: String?
    private var negativeCache = Set<String>()
    private var urlCache: [String: URL] = [:]

    private init() {}

    func clear() {
        motionURL = nil
        trackKey = ""
        inFlight = nil
    }

    /// Look up motion artwork for the current Apple Music track.
    func resolve(
        catalogSongID: String?,
        title: String,
        artist: String,
        album: String,
        trackKey: String
    ) async {
        guard trackKey != self.trackKey || motionURL == nil else { return }
        if negativeCache.contains(trackKey) {
            if self.trackKey != trackKey {
                self.trackKey = trackKey
                motionURL = nil
            }
            return
        }
        if let cached = urlCache[trackKey] {
            self.trackKey = trackKey
            motionURL = cached
            return
        }
        guard inFlight != trackKey else { return }
        inFlight = trackKey
        defer { if inFlight == trackKey { inFlight = nil } }

        var url: URL?
        if let id = catalogSongID, !id.isEmpty {
            url = await fetchMotionURL(songID: id)
        }
        if url == nil, !title.isEmpty {
            url = await searchThenFetch(title: title, artist: artist, album: album)
        }

        guard inFlight == nil || inFlight == trackKey else { return }
        self.trackKey = trackKey
        if let url {
            urlCache[trackKey] = url
            if urlCache.count > 40 {
                urlCache = Dictionary(uniqueKeysWithValues: urlCache.suffix(24))
            }
            motionURL = url
        } else {
            negativeCache.insert(trackKey)
            if negativeCache.count > 80 {
                negativeCache = Set(negativeCache.suffix(40))
            }
            motionURL = nil
        }
    }

    // MARK: - Apple Music API

    private func searchThenFetch(title: String, artist: String, album: String) async -> URL? {
        var request = MusicCatalogSearchRequest(
            term: album.isEmpty ? "\(title) \(artist)" : "\(album) \(artist)",
            types: [Album.self, Song.self]
        )
        request.limit = 5
        guard let response = try? await request.response() else { return nil }

        if let albumMatch = response.albums.first(where: {
            album.isEmpty || $0.title.localizedCaseInsensitiveContains(album)
                || album.localizedCaseInsensitiveContains($0.title)
        }) ?? response.albums.first {
            if let u = await fetchMotionURL(albumID: albumMatch.id.rawValue) { return u }
        }
        if let song = response.songs.first(where: {
            $0.title.caseInsensitiveCompare(title) == .orderedSame
        }) ?? response.songs.first {
            return await fetchMotionURL(songID: song.id.rawValue)
        }
        return nil
    }

    private func fetchMotionURL(songID: String) async -> URL? {
        guard let store = try? await MusicDataRequest.currentCountryCode else { return nil }
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(store)/songs/\(songID)?include=albums") else {
            return nil
        }
        guard let data = await musicData(url: url) else { return nil }
        // Prefer album relationship motion art
        if let albumID = firstAlbumID(fromSongPayload: data) {
            if let u = await fetchMotionURL(albumID: albumID) { return u }
        }
        return extractMotionURL(from: data)
    }

    private func fetchMotionURL(albumID: String) async -> URL? {
        guard let store = try? await MusicDataRequest.currentCountryCode else { return nil }
        // Request editorialVideo attributes used for Album Motion.
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(store)/albums/\(albumID)?extend=editorialVideo") else {
            return nil
        }
        guard let data = await musicData(url: url) else { return nil }
        return extractMotionURL(from: data)
    }

    private func musicData(url: URL) async -> Data? {
        let request = MusicDataRequest(urlRequest: URLRequest(url: url))
        guard let response = try? await request.response() else { return nil }
        return response.data
    }

    private func firstAlbumID(fromSongPayload data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]],
              let song = items.first,
              let rel = song["relationships"] as? [String: Any],
              let albums = rel["albums"] as? [String: Any],
              let albumData = albums["data"] as? [[String: Any]],
              let id = albumData.first?["id"] as? String
        else { return nil }
        return id
    }

    /// Walk JSON for motion / editorialVideo HLS or MP4 URLs.
    private func extractMotionURL(from data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var found: [String] = []
        collectMotionURLs(json, into: &found)
        // Prefer square motion, then any m3u8/mp4.
        let preferred = found.first(where: { $0.contains("square") && $0.contains("m3u8") })
            ?? found.first(where: { $0.contains("m3u8") })
            ?? found.first(where: { $0.contains(".mp4") })
            ?? found.first
        guard let s = preferred, let url = URL(string: s) else { return nil }
        return url
    }

    private func collectMotionURLs(_ any: Any, into out: inout [String]) {
        if let s = any as? String {
            let lower = s.lowercased()
            if (lower.contains("m3u8") || lower.hasSuffix(".mp4"))
                && (lower.contains("video") || lower.contains("motion") || lower.contains("animated")
                    || lower.contains("editorial") || lower.contains("mzstatic")) {
                // Heuristic: animated art CDN paths often include "video" or "motion".
                if lower.contains("video") || lower.contains("motion") || lower.contains("animated") {
                    out.append(s)
                }
            }
            return
        }
        if let dict = any as? [String: Any] {
            // Known Apple Music API keys for album motion.
            let motionKeys = [
                "editorialVideo", "motionDetailSquare", "motionSquareVideo1x1",
                "motionDetailTall", "motionTallVideo16x9", "video", "url", "hlsUrl"
            ]
            for key in motionKeys {
                if let v = dict[key] {
                    collectMotionURLs(v, into: &out)
                }
            }
            for (k, v) in dict {
                let lk = k.lowercased()
                if lk.contains("motion") || lk.contains("editorial") || lk.contains("video") {
                    collectMotionURLs(v, into: &out)
                } else if v is [String: Any] || v is [Any] {
                    collectMotionURLs(v, into: &out)
                }
            }
            return
        }
        if let arr = any as? [Any] {
            for v in arr { collectMotionURLs(v, into: &out) }
        }
    }
}
