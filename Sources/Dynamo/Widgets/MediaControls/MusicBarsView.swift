import SwiftUI

/// Decorative dancing bars — not a real spectrum. Phase-offset sine motion
/// feels more “alive” than pure random jumps while staying cheap.
struct MusicBarsView: View {
    var isPlaying: Bool
    var barCount: Int = 5
    var maxHeight: CGFloat = 14
    var color: Color = NotchTheme.textPrimary

    var body: some View {
        TimelineView(.animation(minimumInterval: isPlaying ? 1.0 / 30.0 : 1.0, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let phase = Double(index) * 0.55
                    let wave = isPlaying
                        ? (sin(t * 5.2 + phase) * 0.5 + 0.5) * 0.65 + 0.35
                        : 0.28
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color, color.opacity(0.65)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 2.2, height: max(3, maxHeight * CGFloat(wave)))
                }
            }
            .frame(height: maxHeight)
        }
    }
}
