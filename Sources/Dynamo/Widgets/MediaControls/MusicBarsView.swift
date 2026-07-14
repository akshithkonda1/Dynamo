import SwiftUI

/// A small decorative "dancing bars" music indicator.
///
/// This is deliberately *not* a real audio spectrum — there's no FFT or audio
/// tap (which would need extra entitlements and CPU). The bars just animate to
/// random heights on a timer while something is playing, which reads as "music
/// is playing" perfectly well and costs almost nothing.
struct MusicBarsView: View {
    var isPlaying: Bool
    var barCount: Int = 4
    var maxHeight: CGFloat = 14
    var color: Color = NotchTheme.textPrimary

    @State private var scales: [CGFloat]
    private let ticker = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    init(isPlaying: Bool, barCount: Int = 4, maxHeight: CGFloat = 14, color: Color = NotchTheme.textPrimary) {
        self.isPlaying = isPlaying
        self.barCount = barCount
        self.maxHeight = maxHeight
        self.color = color
        _scales = State(initialValue: Array(repeating: 0.4, count: barCount))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: max(3, maxHeight * scales[index]))
            }
        }
        .frame(height: maxHeight)
        .onReceive(ticker) { _ in
            guard isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.26)) {
                scales = scales.map { _ in CGFloat.random(in: 0.35...1.0) }
            }
        }
        .onChange(of: isPlaying) { playing in
            withAnimation(.easeInOut(duration: 0.26)) {
                scales = playing
                    ? scales.map { _ in CGFloat.random(in: 0.35...1.0) }
                    : Array(repeating: 0.3, count: barCount)
            }
        }
    }
}
