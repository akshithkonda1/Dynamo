import AppKit
import SwiftUI

/// Media controls widget. Talks only to `NowPlayingProvider` — never to a
/// concrete data source. Swapping mock ↔ real happens at construction time.
@MainActor
final class MediaControlsPlugin: ObservableObject, NotchWidgetPlugin, NotchAmbientProviding, NotchSneakPeekProviding {
    let id = "media"
    let displayName = "Media"
    let systemImage = "music.note"

    @Published private(set) var info: NowPlayingInfo = .empty
    var onSneakPeek: ((NotchSneakPeek) -> Void)?

    private let provider: NowPlayingProvider
    private var lastTrackKey: String
    /// The onChange right after (re)start reports whatever's already playing —
    /// that's not a "track change" worth a peek, just Dynamo catching up.
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

    // MARK: - NotchAmbientProviding

    /// Show the ambient art + visualizer only while something is actually playing.
    var isAmbientActive: Bool { info.isPlaying }
    func ambientView() -> AnyView { AnyView(AmbientMediaView(plugin: self)) }
}

// MARK: - Views

/// Ambient content for the collapsed notch: album art hugging the leading edge,
/// a dancing-bars visualizer on the trailing edge, camera gap in between.
private struct AmbientMediaView: View {
    @ObservedObject var plugin: MediaControlsPlugin

    var body: some View {
        HStack(spacing: 0) {
            artThumb
            Spacer(minLength: 0)
            MusicBarsView(isPlaying: plugin.info.isPlaying, maxHeight: 12)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        } else {
            shape
                .fill(NotchTheme.chipFill)
                .frame(width: 20, height: 20)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NotchTheme.textSecondary)
                )
        }
    }
}

private struct ExpandedMediaView: View {
    @ObservedObject var plugin: MediaControlsPlugin

    private var hasTrack: Bool {
        plugin.info.isPlaying || plugin.info.title != NowPlayingInfo.empty.title
    }

    var body: some View {
        HStack(alignment: .center, spacing: NotchTheme.spaceLG) {
            artwork
            VStack(alignment: .leading, spacing: 5) {
                header
                Text(hasTrack ? plugin.info.title : "Nothing playing")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(NotchTheme.body)
                    .foregroundStyle(NotchTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: NotchTheme.spaceSM)
                transportRow
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
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
        // Tap gesture first so transport works even when the notch panel is
        // nonactivating / not yet key (SwiftUI Button can miss first click).
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
