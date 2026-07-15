import SwiftUI

/// Single-line label that scrolls horizontally when the text is wider than its
/// container (marquee). Short text stays left-aligned and still.
///
/// Long titles use a dual-copy loop so the end of the string leads back into
/// the start without a blank gap.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var foreground: Color = .primary
    /// Points per second while scrolling.
    var speed: Double = 28
    /// Pause at the start before each pass, in seconds.
    var endPause: Double = 1.2
    /// Gap between the end of the string and the repeated lead-in.
    var gap: CGFloat = 40

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animationToken = UUID()

    private var needsScroll: Bool {
        textWidth > containerWidth + 1 && containerWidth > 0 && textWidth > 0
    }

    var body: some View {
        GeometryReader { container in
            let width = container.size.width
            HStack(spacing: gap) {
                label
                if needsScroll {
                    label
                }
            }
            .background(
                // Measure a single label (not the duplicated row).
                label
                    .hidden()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: MarqueeTextWidthKey.self,
                                value: geo.size.width
                            )
                        }
                    )
            )
            .offset(x: needsScroll ? offset : 0)
            .frame(width: width, alignment: .leading)
            .clipped()
            .onAppear {
                containerWidth = width
                restartAnimation()
            }
            .onChange(of: width) { newWidth in
                containerWidth = newWidth
                restartAnimation()
            }
        }
        .onPreferenceChange(MarqueeTextWidthKey.self) { w in
            if abs(w - textWidth) > 0.5 {
                textWidth = w
                restartAnimation()
            }
        }
        .onChange(of: text) { _ in
            offset = 0
            restartAnimation()
        }
        .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func restartAnimation() {
        let token = UUID()
        animationToken = token
        offset = 0
        guard needsScroll else { return }

        let travel = textWidth + gap
        let duration = max(Double(travel) / max(speed, 1), 0.8)

        DispatchQueue.main.asyncAfter(deadline: .now() + endPause) {
            guard animationToken == token else { return }
            runLoop(token: token, travel: travel, duration: duration)
        }
    }

    private func runLoop(token: UUID, travel: CGFloat, duration: Double) {
        guard animationToken == token, needsScroll else { return }
        withAnimation(.linear(duration: duration)) {
            offset = -travel
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard animationToken == token else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { offset = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + endPause) {
                guard animationToken == token else { return }
                runLoop(token: token, travel: travel, duration: duration)
            }
        }
    }
}

private struct MarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
