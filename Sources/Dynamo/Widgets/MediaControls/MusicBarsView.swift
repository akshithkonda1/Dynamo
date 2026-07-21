import SwiftUI

/// Decorative dancing bars — not a real spectrum. Phase-offset sine motion
/// at a low frame budget so ambient media stays cheap.
struct MusicBarsView: View {
    var isPlaying: Bool
    var barCount: Int = 5
    var maxHeight: CGFloat = 14
    var color: Color = NotchTheme.textPrimary

    var body: some View {
        // ~12 fps when playing; fully paused when not — no idle TimelineView churn.
        TimelineView(.animation(minimumInterval: isPlaying ? 1.0 / 12.0 : 60, paused: !isPlaying)) { context in
            let t = isPlaying ? context.date.timeIntervalSinceReferenceDate : 0
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let phase = Double(index) * 0.55
                    let wave = isPlaying
                        ? (sin(t * 4.8 + phase) * 0.5 + 0.5) * 0.65 + 0.35
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
            .drawingGroup(opaque: false) // flatten bar redraws into one layer
        }
    }
}
