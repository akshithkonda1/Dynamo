import AppKit
import SwiftUI

/// Media controls widget. Talks only to `NowPlayingProvider` — never to a
/// concrete data source. Swapping mock ↔ real happens at construction time.
@MainActor
final class MediaControlsPlugin: ObservableObject, NotchWidgetPlugin {
    let id = "media"
    let displayName = "Media"
    let systemImage = "music.note"

    @Published private(set) var info: NowPlayingInfo = .empty

    private let provider: NowPlayingProvider

    init(provider: NowPlayingProvider? = nil) {
        let resolved = provider ?? MockNowPlayingProvider()
        self.provider = resolved
        self.info = resolved.current
        resolved.onChange = { [weak self] newValue in
            self?.info = newValue
        }
    }

    func start() {
        provider.start()
        info = provider.current
    }

    func stop() {
        provider.stop()
    }

    func collapsedView() -> AnyView {
        AnyView(CollapsedMediaView(info: info))
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedMediaView(plugin: self))
    }

    func togglePlayPause() { provider.togglePlayPause() }
    func nextTrack() { provider.nextTrack() }
    func previousTrack() { provider.previousTrack() }
}

// MARK: - Views

private struct CollapsedMediaView: View {
    let info: NowPlayingInfo

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: info.isPlaying ? "music.note" : "music.note.list")
                .font(NotchTheme.caption.weight(.semibold))
                .foregroundStyle(NotchTheme.textPrimary)
            Text(info.title)
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: 90, alignment: .leading)
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
            softButton("backward.fill", size: 15) { plugin.previousTrack() }
            softButton(plugin.info.isPlaying ? "pause.fill" : "play.fill", size: 18, prominent: true) {
                plugin.togglePlayPause()
            }
            softButton("forward.fill", size: 15) { plugin.nextTrack() }
        }
    }

    private func softButton(_ systemName: String, size: CGFloat, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .frame(width: prominent ? 44 : 38, height: prominent ? 44 : 38)
                .background(Circle().fill(prominent ? NotchTheme.chipFillActive : NotchTheme.chipFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
