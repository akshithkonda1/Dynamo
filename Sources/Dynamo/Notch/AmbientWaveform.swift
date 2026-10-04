import SwiftUI

/// Decorative Ambient waveform — **not** live audio levels.
///
/// Reading another app's audio requires Screen & System Audio Recording
/// (ScreenCaptureKit). This equalizer is a phase-locked visual only: five
/// capsules driven by `TimelineView` at ~30 fps, or a static settled row.
enum AmbientWaveform {
    static let barCount = 5
    /// ~30 fps. The view must not install a TimelineView when `shouldAnimate` is false.
    static let timelineInterval: TimeInterval = 1.0 / 30.0
    /// Reference red when album art has no usable palette.
    static let defaultTint = Color(red: 1.0, green: 0.18, blue: 0.22)

    /// Single decision the view (via `AmbientWaveformState`) must call.
    static func shouldAnimate(isPlaying: Bool, reduceMotion: Bool, screenAsleep: Bool) -> Bool {
        isPlaying && !reduceMotion && !screenAsleep
    }

    /// Decorative 0…1 heights. Flattened when not animating; time-varying otherwise.
    static func barHeights(at date: Date, animate: Bool) -> [CGFloat] {
        if !animate {
            return [0.30, 0.22, 0.26, 0.20, 0.24]
        }
        let t = date.timeIntervalSinceReferenceDate
        return (0..<barCount).map { index in
            let phase = t * 2.35 + Double(index) * 0.82
            let wave = 0.28 + 0.72 * (0.5 + 0.5 * sin(phase))
            return CGFloat(wave)
        }
    }

    static func tint(hasArtwork: Bool, palette: CoverArtPalette) -> Color {
        guard hasArtwork else { return defaultTint }
        return palette.accent.boosted(saturation: 1.3).color
    }
}

/// Testable view-model. The view's TimelineView flag **must** come from here,
/// and this flag **must** call `AmbientWaveform.shouldAnimate` — no local copy.
struct AmbientWaveformState: Equatable {
    var isPlaying: Bool
    var reduceMotion: Bool
    var screenAsleep: Bool

    var shouldAnimate: Bool {
        AmbientWaveform.shouldAnimate(
            isPlaying: isPlaying,
            reduceMotion: reduceMotion,
            screenAsleep: screenAsleep
        )
    }
}

/// Five decorative bars. TimelineView is installed only when `model.shouldAnimate`.
struct AmbientWaveformView: View {
    var isPlaying: Bool
    var tint: Color
    var maxHeight: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var screenSleep = ScreenSleepMonitor.shared

    var model: AmbientWaveformState {
        AmbientWaveformState(
            isPlaying: isPlaying,
            reduceMotion: reduceMotion,
            screenAsleep: screenSleep.isAsleep
        )
    }

    var body: some View {
        let animate = model.shouldAnimate
        Group {
            if animate {
                TimelineView(.periodic(from: .now, by: AmbientWaveform.timelineInterval)) { context in
                    bars(date: context.date, animate: true)
                }
            } else {
                bars(date: .distantPast, animate: false)
            }
        }
        .frame(height: maxHeight, alignment: .center)
        .accessibilityHidden(true)
    }

    private func bars(date: Date, animate: Bool) -> some View {
        let heights = AmbientWaveform.barHeights(at: date, animate: animate)
        return HStack(alignment: .center, spacing: 2) {
            ForEach(0..<AmbientWaveform.barCount, id: \.self) { index in
                let unit = index < heights.count ? heights[index] : 0.2
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: 2.4, height: max(3, maxHeight * unit))
            }
        }
        .transaction { $0.animation = nil }
    }
}
