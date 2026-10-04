import Combine
import Foundation

/// Whether the collapsed island should use the Ambient pill silhouette.
///
/// Pill when Ambient mode is on **and** media is actually playing. Off, or
/// nothing playing (including paused / empty), returns the normal closed notch.
enum AmbientMode {
    static func showsPill(ambientEnabled: Bool, isPlaying: Bool) -> Bool {
        ambientEnabled && isPlaying
    }
}

/// Persists the user-facing **Ambient mode** toggle. Default is off so today's
/// collapsed notch (clock / widget ambient) is unchanged until the user opts in.
@MainActor
final class AmbientModeStore: ObservableObject {
    static let shared = AmbientModeStore()
    static let defaultsKey = "dynamo.ambientMode"

    @Published private(set) var isEnabled: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `bool(forKey:)` is false when the key is missing — correct default.
        isEnabled = defaults.bool(forKey: Self.defaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
    }
}
