import AppKit
import Foundation

/// Amplify profile — louder, crisper, more visceral system + Music EQ.
enum MediaAmplifyProfile: String, CaseIterable, Identifiable {
    case crisp
    case balanced
    case visceral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crisp: return "Crisp"
        case .balanced: return "Balanced"
        case .visceral: return "Visceral"
        }
    }

    var subtitle: String {
        switch self {
        case .crisp: return "Treble clarity + precision"
        case .balanced: return "Loudness + punch"
        case .visceral: return "Max body + impact"
        }
    }

    var systemImage: String {
        switch self {
        case .crisp: return "waveform.path"
        case .balanced: return "hifispeaker.fill"
        case .visceral: return "speaker.wave.3.fill"
        }
    }

    /// Points added to system UI volume (0…100 scale).
    var volumeBoost: Int {
        switch self {
        case .crisp: return 10
        case .balanced: return 16
        case .visceral: return 24
        }
    }

    /// Minimum volume floor while amplify is on.
    var volumeFloor: Int {
        switch self {
        case .crisp: return 55
        case .balanced: return 68
        case .visceral: return 78
        }
    }

    /// Apple Music built-in EQ preset name (when Music is the source).
    var musicEQPreset: String {
        switch self {
        case .crisp: return "Treble Booster"
        case .balanced: return "Loudness"
        case .visceral: return "Rock"
        }
    }
}

/// Makes playback feel louder, crisper, and more physical without a virtual audio driver.
///
/// Strategy (production-safe, on-device):
/// 1. Unmute + boost system output volume toward a profile floor/boost.
/// 2. When Music is active, enable a built-in EQ preset matched to the profile.
/// 3. Persist restore-state so toggling off returns the user’s prior volume/EQ.
@MainActor
final class MediaAmplifyController: ObservableObject {
    static let shared = MediaAmplifyController()

    private static let enabledKey = "dynamo.media.amplify.enabled"
    private static let profileKey = "dynamo.media.amplify.profile"
    private static let savedVolumeKey = "dynamo.media.amplify.savedVolume"
    private static let savedEQKey = "dynamo.media.amplify.savedEQ"
    private static let savedPresetKey = "dynamo.media.amplify.savedPreset"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                apply(reason: "enable")
            } else {
                restore()
            }
        }
    }

    @Published var profile: MediaAmplifyProfile {
        didSet {
            UserDefaults.standard.set(profile.rawValue, forKey: Self.profileKey)
            if isEnabled {
                apply(reason: "profile")
            }
        }
    }

    @Published private(set) var statusLine: String = "Off"
    @Published private(set) var lastError: String?

    private var didCaptureBaseline = false

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if let raw = UserDefaults.standard.string(forKey: Self.profileKey),
           let p = MediaAmplifyProfile(rawValue: raw) {
            profile = p
        } else {
            profile = .visceral
        }
        statusLine = isEnabled ? "\(profile.title) on" : "Off"
        // Re-apply after launch if user left Amplify on.
        if isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.apply(reason: "launch")
            }
        }
    }

    /// Call when now-playing source changes so Music EQ can re-attach.
    func reapplyForSource() {
        guard isEnabled else { return }
        apply(reason: "source")
    }

    func toggle() {
        isEnabled.toggle()
    }

    // MARK: - Apply / Restore

    private func apply(reason: String) {
        lastError = nil
        captureBaselineIfNeeded()

        let volume = SystemVolumeController.shared
        volume.start()
        volume.refreshFromSystem(announceExternal: false)

        if volume.isMuted {
            volume.setMuted(false)
        }

        let current = volume.percent
        let boosted = min(100, max(profile.volumeFloor, current + profile.volumeBoost))
        if boosted > current {
            volume.setPercent(boosted)
        } else if current < profile.volumeFloor {
            volume.setPercent(profile.volumeFloor)
        }

        // Music EQ for crisp/visceral coloration when Apple Music is driving.
        applyMusicEQ(enabled: true, preset: profile.musicEQPreset)

        statusLine = "\(profile.title) · \(volume.percent)%"
        #if DEBUG
        print("[MediaAmplify] apply \(reason) → \(statusLine)")
        #endif
    }

    private func restore() {
        let volume = SystemVolumeController.shared
        volume.start()

        if let saved = UserDefaults.standard.object(forKey: Self.savedVolumeKey) as? Int {
            volume.setPercent(min(100, max(0, saved)))
        }

        let eqWasOn = UserDefaults.standard.object(forKey: Self.savedEQKey) as? Bool
        let preset = UserDefaults.standard.string(forKey: Self.savedPresetKey)
        if let eqWasOn {
            if eqWasOn, let preset, !preset.isEmpty {
                applyMusicEQ(enabled: true, preset: preset)
            } else {
                applyMusicEQ(enabled: false, preset: nil)
            }
        }

        clearBaseline()
        statusLine = "Off"
    }

    private func captureBaselineIfNeeded() {
        guard !didCaptureBaseline else { return }
        let volume = SystemVolumeController.shared
        volume.start()
        volume.refreshFromSystem(announceExternal: false)
        UserDefaults.standard.set(volume.percent, forKey: Self.savedVolumeKey)

        // Snapshot Music EQ if available.
        if let state = Self.readMusicEQState() {
            UserDefaults.standard.set(state.enabled, forKey: Self.savedEQKey)
            UserDefaults.standard.set(state.preset, forKey: Self.savedPresetKey)
        }
        didCaptureBaseline = true
    }

    private func clearBaseline() {
        didCaptureBaseline = false
        UserDefaults.standard.removeObject(forKey: Self.savedVolumeKey)
        UserDefaults.standard.removeObject(forKey: Self.savedEQKey)
        UserDefaults.standard.removeObject(forKey: Self.savedPresetKey)
    }

    // MARK: - Music EQ (AppleScript)

    private struct MusicEQState {
        var enabled: Bool
        var preset: String
    }

    private static func readMusicEQState() -> MusicEQState? {
        let source = """
        try
            tell application "Music"
                if player state is stopped then return "0|"
                set e to eq enabled
                set p to ""
                try
                    set p to name of current EQ preset
                end try
                return (e as integer as text) & "|" & p
            end tell
        on error
            return ""
        end try
        """
        guard let out = runAppleScript(source), !out.isEmpty else { return nil }
        let parts = out.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let enabled = (parts.first.map(String.init) ?? "0") != "0"
        let preset = parts.count > 1 ? String(parts[1]) : ""
        return MusicEQState(enabled: enabled, preset: preset)
    }

    private func applyMusicEQ(enabled: Bool, preset: String?) {
        // Only touch Music if it’s running — avoid launching Music just for EQ.
        let musicRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Music" && !$0.isTerminated
        }
        guard musicRunning else { return }

        let presetLine: String
        if enabled, let preset, !preset.isEmpty {
            // Prefer named preset; fall back to enabling EQ if preset missing.
            presetLine = """
            try
                set current EQ preset to EQ preset "\(preset.appleScriptEscaped)"
            end try
            set eq enabled to true
            """
        } else if enabled {
            presetLine = "set eq enabled to true"
        } else {
            presetLine = "set eq enabled to false"
        }

        let source = """
        try
            tell application "Music"
                \(presetLine)
            end tell
        end try
        """
        _ = Self.runAppleScript(source)
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }
}

private extension String {
    var appleScriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
