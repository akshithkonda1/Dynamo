import Foundation

/// Rhythm + spectrum for equalizers.
///
/// **Rhythm master clock** = continuous beat phase (onset-locked when sampling,
/// otherwise playback elapsed × BPM). Views call `beatPhase(at:)` / `beatKick(at:)`
/// every frame so motion never freezes between FFT publishes.
@MainActor
final class MediaPeekPulse: ObservableObject {
    static let shared = MediaPeekPulse()

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var bpm: Double = 120
    @Published private(set) var artworkData: Data?
    @Published private(set) var palette: CoverArtPalette = .auroraFallback
    @Published private(set) var trackKey: String = ""
    @Published private(set) var sourceBundleID: String?

    private(set) var elapsedSampledAt: Date = .distantPast
    private var lastArtworkHash: Int = 0
    private var trackSeed: UInt64 = 0
    /// Transport-side phase offset so audio onsets can snap the grid.
    private var transportPhaseOffset: Double = 0
    private let sampler = MusicAudioSampler.shared

    var isSampleDriven: Bool { sampler.isLive && isPlaying }
    var sampleBands: [Float] { sampler.bands }
    var sampleKick: Float { sampler.kick }
    var sampleLevel: Float { sampler.level }
    var sampleBrightness: Float { sampler.brightness }

    private init() {}

    func sync(from info: NowPlayingInfo) {
        isPlaying = info.isPlaying
        elapsed = max(0, info.elapsed)
        duration = max(0, info.duration)
        elapsedSampledAt = Date()

        let key = "\(info.title)\u{1}\(info.artist)\u{1}\(info.album)"
        let artChanged = info.artworkData != artworkData
        if key != trackKey {
            trackKey = key
            trackSeed = Self.hash64(key)
            transportPhaseOffset = 0
        }
        artworkData = info.artworkData
        sourceBundleID = Self.bundleID(for: info.sourceApp)

        if artChanged {
            let hash = info.artworkData?.hashValue ?? 0
            if hash != lastArtworkHash {
                lastArtworkHash = hash
                palette = CoverArtPalette.extract(from: info.artworkData)
            }
        }

        // Tempo: live detection > estimate
        if sampler.isLive, sampler.detectedBPM >= 60, sampler.detectedBPM <= 180 {
            bpm = sampler.detectedBPM
        } else if sampler.detectedBPM >= 60, sampler.detectedBPM <= 180, sampler.beatAnchor > 0 {
            bpm = sampler.detectedBPM
        } else {
            bpm = estimatedBPM(from: palette, duration: duration, seed: trackSeed)
        }

        // Keep sampler warm while music is up; retarget when player app changes.
        if info.isPlaying,
           !info.title.isEmpty,
           info.title != NowPlayingInfo.empty.title {
            sampler.setActive(true, preferredBundleID: sourceBundleID)
            sampler.refreshTarget(preferredBundleID: sourceBundleID)
        } else if !info.isPlaying {
            // Paused / stopped / empty — release the process tap.
            sampler.setActive(false)
        }
    }

    func musicTime(at now: Date = Date()) -> TimeInterval {
        guard isPlaying else { return elapsed }
        let delta = now.timeIntervalSince(elapsedSampledAt)
        guard delta > 0, delta < 4 else { return elapsed }
        let t = elapsed + delta
        if duration > 0.5 { return min(t, duration) }
        return t
    }

    /// Continuous 0…1 phase (0 = downbeat). Always interpolates in real time.
    func beatPhase(at now: Date = Date()) -> Double {
        // 1) Live audio grid (onset-locked) — free-runs between FFT frames.
        if isSampleDriven, sampler.beatPeriod > 0.05, sampler.beatAnchor > 0 {
            return Double(sampler.phase(at: now))
        }
        // 2) Even when not fully live, prefer last locked grid if we have one.
        if sampler.beatPeriod > 0.05, sampler.beatAnchor > 0, isPlaying {
            return Double(sampler.phase(at: now))
        }
        // 3) Transport clock: elapsed × BPM (+ optional onset snap offset).
        let t = musicTime(at: now)
        let bps = max(0.5, bpm / 60.0)
        var x = t * bps + transportPhaseOffset
        x = x - floor(x)
        return x
    }

    /// Downbeat pulse 0…1 — sharp on the beat, silent mid-bar.
    func beatKick(at now: Date = Date()) -> Double {
        let p = beatPhase(at: now)
        let near = min(p, 1 - p)
        // Narrow Gaussian on the beat grid — visual "kick" of the song.
        let phasePulse = exp(-(near * near) * 120)

        if isSampleDriven || sampler.lastOnsetAt > 0 {
            let env = Double(sampler.kickEnvelope(at: now))
            // Real onsets + grid pulse so rhythm never dies between hits.
            return min(1, max(env, phasePulse * 0.95))
        }
        return phasePulse
    }

    /// Spectrum slice for bar `index` of `count`.
    func bandLevel(index: Int, count: Int, at now: Date = Date()) -> Double {
        let n = max(count, 1)
        let i = min(max(index, 0), n - 1)
        let kick = beatKick(at: now)
        let phase = beatPhase(at: now)
        let near = min(phase, 1 - phase)
        let pump = exp(-(near * near) * 90)

        if isSampleDriven, !sampleBands.isEmpty {
            let src = sampleBands
            let start = (i * src.count) / n
            let end = max(start + 1, ((i + 1) * src.count) / n)
            var sum: Float = 0
            var peak: Float = 0
            var c = 0
            for b in start..<min(end, src.count) {
                sum += src[b]
                peak = max(peak, src[b])
                c += 1
            }
            let mean = c > 0 ? sum / Float(c) : 0
            var v = mean * 0.30 + peak * 0.70
            let t = Double(i) / Double(max(n - 1, 1))
            // Rhythm is the master: every bar hits the beat hard, bass harder.
            let rhythm = Float(
                kick * (0.62 - 0.28 * t)
                + pump * (0.28 - 0.12 * t)
            )
            v = min(1, v * 1.05 + rhythm)
            return Double(min(1, max(0.10, v)))
        }

        return syntheticBand(index: i, count: n, at: now, kick: kick, phase: phase)
    }

    func toneMix(at now: Date = Date()) -> Double {
        if isSampleDriven { return Double(sampleBrightness) }
        let t = musicTime(at: now)
        return 0.35 + 0.3 * (0.5 + 0.5 * sin(t * 0.15 + Double(trackSeed % 7)))
    }

    private func syntheticBand(
        index: Int,
        count: Int,
        at now: Date,
        kick: Double,
        phase: Double
    ) -> Double {
        guard isPlaying else { return 0.16 }
        let n = max(count, 1)
        let i = min(max(index, 0), n - 1)
        let t = Double(i) / Double(max(n - 1, 1))

        // Strictly phase-locked oscillators (same beat grid as kick).
        let barPhase = Double(i) * (2 * .pi / Double(n))
        // cos(0) = 1 at downbeat so every bar peaks together on the beat.
        let fund = 0.5 + 0.5 * cos(phase * 2 * .pi + barPhase * 0.35)
        let harm = 0.5 + 0.5 * cos(phase * 4 * .pi + barPhase * 0.55)
        let mix = fund * 0.65 + harm * 0.35
        let near = min(phase, 1 - phase)
        let pump = exp(-(near * near) * 90)

        let kickAmt = kick * (0.60 - 0.28 * t) + pump * (0.22 - 0.1 * t)
        return min(1, 0.12 + mix * 0.48 + kickAmt)
    }

    private static func bundleID(for app: MediaPlayerApp?) -> String? {
        switch app {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .other, .none: return nil
        }
    }

    private func estimatedBPM(from palette: CoverArtPalette, duration: TimeInterval, seed: UInt64) -> Double {
        // Prefer a mid dance tempo when we have no audio — better than random.
        let energy = palette.primary.saturation * 0.45 + palette.primary.luminance * 0.25
        var bpm = 110 + energy * 30 + Double(seed % 7)
        if duration > 360 { bpm *= 0.9 }
        else if duration > 0, duration < 150 { bpm *= 1.05 }
        return min(140, max(90, bpm))
    }

    private static func hash64(_ string: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in string.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }
}
