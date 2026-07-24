import AppKit
import SwiftUI

/// Horizontal strip of upcoming tracks sourced from the MusicKit queue.
/// Only rendered when `tracks` is non-empty.
struct QueuePeekView: View {
    let tracks: [UpcomingTrackInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Up Next")
                .font(NotchTheme.section)
                .foregroundStyle(NotchTheme.textQuaternary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tracks) { track in
                        QueueTrackCard(track: track)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.top, 2)
    }
}

// MARK: - Individual card

private struct QueueTrackCard: View {
    let track: UpcomingTrackInfo
    @State private var artworkImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            artView
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )

            Text(track.title)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(NotchTheme.textTertiary)
                .lineLimit(1)
                .frame(width: 40, alignment: .leading)
        }
        .frame(width: 40)
        .task(id: track.id) { await loadArtwork() }
    }

    @ViewBuilder
    private var artView: some View {
        if let img = artworkImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(1, contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(NotchTheme.chipFill)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchTheme.textQuaternary)
                )
        }
    }

    private func loadArtwork() async {
        guard let url = track.artworkURL else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = NSImage(data: data) else { return }
        artworkImage = img
    }
}
