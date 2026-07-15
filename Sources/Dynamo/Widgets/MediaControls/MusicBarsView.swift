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
        .task(id: isPlaying) {
            guard isPlaying else {
                withAnimation(.easeInOut(duration: 0.26)) {
                    scales = Array(repeating: 0.3, count: barCount)
                }
                return
            }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.26)) {
                    scales = scales.map { _ in CGFloat.random(in: 0.35...1.0) }
                }
                try? await Task.sleep(for: .seconds(0.28))
            }
        }
    }
}
