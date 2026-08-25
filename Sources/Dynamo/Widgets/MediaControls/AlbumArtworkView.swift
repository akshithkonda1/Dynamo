import AVFoundation
import AppKit
import AVKit
import SwiftUI

// MARK: - Host wired to MediaControlsPlugin

/// Binds now-playing + MusicKit motion loader into `AlbumArtworkView`.
struct AlbumCoverHost: View {
    @ObservedObject var plugin: MediaControlsPlugin
    @ObservedObject private var motion = MusicMotionArtworkLoader.shared
    let size: CGFloat
    let playerAppName: String

    private var staticImage: NSImage? {
        guard let data = plugin.info.artworkData else { return nil }
        return NSImage(data: data)
    }

    private var motionURL: URL? {
        // Only Apple Music album motion — Spotify stays static.
        guard plugin.motionArtworkEnabled else { return nil }
        guard plugin.info.sourceApp == .music else { return nil }
        let key = "\(plugin.info.title)\u{1}\(plugin.info.artist)\u{1}\(plugin.info.album)"
        guard motion.trackKey == key else { return nil }
        return motion.motionURL
    }

    var body: some View {
        AlbumArtworkView(
            staticImage: staticImage,
            motionURL: motionURL,
            isPlaying: plugin.info.isPlaying,
            size: size,
            onOpen: { plugin.openConnectedApp() }
        )
        .onChange(of: plugin.info.title) { _ in
            resolveMotion()
        }
        .onChange(of: plugin.info.musicKitCatalogID) { _ in
            resolveMotion()
        }
        .onChange(of: plugin.motionArtworkEnabled) { _ in
            resolveMotion()
        }
        .onAppear { resolveMotion() }
    }

    private func resolveMotion() {
        guard plugin.motionArtworkEnabled, plugin.info.sourceApp == .music else {
            MusicMotionArtworkLoader.shared.clear()
            return
        }
        let key = "\(plugin.info.title)\u{1}\(plugin.info.artist)\u{1}\(plugin.info.album)"
        Task {
            await MusicMotionArtworkLoader.shared.resolve(
                catalogSongID: plugin.info.musicKitCatalogID,
                title: plugin.info.title,
                artist: plugin.info.artist,
                album: plugin.info.album,
                trackKey: key
            )
        }
    }
}

/// Album cover that:
/// - Plays **Apple Music Album Motion** (HLS/mp4) when a motion URL exists and the track is playing
/// - Stays **static** otherwise
/// - **Hover** expands a larger preview of the cover
struct AlbumArtworkView: View {
    let staticImage: NSImage?
    let motionURL: URL?
    let isPlaying: Bool
    let size: CGFloat
    var onOpen: (() -> Void)? = nil

    @State private var isHovering = false
    @StateObject private var playerModel = MotionArtworkPlayer()

    private var corner: CGFloat { size >= 120 ? 18 : 16 }

    var body: some View {
        ZStack {
            PlayingArtRing(isPlaying: isPlaying, size: size, cornerRadius: corner) {
                ZStack {
                    staticLayer
                    if motionURL != nil, isPlaying {
                        MotionVideoLayer(player: playerModel.player)
                            .opacity(playerModel.isReady ? 1 : 0)
                            .animation(.easeIn(duration: 0.35), value: playerModel.isReady)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                        .padding(6)
                }
                .overlay(alignment: .topLeading) {
                    if motionURL != nil, isPlaying {
                        Text("LIVE")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                            .padding(7)
                    }
                }
            }
            .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
            .scaleEffect(isHovering ? 1.03 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
            .onTapGesture { onOpen?() }
            .help(motionURL != nil ? "Animated Apple Music cover · click to open" : "Open in player")

            // Hover enlarge preview
            if isHovering {
                Color.clear
                    .frame(width: size, height: size)
                    .overlay(alignment: .topLeading) {
                        hoverPreview
                            .offset(x: size * 0.55, y: -12)
                            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
                    }
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
        }
        .zIndex(isHovering ? 40 : 0)
        .onChange(of: motionURL) { url in
            playerModel.setURL(url, playing: isPlaying)
        }
        .onChange(of: isPlaying) { playing in
            playerModel.setPlaying(playing)
        }
        .onAppear {
            playerModel.setURL(motionURL, playing: isPlaying)
        }
        .onDisappear {
            playerModel.pause()
        }
    }

    @ViewBuilder
    private var staticLayer: some View {
        if let image = staticImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(1, contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [NotchTheme.chipFillActive, NotchTheme.chipFill],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.27, weight: .medium))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }

    private var hoverPreview: some View {
        let preview: CGFloat = min(220, max(160, size * 1.65))
        return ZStack {
            if motionURL != nil, isPlaying {
                MotionVideoLayer(player: playerModel.player)
            } else if let image = staticImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
            }
        }
        .frame(width: preview, height: preview)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
    }
}

// MARK: - Video layer

private struct MotionVideoLayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let v = PlayerNSView()
        v.configure(player: player)
        return v
    }

    func updateNSView(_ nsView: PlayerNSView, context: Context) {
        nsView.configure(player: player)
    }

    final class PlayerNSView: NSView {
        private var playerLayer: AVPlayerLayer?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func configure(player: AVPlayer) {
            if playerLayer == nil {
                let layer = AVPlayerLayer(player: player)
                layer.videoGravity = .resizeAspectFill
                layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                self.layer?.addSublayer(layer)
                playerLayer = layer
            } else {
                playerLayer?.player = player
            }
            playerLayer?.frame = bounds
        }

        override func layout() {
            super.layout()
            playerLayer?.frame = bounds
        }
    }
}

// MARK: - Player controller

@MainActor
private final class MotionArtworkPlayer: ObservableObject {
    let player = AVPlayer()
    @Published var isReady = false

    private var loopObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var currentURL: URL?

    func setURL(_ url: URL?, playing: Bool) {
        guard url != currentURL else {
            setPlaying(playing)
            return
        }
        currentURL = url
        isReady = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeObservers()
        guard let url else { return }

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.actionAtItemEnd = .none

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                self?.isReady = item.status == .readyToPlay
                if playing, item.status == .readyToPlay {
                    self?.player.play()
                }
            }
        }
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }
        if playing { player.play() }
    }

    func setPlaying(_ playing: Bool) {
        if playing {
            player.play()
        } else {
            player.pause()
        }
    }

    func pause() {
        player.pause()
    }

    private func removeObservers() {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
    }

    deinit {
        // Best-effort cleanup; MainActor deinit is fine for NSObjectProtocol.
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
    }
}
