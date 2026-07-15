import AppKit
import SwiftUI

/// Media controls widget. Talks only to `NowPlayingProvider` — never to a
/// concrete data source. Swapping mock ↔ real happens at construction time.
@MainActor
final class MediaControlsPlugin: ObservableObject, NotchWidgetPlugin, NotchAmbientProviding, NotchSneakPeekProviding, PlayerAppOpening {
    let id = "media"
    let displayName = "Media"
    let systemImage = "music.note"

    @Published private(set) var info: NowPlayingInfo = .empty
    @Published private(set) var playlists: [String] = []
    @Published var showPlaylistPicker = false
    var onSneakPeek: ((NotchSneakPeek) -> Void)?

    private let provider: NowPlayingProvider
    private var lastTrackKey: String
    private var suppressNextPeek = true

    init(provider: NowPlayingProvider? = nil) {
        let resolved = provider ?? MockNowPlayingProvider()
        self.provider = resolved
        self.info = resolved.current
        self.lastTrackKey = Self.trackKey(resolved.current)
        resolved.onChange = { [weak self] newValue in
            self?.handleInfoChange(newValue)
        }
    }

    func start() {
        suppressNextPeek = true
        provider.start()
        info = provider.current
        refreshPlaylists()
    }

    func stop() {
        provider.stop()
    }

    private func handleInfoChange(_ newValue: NowPlayingInfo) {
        info = newValue
        let key = Self.trackKey(newValue)
        let shouldSuppress = suppressNextPeek
        suppressNextPeek = false
        defer { lastTrackKey = key }
        guard !shouldSuppress,
              newValue.isPlaying,
              key != lastTrackKey,
              !newValue.title.isEmpty,
              newValue.title != NowPlayingInfo.empty.title
        else { return }
        onSneakPeek?(NotchSneakPeek(
            systemImage: "music.note",
            title: newValue.title,
            subtitle: newValue.artist.isEmpty ? newValue.album : newValue.artist
        ))
    }

    private static func trackKey(_ info: NowPlayingInfo) -> String {
        "\(info.title)\u{1}\(info.artist)\u{1}\(info.album)"
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedMediaView(plugin: self))
    }

    func togglePlayPause() { provider.togglePlayPause() }
    func nextTrack() { provider.nextTrack() }
    func previousTrack() { provider.previousTrack() }

    /// Open Music / Spotify and reveal the current track / playlist context.
    func openConnectedApp() {
        provider.openConnectedApp()
    }

    /// Tray re-tap → jump to the connected player app.
    func openPlayerApp() {
        openConnectedApp()
    }

    func refreshPlaylists() {
        playlists = provider.availablePlaylists()
    }

    func playPlaylist(_ name: String) {
        provider.playPlaylist(named: name)
        showPlaylistPicker = false
    }

    // MARK: - NotchAmbientProviding

    var isAmbientActive: Bool { info.isPlaying }
    func ambientView() -> AnyView { AnyView(AmbientMediaView(plugin: self)) }
}

// MARK: - Ambient (collapsed)

private struct AmbientMediaView: View {
    @ObservedObject var plugin: MediaControlsPlugin

    var body: some View {
        HStack(spacing: 0) {
            artThumb
                .onTapGesture { plugin.openConnectedApp() }
                .help("Open \(playerLabel)")
            Spacer(minLength: 0)
            MusicBarsView(isPlaying: plugin.info.isPlaying, maxHeight: 12)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var playerLabel: String {
        switch plugin.info.sourceApp {
        case .spotify: return "Spotify"
        case .music, .other, .none: return "Music"
        }
    }

    @ViewBuilder
    private var artThumb: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        if let data = plugin.info.artworkData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(shape)
                .contentShape(shape)
        } else {
            shape
                .fill(NotchTheme.chipFill)
                .frame(width: 20, height: 20)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NotchTheme.textSecondary)
                )
                .contentShape(shape)
        }
    }
}

// MARK: - Expanded

private struct ExpandedMediaView: View {
    @ObservedObject var plugin: MediaControlsPlugin

    private var hasTrack: Bool {
        plugin.info.isPlaying || plugin.info.title != NowPlayingInfo.empty.title
    }

    var body: some View {
        HStack(alignment: .center, spacing: NotchTheme.spaceLG) {
            artwork
                .onTapGesture { plugin.openConnectedApp() }
                .help("Open in \(playerAppName)")

            VStack(alignment: .leading, spacing: 5) {
                header
                Text(hasTrack ? plugin.info.title : "Nothing playing")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                    .onTapGesture { plugin.openConnectedApp() }
                Text(subtitle)
                    .font(NotchTheme.body)
                    .foregroundStyle(NotchTheme.textSecondary)
                    .lineLimit(1)

                playlistRow

                Spacer(minLength: NotchTheme.spaceSM)
                transportRow
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear { plugin.refreshPlaylists() }
    }

    private var playerAppName: String {
        switch plugin.info.sourceApp {
        case .spotify: return "Spotify"
        case .music, .other, .none: return "Music"
        }
    }

    private var subtitle: String {
        if hasTrack {
            return plugin.info.artist.isEmpty ? plugin.info.album : plugin.info.artist
        }
        return "Play something and it'll show up here."
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(plugin.info.isPlaying ? "Now Playing" : "Media")
                .font(NotchTheme.section)
                .foregroundStyle(NotchTheme.textTertiary)
                .textCase(.uppercase)
            if plugin.info.isPlaying {
                MusicBarsView(isPlaying: true, maxHeight: 11)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            // Icon that opens Music / Spotify
            Image(systemName: playerAppName == "Spotify" ? "music.note.list" : "music.note.house")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(NotchTheme.chipFill))
                .contentShape(Circle())
                .onTapGesture { plugin.openConnectedApp() }
                .help("Open \(playerAppName)")
        }
    }

    @ViewBuilder
    private var playlistRow: some View {
        if hasTrack || !plugin.playlists.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                Text(plugin.info.playlistName ?? "No playlist")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !plugin.playlists.isEmpty {
                    Menu {
                        ForEach(plugin.playlists, id: \.self) { name in
                            Button(name) { plugin.playPlaylist(name) }
                        }
                    } label: {
                        Text("Switch")
                            .font(NotchTheme.micro.weight(.semibold))
                            .foregroundStyle(NotchTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(NotchTheme.chipFill))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Play a different Music playlist")
                }
            }
            .onTapGesture {
                // Tapping the playlist name also opens the player at context.
                plugin.openConnectedApp()
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Group {
            if let data = plugin.info.artworkData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 104, height: 104)
                    .clipShape(shape)
                    .shadow(color: .black.opacity(0.28), radius: 9, y: 3)
            } else {
                shape
                    .fill(NotchTheme.chipFill)
                    .frame(width: 104, height: 104)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 30))
                            .foregroundStyle(NotchTheme.textTertiary)
                    )
            }
        }
        .contentShape(shape)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.right.square.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 2)
                .padding(6)
        }
    }

    private var transportRow: some View {
        HStack(spacing: 14) {
            transportButton("backward.fill", size: 15, diameter: 38) { plugin.previousTrack() }
            transportButton(
                plugin.info.isPlaying ? "pause.fill" : "play.fill",
                size: 18,
                diameter: 44,
                prominent: true
            ) { plugin.togglePlayPause() }
            transportButton("forward.fill", size: 15, diameter: 38) { plugin.nextTrack() }
        }
    }

    private func transportButton(
        _ systemName: String,
        size: CGFloat,
        diameter: CGFloat,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(NotchTheme.textPrimary)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(prominent ? NotchTheme.chipFillActive : NotchTheme.chipFill))
            .contentShape(Circle())
            .onTapGesture(perform: action)
            .accessibilityLabel(systemName)
            .accessibilityAddTraits(.isButton)
    }
}
