import SwiftUI

/// Peek equalizer — beat + tone under the track title.
/// Subtle full-bleed bars with cover-art color, driven by live samples when available.
struct AuroraEqualizerView: View {
    @ObservedObject private var pulse = MediaPeekPulse.shared
    @ObservedObject private var sampler = MusicAudioSampler.shared

    var isActive: Bool = true
    var barCount: Int = 32
    var fps: Double = 48

    /// Bars occupy the lower portion so text stays primary.
    private let heightCeiling: CGFloat = 0.56
    private let heightFloor: CGFloat = 0.08

    var body: some View {
        let playing = isActive && pulse.isPlaying
        let _ = sampler.bands
        let _ = sampler.kick
        let _ = sampler.beatAnchor
        let _ = sampler.beatPeriod
        let _ = sampler.lastOnsetAt
        let _ = sampler.brightness
        let _ = sampler.level

        TimelineView(.animation(minimumInterval: playing ? 1.0 / fps : 0.25, paused: !isActive)) { context in
            let now = context.date
            let kickRaw = playing ? pulse.beatKick(at: now) : 0.03
            let kick = CGFloat(min(0.85, kickRaw * 0.9))
            let beatPhase = pulse.beatPhase(at: now)
            let near = min(beatPhase, 1 - beatPhase)
            let pump = exp(-(near * near) * 100)
            let tone = pulse.toneMix(at: now)
            let palette = pulse.palette
            let live = pulse.isSampleDriven
            let overall = CGFloat(playing ? pulse.sampleLevel : 0)

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let spacing: CGFloat = 2.0
                let barW = max(1.8, (w - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))

                ZStack(alignment: .bottom) {
                    softBackdrop(
                        palette: palette,
                        kick: Double(kick),
                        beatPhase: beatPhase,
                        tone: tone,
                        live: live,
                        size: geo.size
                    )

                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(0..<barCount, id: \.self) { i in
                            let raw = pulse.bandLevel(index: i, count: barCount, at: now)
                            // Musical curve: rhythm-first so every bar hits the beat.
                            let body = pow(max(0, raw), 0.72)
                            let mid = Double(barCount - 1) / 2.0
                            let dist = abs(Double(i) - mid) / max(mid, 1)
                            let center = 1.0 - dist * 0.10
                            let t = Double(i) / Double(max(barCount - 1, 1))
                            let boost = Double(kick) * (0.16 + 0.28 * (1.0 - t))
                                + pump * (0.10 + 0.14 * (1.0 - t))
                            let shaped = heightFloor
                                + CGFloat((body * center + boost + Double(overall) * 0.05))
                                * (heightCeiling - heightFloor)
                            let heightFrac = min(heightCeiling, max(heightFloor, shaped))

                            let color = barColor(
                                index: i,
                                heightFrac: heightFrac,
                                kick: Double(kick),
                                tone: tone,
                                palette: palette
                            )
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            color.opacity(0.12),
                                            color.opacity(0.48),
                                            color.opacity(0.62 + kick * 0.22)
                                        ],
                                        startPoint: .bottom,
                                        endPoint: .top
                                    )
                                )
                                .frame(width: barW, height: max(3, h * heightFrac))
                                .shadow(
                                    color: color.opacity(0.14 + kick * 0.26),
                                    radius: 1.5 + kick * 3.5,
                                    y: 0
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
                    .scaleEffect(x: 1, y: 1 + kick * 0.045, anchor: .bottom)
                    .opacity(0.90 + kick * 0.10)
                    .transaction { $0.animation = nil }

                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.58),
                            Color.black.opacity(0.18),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.58)
                    )
                    .allowsHitTesting(false)
                }
                .drawingGroup(opaque: false)
            }
        }
    }

    private func barColor(
        index: Int,
        heightFrac: CGFloat,
        kick: Double,
        tone: Double,
        palette: CoverArtPalette
    ) -> Color {
        let x = Double(index) / Double(max(barCount - 1, 1))
        let low = palette.deep.mixed(with: palette.secondary, t: 0.4)
        let mid = palette.primary.mixed(with: palette.accent, t: 0.3)
        let high = palette.accent.mixed(with: palette.highlight, t: 0.45)
        let stops = [low, mid, high]
        let pos = min(1.99, x * 2.0 + (tone - 0.5) * 0.25)
        let i0 = min(stops.count - 1, max(0, Int(pos)))
        let i1 = min(stops.count - 1, i0 + 1)
        let frac = pos - Double(i0)
        var rgb = stops[i0].mixed(with: stops[i1], t: frac)

        if kick > 0.1 {
            rgb = rgb.mixed(with: palette.highlight, t: kick * 0.28)
        }
        let lift = 0.6 + Double(heightFrac) * 0.65 + kick * 0.1
        rgb = rgb.scaled(brightness: lift)
        rgb = rgb.mixed(with: CoverArtPalette.RGB(r: 0.88, g: 0.9, b: 0.96), t: 0.12)
        return rgb.color
    }

    private func softBackdrop(
        palette: CoverArtPalette,
        kick: Double,
        beatPhase: Double,
        tone: Double,
        live: Bool,
        size: CGSize
    ) -> some View {
        let shift = CGFloat(sin(beatPhase * .pi * 2) * 0.05)
        return ZStack {
            Color.black.opacity(0.32)

            EllipticalGradient(
                colors: [
                    palette.primary.color.opacity(0.12 + kick * 0.14),
                    Color.clear
                ],
                center: UnitPoint(x: 0.32 + shift, y: 0.88),
                startRadiusFraction: 0.04,
                endRadiusFraction: 0.72
            )

            EllipticalGradient(
                colors: [
                    palette.accent.color.opacity(0.07 + kick * 0.08),
                    Color.clear
                ],
                center: UnitPoint(x: 0.7 - shift, y: 0.72),
                startRadiusFraction: 0.04,
                endRadiusFraction: 0.55
            )

            LinearGradient(
                colors: [Color.clear, palette.deep.color.opacity(0.22)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .frame(width: size.width, height: size.height)
        .opacity(live ? 1.0 : 0.9)
    }
}
