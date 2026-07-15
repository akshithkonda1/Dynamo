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

    func seek(to elapsed: TimeInterval) {
        provider.seek(to: elapsed)
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
    /// Local scrub value while the user is dragging the timeline.
    @State private var scrubElapsed: Double?
    @State private var displayElapsed: Double = 0
    @State private var lastTick: Date = .now

    private var hasTrack: Bool {
        plugin.info.isPlaying || plugin.info.title != NowPlayingInfo.empty.title
    }

    private var effectiveElapsed: Double {
        if let scrubElapsed { return scrubElapsed }
        return displayElapsed
    }

    var body: some View {
        HStack(alignment: .center, spacing: NotchTheme.spaceLG) {
            artwork
                .onTapGesture { plugin.openConnectedApp() }
                .help("Open in \(playerAppName)")

            VStack(alignment: .leading, spacing: 5) {
                header
                MarqueeText(
                    text: hasTrack ? plugin.info.title : "Nothing playing",
                    font: .system(size: 17, weight: .semibold),
                    foreground: NotchTheme.textPrimary,
                    speed: 32
                )
                .frame(height: 22)
                .onTapGesture { plugin.openConnectedApp() }
                MarqueeText(
                    text: subtitle,
                    font: NotchTheme.body,
                    foreground: NotchTheme.textSecondary,
                    speed: 28
                )
                .frame(height: 18)

                timelineBar

                playlistRow

                Spacer(minLength: 4)
                transportRow
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear {
            plugin.refreshPlaylists()
            displayElapsed = plugin.info.elapsed
            lastTick = .now
        }
        .onChange(of: plugin.info.elapsed) { newValue in
            // Don't yank the knob while the user is scrubbing.
            guard scrubElapsed == nil else { return }
            // Accept remote updates that jump more than a small delta (seek / new track).
            if abs(newValue - displayElapsed) > 1.25 || !plugin.info.isPlaying {
                displayElapsed = newValue
            }
            lastTick = .now
        }
        .onChange(of: plugin.info.title) { _ in
            displayElapsed = plugin.info.elapsed
            scrubElapsed = nil
            lastTick = .now
        }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { now in
            guard scrubElapsed == nil, plugin.info.isPlaying, plugin.info.duration > 0 else {
                lastTick = now
                return
            }
            let dt = now.timeIntervalSince(lastTick)
            lastTick = now
            let next = min(plugin.info.duration, displayElapsed + dt)
            displayElapsed = next
        }
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

    /// Scrubbable playback position — the “time bar”, not a content scrollbar.
    private var timelineBar: some View {
        let duration = max(plugin.info.duration, 0)
        let canSeek = duration > 0.5 && hasTrack
        return VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: {
                        canSeek ? min(effectiveElapsed, duration) : 0
                    },
                    set: { newValue in
                        scrubElapsed = newValue
                        displayElapsed = newValue
                    }
                ),
                in: 0...max(duration, 0.001),
                onEditingChanged: { editing in
                    if editing {
                        scrubElapsed = effectiveElapsed
                    } else if let value = scrubElapsed {
                        plugin.seek(to: value)
                        displayElapsed = value
                        scrubElapsed = nil
                        lastTick = .now
                    }
                }
            )
            .controlSize(.mini)
            .disabled(!canSeek)
            .opacity(canSeek ? 1 : 0.35)
            .tint(Color.white.opacity(0.85))

            HStack {
                Text(Self.formatTime(effectiveElapsed))
                    .font(NotchTheme.micro.monospacedDigit())
                    .foregroundStyle(NotchTheme.textTertiary)
                Spacer(minLength: 0)
                Text(canSeek ? Self.formatTime(duration) : "--:--")
                    .font(NotchTheme.micro.monospacedDigit())
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
        }
        .padding(.top, 2)
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    @ViewBuilder
    private var playlistRow: some View {
        if hasTrack || !plugin.playlists.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                MarqueeText(
                    text: plugin.info.playlistName ?? "No playlist",
                    font: NotchTheme.micro,
                    foreground: NotchTheme.textTertiary,
                    speed: 24
                )
                .frame(height: 14)
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
            transportButton(
                "backward.fill",
                accessibility: "Previous",
                size: 15,
                diameter: 38
            ) { plugin.previousTrack() }
            transportButton(
                plugin.info.isPlaying ? "pause.fill" : "play.fill",
                accessibility: plugin.info.isPlaying ? "Pause" : "Play",
                size: 18,
                diameter: 44,
                prominent: true
            ) { plugin.togglePlayPause() }
            transportButton(
                "forward.fill",
                accessibility: "Next",
                size: 15,
                diameter: 38
            ) { plugin.nextTrack() }
        }
    }

    private func transportButton(
        _ systemName: String,
        accessibility: String,
        size: CGFloat,
        diameter: CGFloat,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        // Real `Button` + shared style so first-clicks fire on the nonactivating
        // notch panel (plain Image + onTapGesture often eats the first press).
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
        }
        .buttonStyle(.notchIcon(diameter: diameter, prominent: prominent))
        .help(accessibility)
        .accessibilityLabel(accessibility)
    }
}
