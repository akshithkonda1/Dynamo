import SwiftUI

/// Now Playing equalizer — **rhythm-first**.
/// Every frame recomputes beat phase from onset anchors / playback time so
/// bars hit the downbeat even between FFT publishes.
struct MusicBarsView: View {
    var isPlaying: Bool
    var barCount: Int = 6
    var maxHeight: CGFloat = 17
    var color: Color = NotchTheme.textPrimary

    @ObservedObject private var pulse = MediaPeekPulse.shared
    @ObservedObject private var sampler = MusicAudioSampler.shared

    var body: some View {
        let _ = sampler.bands
        let _ = sampler.kick
        let _ = sampler.beatAnchor
        let _ = sampler.beatPeriod
        let _ = sampler.lastOnsetAt
        let _ = sampler.level
        let _ = pulse.isPlaying

        TimelineView(
            .animation(
                minimumInterval: isPlaying ? 1.0 / 60.0 : 60,
                paused: !isPlaying
            )
        ) { context in
            let now = context.date
            let phase = isPlaying ? pulse.beatPhase(at: now) : 0
            let kick = isPlaying ? pulse.beatKick(at: now) : 0
            // Continuous pump peaking hard at downbeat (phase ≈ 0 / 1).
            let near = min(phase, 1 - phase)
            let pump = exp(-(near * near) * 100)

            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { index in
                    let wave = height(
                        index: index,
                        phase: phase,
                        kick: kick,
                        pump: pump,
                        now: now
                    )
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    color.opacity(0.35 + kick * 0.4),
                                    color
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 2.8, height: max(3.5, maxHeight * CGFloat(wave)))
                        .shadow(
                            color: color.opacity(0.12 + kick * 0.4),
                            radius: kick > 0.25 ? 2.2 : 0.5
                        )
                }
            }
            .frame(height: maxHeight, alignment: .center)
            .scaleEffect(x: 1, y: 1 + CGFloat(kick) * 0.14, anchor: .center)
            .opacity(isPlaying ? 1 : 0.4)
            .drawingGroup(opaque: false)
            // Disable implicit animations so bars hit the beat on-frame.
            .transaction { $0.animation = nil }
        }
    }

    private func height(
        index: Int,
        phase: Double,
        kick: Double,
        pump: Double,
        now: Date
    ) -> Double {
        guard isPlaying else { return 0.18 }

        let n = max(barCount, 1)
        let t = Double(index) / Double(max(n - 1, 1))

        // Spectrum (live FFT slice or synthetic phase-locked).
        let spectral = pulse.bandLevel(index: index, count: n, at: now)

        // Rhythm master — same phase for all bars, bass-weighted kick + grid pump.
        let bassW = 1.0 - t * 0.5
        let rhythm = kick * (0.55 * bassW + 0.18) + pump * (0.32 * bassW + 0.12)

        // Harmonic shimmer locked to beat phase (not wall clock) — peaks at downbeat.
        let barPhase = Double(index) * (2 * .pi / Double(n)) * 0.4
        let shimmer = 0.5 + 0.5 * cos(phase * 2 * .pi + barPhase)

        let mid = Double(n - 1) / 2.0
        let centerBoost = 1.0 - abs(Double(index) - mid) / max(mid, 1) * 0.10

        let body = pow(max(0, spectral), 0.62) * 0.42 + shimmer * 0.14
        let shaped = 0.10 + (body * centerBoost) + rhythm
        return min(1, max(0.10, shaped))
    }
}
