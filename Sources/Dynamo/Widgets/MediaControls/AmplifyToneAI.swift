import Foundation

/// On-device genre / tone intelligence for Amplify EQ.
///
/// Goals: hear music closer to how it was mixed — clear notes, balanced
/// volume, presence without harshness. Pure on-device (no cloud APIs).
///
/// - Linear softmax classifier over spectral features
/// - Local metadata prior (MusicKit / now-playing genre strings)
/// - Ephemeral session EMA (never persisted)
/// - Genre → note-region dB map + volume / presence / clarity targets
enum AmplifyToneAI {

    static let genres: [String] = [
        "pop", "classical", "electronic", "hiphop", "rock",
        "jazz", "speech", "ambient", "metal", "folk", "unknown"
    ]

    /// Feature order matches Python FEATURE_KEYS (bias is appended as 1).
    private static let featureCount = 9

    private static let weights: [[Float]] = [
        [0.4, 0.8, 0.3, 0.2, 0.1, -0.8, 0.5, 0.6, 0.2],
        [-1.2, 0.6, 1.4, -0.3, 1.6, -0.5, 1.0, 0.3, -0.1],
        [1.6, 0.4, -0.4, 0.1, -0.3, -0.9, 0.6, -0.2, 0.1],
        [2.0, -0.6, -0.5, -0.2, -0.4, -0.7, 0.2, -0.3, 0.15],
        [0.3, 0.5, 0.2, 0.3, 0.0, -0.6, 0.5, 0.8, 0.1],
        [-0.3, 0.2, 0.6, 0.1, 0.7, -0.4, 0.4, 0.5, 0.05],
        [-1.5, 0.3, 0.2, 2.2, 0.3, 2.5, -0.4, 1.2, 0.0],
        [0.5, 0.4, -0.8, -0.4, 0.4, -0.5, 0.7, -0.2, 0.0],
        [0.6, 0.3, -0.2, 0.4, -0.5, -0.7, 0.3, 1.0, 0.1],
        [-0.4, 0.2, 0.5, 0.0, 0.5, -0.3, 0.3, 0.6, 0.05],
        [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    ]

    private static let metadataKeywords: [String: [String]] = [
        "pop": ["pop", "dance pop", "synth-pop", "k-pop", "electropop", "teen pop"],
        "classical": [
            "classical", "orchestral", "symphony", "opera", "baroque", "chamber",
            "mozart", "bach", "beethoven", "romantic era"
        ],
        "electronic": [
            "electronic", "edm", "house", "techno", "trance", "dubstep",
            "drum and bass", "synthwave", "electro"
        ],
        "hiphop": ["hip-hop", "hip hop", "rap", "trap", "r&b", "rnb", "soul"],
        "rock": ["rock", "indie rock", "alternative", "punk", "grunge", "hard rock"],
        "jazz": ["jazz", "swing", "bebop", "blues", "smooth jazz"],
        "speech": ["podcast", "audiobook", "spoken", "speech", "comedy", "interview"],
        "ambient": ["ambient", "chillout", "downtempo", "new age", "drone"],
        "metal": ["metal", "death metal", "black metal", "thrash", "hardcore"],
        "folk": ["folk", "acoustic", "country", "bluegrass", "americana", "singer-songwriter"]
    ]

    /// Per-genre note-region dB offsets — “hear every note” without wrecking fidelity.
    /// Keys match DynamoEQCurves band labels.
    static let genreNoteBias: [String: [String: Float]] = [
        "pop": [
            "sub": 0.25, "punch": 0.65, "body": 0.35, "mud": -0.55,
            "warmth": 0.15, "presence": 0.85, "sheen": 0.40, "air": 0.30, "brilliance": 0.15
        ],
        "classical": [
            "sub": -0.15, "punch": -0.10, "body": 0.25, "mud": -0.65,
            "warmth": 0.35, "presence": 0.45, "sheen": 0.55, "air": 0.70, "brilliance": 0.45
        ],
        "electronic": [
            "sub": 0.95, "punch": 0.55, "body": 0.15, "mud": -0.45,
            "warmth": -0.05, "presence": 0.35, "sheen": 0.20, "air": 0.05, "brilliance": 0.0
        ],
        "hiphop": [
            "sub": 1.05, "punch": 0.70, "body": 0.30, "mud": -0.60,
            "warmth": 0.30, "presence": 0.50, "sheen": 0.05, "air": -0.05, "brilliance": -0.10
        ],
        "rock": [
            "sub": 0.30, "punch": 0.50, "body": 0.65, "mud": -0.55,
            "warmth": 0.25, "presence": 0.70, "sheen": -0.15, "air": 0.15, "brilliance": -0.05
        ],
        "jazz": [
            "sub": -0.05, "punch": 0.10, "body": 0.40, "mud": -0.45,
            "warmth": 0.60, "presence": 0.40, "sheen": 0.40, "air": 0.50, "brilliance": 0.20
        ],
        "speech": [
            "sub": -1.0, "punch": -0.50, "body": 0.15, "mud": -0.85,
            "warmth": 0.20, "presence": 1.35, "sheen": 0.50, "air": 0.25, "brilliance": 0.10
        ],
        "ambient": [
            "sub": 0.40, "punch": -0.25, "body": 0.25, "mud": -0.25,
            "warmth": 0.45, "presence": 0.10, "sheen": 0.35, "air": 0.60, "brilliance": 0.40
        ],
        "metal": [
            "sub": 0.45, "punch": 0.60, "body": 0.55, "mud": -0.85,
            "warmth": -0.10, "presence": 0.75, "sheen": -0.35, "air": -0.10, "brilliance": -0.20
        ],
        "folk": [
            "sub": -0.10, "punch": 0.15, "body": 0.55, "mud": -0.40,
            "warmth": 0.55, "presence": 0.50, "sheen": 0.30, "air": 0.40, "brilliance": 0.20
        ],
        "unknown": [
            "sub": 0.15, "punch": 0.20, "body": 0.20, "mud": -0.40,
            "warmth": 0.15, "presence": 0.45, "sheen": 0.20, "air": 0.25, "brilliance": 0.10
        ]
    ]

    struct Features: Equatable {
        var bassRatio: Float
        var brightness: Float
        var crestDB: Float
        var zcr: Float
        var dynamicRangeDB: Float
        var speechLikelihood: Float
        var bandwidthHz: Float
        var midRatio: Float
        var rms: Float = 0.05

        func vector() -> [Float] {
            [
                clamp01(bassRatio),
                clamp01(brightness),
                clamp01(crestDB / 20),
                clamp01(zcr * 2.5),
                clamp01(dynamicRangeDB / 28),
                clamp01(speechLikelihood),
                clamp01(bandwidthHz / 16_000),
                clamp01(midRatio),
                1.0
            ]
        }
    }

    /// Full live guidance for the process-tap path.
    struct Verdict: Equatable {
        var genre: String
        var confidence: Float
        /// Overall wet makeup (volume) multiplier.
        var makeupMul: Float
        /// High-frequency blend vs dry (1 = full EQ HF, lower = tamer).
        var hfMul: Float
        /// Presence / note intelligibility lift (1…~1.12).
        var presenceMul: Float
        /// Sub/punch body lift (1…~1.10).
        var bassMul: Float
        /// Note-region dB map for curve rebuild.
        var noteBias: [String: Float]
        var source: String
        var displayLabel: String {
            let name = genre.prefix(1).uppercased() + genre.dropFirst()
            if confidence < 0.32 { return "Tone AI" }
            return "AI \(name)"
        }
    }

    final class SessionMemory: @unchecked Sendable {
        private let lock = NSLock()
        private var ema: [Float]?
        private let alpha: Float = 0.18

        func reset() {
            lock.lock()
            ema = nil
            lock.unlock()
        }

        func blend(current: [Float]) -> [Float] {
            lock.lock()
            defer { lock.unlock() }
            let free = Array(current.dropLast())
            if var e = ema, e.count == free.count {
                for i in 0..<e.count {
                    e[i] = (1 - alpha) * e[i] + alpha * free[i]
                }
                ema = e
                return e + [1.0]
            } else {
                ema = free
                return current
            }
        }
    }

    static let session = SessionMemory()

    static func classify(
        features: Features,
        metadataText: String? = nil
    ) -> Verdict {
        var vec = features.vector()
        vec = session.blend(current: vec)

        var logits = [Float](repeating: 0, count: genres.count)
        for g in 0..<genres.count {
            var s: Float = 0
            let row = weights[g]
            for j in 0..<featureCount {
                s += row[j] * vec[j]
            }
            logits[g] = s
        }

        var source = "audio"
        if let meta = metadataPrior(metadataText) {
            if let idx = genres.firstIndex(of: meta.genre) {
                logits[idx] += 1.8 * meta.confidence
                source = "blend"
            }
        }

        let probs = softmax(logits)
        var bestIdx = 0
        var bestP: Float = 0
        for i in 0..<probs.count {
            if probs[i] > bestP {
                bestP = probs[i]
                bestIdx = i
            }
        }
        var genre = genres[bestIdx]
        var conf = bestP
        if conf < 0.28 {
            genre = "unknown"
            conf = max(conf, 0.2)
            source = "audio"
        }

        let targets = listeningTargets(genre: genre, features: features)
        var noteBias = genreNoteBias[genre] ?? genreNoteBias["unknown"]!
        // Live note balancing from spectrum: lift weak bands, tame harsh HF.
        noteBias = adaptNotes(base: noteBias, features: features)

        return Verdict(
            genre: genre,
            confidence: conf,
            makeupMul: targets.makeup,
            hfMul: targets.hf,
            presenceMul: targets.presence,
            bassMul: targets.bass,
            noteBias: noteBias,
            source: source
        )
    }

    static func featuresFromLive(
        rms: Float,
        crest: Float,
        highRatio: Float,
        zcr: Float
    ) -> Features {
        let bassProxy = max(0, min(1, 1.15 - highRatio * 0.9 - zcr * 1.2))
        let midProxy = max(0.05, min(0.7, 0.55 - abs(highRatio - 0.5) * 0.3))
        let speech = max(0, min(1, (zcr - 0.05) * 4 + (0.35 - bassProxy) * 1.5))
        let crestDB = 20 * log10(max(crest, 1e-3))
        let bw: Float = highRatio > 0.7 ? 14_000 : (highRatio > 0.4 ? 11_000 : 8_000)
        return Features(
            bassRatio: bassProxy * 0.55 + (1 - highRatio) * 0.25,
            brightness: min(1, highRatio * 0.85),
            crestDB: crestDB,
            zcr: zcr,
            dynamicRangeDB: max(4, min(28, crestDB * 1.1)),
            speechLikelihood: speech,
            bandwidthHz: bw,
            midRatio: midProxy,
            rms: rms
        )
    }

    /// Band dB bias for curve rebuild (scaled by confidence).
    static func scaledNoteBias(for genre: String, confidence: Float, intensity: Float = 0.72) -> [String: Float] {
        let base = genreNoteBias[genre] ?? genreNoteBias["unknown"]!
        let scale = intensity * max(0.35, min(1.0, confidence + 0.25))
        return base.mapValues { $0 * scale }
    }

    // MARK: - Private

    private static func listeningTargets(
        genre: String,
        features: Features
    ) -> (makeup: Float, hf: Float, presence: Float, bass: Float) {
        // Intent: even, clear, “as mixed” — not a loudness war.
        var makeup: Float = 1.02
        var hf: Float = 0.98
        var presence: Float = 1.04
        var bass: Float = 1.02

        switch genre {
        case "classical":
            // Preserve dynamics; open air; gentle presence for quiet passages.
            makeup = 1.00; hf = 1.02; presence = 1.06; bass = 0.99
        case "pop":
            makeup = 1.04; hf = 0.98; presence = 1.08; bass = 1.03
        case "electronic":
            makeup = 1.05; hf = 0.94; presence = 1.04; bass = 1.08
        case "hiphop":
            makeup = 1.06; hf = 0.92; presence = 1.05; bass = 1.10
        case "rock":
            makeup = 1.03; hf = 0.95; presence = 1.07; bass = 1.04
        case "jazz":
            makeup = 1.01; hf = 1.00; presence = 1.05; bass = 1.00
        case "speech":
            makeup = 1.05; hf = 1.0; presence = 1.12; bass = 0.94
        case "ambient":
            makeup = 1.02; hf = 1.03; presence = 1.02; bass = 1.03
        case "metal":
            makeup = 1.03; hf = 0.90; presence = 1.08; bass = 1.05
        case "folk":
            makeup = 1.02; hf = 1.00; presence = 1.06; bass = 1.00
        default:
            makeup = 1.03; hf = 0.98; presence = 1.05; bass = 1.02
        }

        // Volume intelligence: lift quiet content so notes are audible.
        if features.rms < 0.015 {
            makeup = min(1.16, makeup * 1.08)
            presence = min(1.14, presence * 1.04)
        } else if features.rms < 0.035 {
            makeup = min(1.12, makeup * 1.04)
            presence = min(1.12, presence * 1.02)
        } else if features.rms > 0.18 {
            // Hot masters — hold volume, tame air.
            makeup = min(makeup, 1.02)
            hf = min(hf, 0.92)
        }

        // Dynamic classical-like material: don't squash crest with volume.
        if features.crestDB > 12 {
            makeup = min(makeup, 1.06)
        }
        // Harsh / bright: protect ears, keep presence via mid focus.
        if features.brightness > 0.55 {
            hf *= 0.92
            presence = min(1.12, presence * 1.03)
        }
        // Bass-heavy: keep body, don't bury vocals.
        if features.bassRatio > 0.42 {
            bass = min(1.12, bass * 1.03)
            presence = min(1.12, presence * 1.02)
            hf = min(hf, 0.95)
        }
        // Speech-like: maximize intelligibility.
        if features.speechLikelihood > 0.5 {
            presence = max(presence, 1.10)
            bass = min(bass, 0.96)
            makeup = max(makeup, 1.04)
        }
        // Narrow bandwidth (low quality streams): fill body, cut harsh air.
        if features.bandwidthHz < 9_000 {
            presence = min(1.12, presence * 1.05)
            hf = min(hf, 0.90)
            makeup = min(1.10, makeup * 1.03)
        }

        return (
            max(0.92, min(1.16, makeup)),
            max(0.82, min(1.06, hf)),
            max(0.96, min(1.14, presence)),
            max(0.92, min(1.12, bass))
        )
    }

    private static func adaptNotes(base: [String: Float], features: Features) -> [String: Float] {
        var out = base
        // Sparse / quiet → lift presence + air so quiet notes speak.
        if features.rms < 0.03 || features.dynamicRangeDB > 16 {
            out["presence", default: 0] += 0.25
            out["air", default: 0] += 0.20
            out["sheen", default: 0] += 0.12
        }
        // Muddy mid build-up
        if features.midRatio > 0.5, features.brightness < 0.35 {
            out["mud", default: 0] -= 0.25
            out["presence", default: 0] += 0.20
        }
        // Thin → body
        if features.bassRatio < 0.18, features.speechLikelihood < 0.4 {
            out["body", default: 0] += 0.25
            out["warmth", default: 0] += 0.15
        }
        // Harsh top
        if features.brightness > 0.55 {
            out["brilliance", default: 0] -= 0.30
            out["sheen", default: 0] -= 0.15
            out["presence", default: 0] += 0.10
        }
        return out
    }

    private static func metadataPrior(_ text: String?) -> (genre: String, confidence: Float)? {
        guard let text, !text.isEmpty else { return nil }
        let blob = text.lowercased()
        var best: String?
        var bestHits = 0
        for (genre, keys) in metadataKeywords {
            let hits = keys.reduce(0) { $0 + (blob.contains($1) ? 1 : 0) }
            if hits > bestHits {
                bestHits = hits
                best = genre
            }
        }
        guard let best, bestHits > 0 else { return nil }
        let conf = min(0.92, 0.45 + 0.15 * Float(bestHits))
        return (best, conf)
    }

    private static func softmax(_ xs: [Float]) -> [Float] {
        let m = xs.max() ?? 0
        let exps = xs.map { exp($0 - m) }
        let s = exps.reduce(0, +) + 1e-12
        return exps.map { $0 / s }
    }

    private static func clamp01(_ x: Float) -> Float {
        max(0, min(1, x))
    }
}
