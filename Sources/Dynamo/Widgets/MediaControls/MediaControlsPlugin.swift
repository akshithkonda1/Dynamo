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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(info.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: 90, alignment: .leading)
        }
    }
}

private struct ExpandedMediaView: View {
    @ObservedObject var plugin: MediaControlsPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(plugin.info.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !plugin.info.artist.isEmpty {
                        Text(plugin.info.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    if !plugin.info.album.isEmpty {
                        Text(plugin.info.album)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 28) {
                Spacer()
                controlButton(systemName: "backward.fill") { plugin.previousTrack() }
                controlButton(systemName: plugin.info.isPlaying ? "pause.fill" : "play.fill", size: 22) {
                    plugin.togglePlayPause()
                }
                controlButton(systemName: "forward.fill") { plugin.nextTrack() }
                Spacer()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let data = plugin.info.artworkData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(shape)
        } else {
            shape
                .fill(Color.white.opacity(0.08))
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "music.note")
                        .foregroundStyle(.white.opacity(0.5))
                )
        }
    }

    private func controlButton(systemName: String, size: CGFloat = 16, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
