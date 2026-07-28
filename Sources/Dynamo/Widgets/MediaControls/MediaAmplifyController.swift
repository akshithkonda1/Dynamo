import AppKit
import Foundation

/// Amplify profile — perceived punch via **tone / EQ only** (never system volume).
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
        case .crisp: return "Treble clarity — no volume change"
        case .balanced: return "Loudness curve — no volume change"
        case .visceral: return "Body & impact — no volume change"
        }
    }

    var systemImage: String {
        switch self {
        case .crisp: return "waveform.path"
        case .balanced: return "hifispeaker.fill"
        case .visceral: return "speaker.wave.3.fill"
        }
    }

    /// Apple Music built-in EQ preset (shapes tone without moving the volume keys).
    var musicEQPreset: String {
        switch self {
        case .crisp: return "Treble Booster"
        case .balanced: return "Loudness"
        case .visceral: return "Rock"
        }
    }
}

/// Makes playback feel fuller / crisper **without raising system volume**.
///
/// Strategy (on-device, no DSP driver):
/// 1. Never call `SystemVolumeController` setPercent / mute for Amplify.
/// 2. When **Music** is running, enable a built-in EQ preset for the profile
///    (Loudness / Treble Booster / Rock) — perceived impact without UI volume.
/// 3. Restore the previous Music EQ state on disable.
/// 4. Spotify / other players have no scriptable EQ; Amplify stays “armed” and
///    re-applies as soon as Music is active.
@MainActor
final class MediaAmplifyController: ObservableObject {
    static let shared = MediaAmplifyController()

    private static let enabledKey = "dynamo.media.amplify.enabled"
    private static let profileKey = "dynamo.media.amplify.profile"
    private static let savedEQKey = "dynamo.media.amplify.savedEQ"
    private static let savedPresetKey = "dynamo.media.amplify.savedPreset"
    /// Legacy key from volume-boost Amplify — cleared so we never re-apply old volume.
    private static let legacySavedVolumeKey = "dynamo.media.amplify.savedVolume"

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
        // Drop any leftover volume baseline from older Amplify builds.
        UserDefaults.standard.removeObject(forKey: Self.legacySavedVolumeKey)

        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if let raw = UserDefaults.standard.string(forKey: Self.profileKey),
           let p = MediaAmplifyProfile(rawValue: raw) {
            profile = p
        } else {
            profile = .visceral
        }
        statusLine = isEnabled ? "\(profile.title) · EQ" : "Off"
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

        let musicRunning = Self.isMusicRunning()
        if musicRunning {
            let ok = applyMusicEQ(enabled: true, preset: profile.musicEQPreset)
            if ok {
                statusLine = "\(profile.title) · EQ"
                lastError = nil
            } else {
                statusLine = "\(profile.title) · EQ pending"
                lastError = "Couldn’t set Music EQ — open Music once"
            }
        } else {
            // Armed without touching volume; EQ applies when Music is the player.
            statusLine = "\(profile.title) · open Music for EQ"
            lastError = nil
        }

        #if DEBUG
        print("[MediaAmplify] apply \(reason) → \(statusLine) (volume untouched)")
        #endif
    }

    private func restore() {
        let eqWasOn = UserDefaults.standard.object(forKey: Self.savedEQKey) as? Bool
        let preset = UserDefaults.standard.string(forKey: Self.savedPresetKey)
        if Self.isMusicRunning(), let eqWasOn {
            if eqWasOn, let preset, !preset.isEmpty {
                _ = applyMusicEQ(enabled: true, preset: preset)
            } else {
                _ = applyMusicEQ(enabled: false, preset: nil)
            }
        }

        clearBaseline()
        statusLine = "Off"
        lastError = nil
    }

    private func captureBaselineIfNeeded() {
        guard !didCaptureBaseline else { return }
        if let state = Self.readMusicEQState() {
            UserDefaults.standard.set(state.enabled, forKey: Self.savedEQKey)
            UserDefaults.standard.set(state.preset, forKey: Self.savedPresetKey)
        }
        didCaptureBaseline = true
    }

    private func clearBaseline() {
        didCaptureBaseline = false
        UserDefaults.standard.removeObject(forKey: Self.savedEQKey)
        UserDefaults.standard.removeObject(forKey: Self.savedPresetKey)
        UserDefaults.standard.removeObject(forKey: Self.legacySavedVolumeKey)
    }

    // MARK: - Music EQ (AppleScript only — no volume)

    private struct MusicEQState {
        var enabled: Bool
        var preset: String
    }

    private static func isMusicRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Music" && !$0.isTerminated
        }
    }

    private static func readMusicEQState() -> MusicEQState? {
        let source = """
        try
            tell application "Music"
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

    @discardableResult
    private func applyMusicEQ(enabled: Bool, preset: String?) -> Bool {
        guard Self.isMusicRunning() else { return false }

        let presetLine: String
        if enabled, let preset, !preset.isEmpty {
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
            return "ok"
        on error errMsg
            return "err:" & errMsg
        end try
        """
        guard let out = Self.runAppleScript(source) else { return false }
        return out.hasPrefix("ok")
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
