import Foundation

/// On-device fidelity ensemble for Dynamic Symphony.
///
/// Six small models read the live spectrum and each do one job: open notes,
/// pull mud, tame harshness, restore weight, add air only when the mix is dark,
/// and focus voices. Nothing is sent off the machine.
enum FidelityModelEnsemble {

    struct Result {
        /// Band dB offsets, already clamped.
        var bias: [String: Float]
        /// Name of the model that moved the curve the most.
        var lead: String
    }

    /// Feature order matches `AmplifyToneAI.Features.vector()`.
    private struct Model {
        var name: String
        var weights: [Float]
        var bands: [String: Float]
    }

    private static let models: [Model] = [
        Model(
            name: "Clarity",
            // Opens a vocal pocket when mids are thin and the top is not already hot.
            weights: [0.15, -1.45, 0.25, -0.35, 0.35, 0.45, -0.15, -1.7, 0.55],
            bands: ["presence": 0.95, "warmth": 0.22, "mud": -0.35, "sheen": 0.12]
        ),
        Model(
            name: "De-mud",
            // Cuts low-mid congestion when bass and mids pile up.
            weights: [1.85, -0.15, -0.2, -0.45, -0.15, -0.25, 0.0, 1.65, -1.15],
            bands: ["mud": -1.15, "body": -0.32, "presence": 0.28, "sub": -0.15]
        ),
        Model(
            name: "De-harsh",
            // Tames sheen and hiss when the top is bright and busy.
            weights: [-0.2, 2.05, -0.1, 1.15, -0.25, 0.25, 0.55, 0.1, -1.35],
            bands: ["sheen": -0.95, "brilliance": -0.55, "air": -0.4, "presence": 0.18]
        ),
        Model(
            name: "Weight",
            // Puts punch back when the low end is missing. Stays quiet when bass is already full.
            weights: [-2.05, 0.05, 0.2, 0.0, 0.25, -0.2, 0.0, -0.15, 0.72],
            bands: ["sub": 0.7, "punch": 0.55, "body": 0.2]
        ),
        Model(
            name: "Air",
            // Opens the top only on a dark, dynamic mix. Suppressed when the track is already bright.
            weights: [0.0, -1.9, 0.85, -0.55, 0.95, -0.85, -0.35, 0.1, 0.15],
            bands: ["air": 0.55, "sheen": 0.28, "brilliance": 0.12]
        ),
        Model(
            name: "Focus",
            // Voice and speech: intelligibility up, sub and mud down.
            weights: [-0.35, 0.15, -0.15, 0.75, 0.0, 2.25, 0.15, 0.35, -0.95],
            bands: ["presence": 1.05, "sub": -0.7, "mud": -0.55, "punch": -0.2, "air": 0.15]
        )
    ]

    static func evaluate(features: AmplifyToneAI.Features) -> Result {
        let vector = features.vector()
        var bias: [String: Float] = [:]
        var bestName = "Clarity"
        var bestDrive: Float = 0
        for model in models {
            let drive = activation(dot(model.weights, vector))
            guard drive > 0.12 else { continue }
            if drive > bestDrive {
                bestDrive = drive
                bestName = model.name
            }
            for (band, gain) in model.bands {
                bias[band, default: 0] += gain * drive
            }
        }
        // Fidelity cap: cuts may go a little deeper than boosts.
        for key in bias.keys {
            let value = bias[key] ?? 0
            if value > 0 {
                bias[key] = min(1.15, value)
            } else {
                bias[key] = max(-1.45, value)
            }
        }
        return Result(bias: bias, lead: bestName)
    }

    private static func dot(_ weights: [Float], _ vector: [Float]) -> Float {
        let n = min(weights.count, vector.count)
        var sum: Float = 0
        for i in 0..<n { sum += weights[i] * vector[i] }
        return sum
    }

    /// Squash to 0…1. Negative evidence means the model stays out of the way.
    private static func activation(_ x: Float) -> Float {
        let y = tanh(x)
        return y > 0 ? y : 0
    }
}
