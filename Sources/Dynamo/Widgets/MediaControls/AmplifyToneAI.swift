import Foundation

/// On-device genre / tone intelligence for Amplify EQ.
///
/// Mirrors `Tools/DynamoEQ/dynamo_tone_ai.py`:
/// - Linear softmax classifier over spectral features (no cloud APIs)
/// - Optional local metadata prior (MusicKit / now-playing genre strings)
/// - Ephemeral session EMA (in-memory only — never persisted)
/// - Genre → live makeup / HF multipliers + EQ band bias map
///
/// Training corpora and scrapes are developer-side only (Python `train`);
/// the app ships weights as constants and never stores audio or lookups.
enum AmplifyToneAI {

    static let genres: [String] = [
        "pop", "classical", "electronic", "hiphop", "rock",
        "jazz", "speech", "ambient", "metal", "folk", "unknown"
    ]

    /// Feature order matches Python FEATURE_KEYS (bias is appended as 1).
    private static let featureCount = 9

    /// Genre × feature weights (embedded; same structure as Python `_WEIGHTS`).
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

    struct Features: Equatable {
        var bassRatio: Float
        var brightness: Float
        var crestDB: Float
        var zcr: Float
        var dynamicRangeDB: Float
        var speechLikelihood: Float
        var bandwidthHz: Float
        var midRatio: Float

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

    struct Verdict: Equatable {
        var genre: String
        var confidence: Float
        var makeupMul: Float
        var hfMul: Float
        var source: String
        var displayLabel: String {
            let name = genre.prefix(1).uppercased() + genre.dropFirst()
            if confidence < 0.35 { return "Tone AI" }
            return "AI \(name)"
        }
    }

    /// In-memory EMA of feature vectors for the current Amplify session only.
    /// Cleared on stop — never written to disk.
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
            // current includes bias 1.0 at end — EMA only over free features
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

        let (makeup, hf) = liveMultipliers(genre: genre, features: features)
        return Verdict(
            genre: genre,
            confidence: conf,
            makeupMul: makeup,
            hfMul: hf,
            source: source
        )
    }

    /// Build features from the lightweight live analysis stats in LocalAmplifyEngine.
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
        // Bandwidth proxy from HF energy
        let bw: Float = highRatio > 0.7 ? 14_000 : (highRatio > 0.4 ? 11_000 : 8_000)
        return Features(
            bassRatio: bassProxy * 0.55 + (1 - highRatio) * 0.25,
            brightness: min(1, highRatio * 0.85),
            crestDB: crestDB,
            zcr: zcr,
            dynamicRangeDB: max(4, min(28, crestDB * 1.1)),
            speechLikelihood: speech,
            bandwidthHz: bw,
            midRatio: midProxy
        )
    }

    // MARK: - Private

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

    private static func liveMultipliers(genre: String, features: Features) -> (Float, Float) {
        var makeup: Float = 1.0
        var hf: Float = 1.0
        switch genre {
        case "classical": makeup = 0.94; hf = 1.02
        case "pop": makeup = 1.01; hf = 0.98
        case "electronic": makeup = 1.02; hf = 0.94
        case "hiphop": makeup = 1.03; hf = 0.90
        case "rock": makeup = 1.00; hf = 0.93
        case "jazz": makeup = 0.97; hf = 1.00
        case "speech": makeup = 0.96; hf = 1.0
        case "ambient": makeup = 0.98; hf = 1.03
        case "metal": makeup = 0.99; hf = 0.88
        case "folk": makeup = 0.98; hf = 1.0
        default: break
        }
        if features.brightness > 0.5 { hf *= 0.95 }
        if features.bassRatio > 0.4 { makeup = min(1.05, makeup + 0.01) }
        if features.speechLikelihood > 0.55 {
            makeup = min(makeup, 0.97)
            hf = min(1.02, max(0.95, hf))
        }
        return (max(0.88, min(1.08, makeup)), max(0.80, min(1.05, hf)))
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
