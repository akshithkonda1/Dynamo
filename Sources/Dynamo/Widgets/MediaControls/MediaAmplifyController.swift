import AppKit
import Foundation

/// Dolby-like **intent** profiles — reshape how music *hits*, not the volume fader.
///
/// Maps to perceptual stages similar to consumer Dolby “enhancement” modes:
/// presence (dialogue/air), cinema (perceived loudness contour), impact (body/bass).
/// Implementation is EQ-only on Apple Music (no system volume, no virtual driver).
enum MediaAmplifyProfile: String, CaseIterable, Identifiable {
    /// Dialogue / air / vocal presence (clarity without louder fader).
    case presence
    /// Cinema-style perceived loudness contour (lows + highs; soft mid scoop).
    case cinema
    /// Bass weight + physical impact (energy without maxing volume keys).
    case impact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .presence: return "Presence"
        case .cinema: return "Cinema"
        case .impact: return "Impact"
        }
    }

    var subtitle: String {
        switch self {
        case .presence: return "Dialogue clarity & air — Dolby-like presence"
        case .cinema: return "Perceived loudness contour — not the volume keys"
        case .impact: return "Bass body & punch — dynamics feel, not fader"
        }
    }

    var systemImage: String {
        switch self {
        case .presence: return "ear"
        case .cinema: return "film"
        case .impact: return "waveform.path.ecg"
        }
    }

    /// Preferred Music EQ presets in order (first available wins).
    /// Built-in names only — no custom band API on Music.
    var musicEQPresetCandidates: [String] {
        switch self {
        case .presence:
            // Vocal/dialogue forward + treble air (clarity stage).
            return ["Vocal Booster", "Treble Booster", "Pop"]
        case .cinema:
            // Equal-loudness style contour — classic “feels louder” without gain.
            return ["Loudness", "Classical", "Flat"]
        case .impact:
            // Low-end weight + energy — physical “hit.”
            return ["Bass Booster", "Electronic", "Rock", "Hip-Hop"]
        }
    }

    /// Migrate pre-Dolby profile raw values.
    static func resolved(fromStored raw: String?) -> MediaAmplifyProfile {
        guard let raw else { return .cinema }
        if let p = MediaAmplifyProfile(rawValue: raw) { return p }
        switch raw {
        case "crisp": return .presence
        case "balanced": return .cinema
        case "visceral": return .impact
        default: return .cinema
        }
    }
}

/// Dolby-inspired Amplify: **tone + perceived impact via EQ only**.
///
/// Never touches system volume. Pipeline concept:
/// 1. Capture prior Music EQ baseline once per enable session.
/// 2. Apply intent-matched built-in Music EQ preset (with fallbacks).
/// 3. Re-apply on source / track changes so skips stay consistent.
/// 4. Restore baseline on disable.
///
/// Spotify and other apps have no scriptable EQ — Amplify stays armed and
/// re-applies when Music is available. True multiband dynamics would need a
/// virtual audio device; this is the honest on-device path without drivers.
@MainActor
final class MediaAmplifyController: ObservableObject {
    static let shared = MediaAmplifyController()

    private static let enabledKey = "dynamo.media.amplify.enabled"
    private static let profileKey = "dynamo.media.amplify.profile"
    private static let savedEQKey = "dynamo.media.amplify.savedEQ"
    private static let savedPresetKey = "dynamo.media.amplify.savedPreset"
    private static let legacySavedVolumeKey = "dynamo.media.amplify.savedVolume"
    private static let activePresetKey = "dynamo.media.amplify.activePreset"

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
    @Published private(set) var activePresetName: String?

    private var didCaptureBaseline = false
    private var lastAppliedTrackKey: String = ""

    private init() {
        // Never re-apply old volume-boost state.
        UserDefaults.standard.removeObject(forKey: Self.legacySavedVolumeKey)

        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        profile = MediaAmplifyProfile.resolved(
            fromStored: UserDefaults.standard.string(forKey: Self.profileKey)
        )
        activePresetName = UserDefaults.standard.string(forKey: Self.activePresetKey)
        statusLine = isEnabled ? statusForEnabled() : "Off"
        if isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.apply(reason: "launch")
            }
        }
    }

    /// Source app changed (Music ↔ Spotify).
    func reapplyForSource() {
        guard isEnabled else { return }
        lastAppliedTrackKey = ""
        apply(reason: "source")
    }

    /// Track changed — re-assert EQ so skips don’t drop the contour.
    func reapplyForTrack(title: String, artist: String) {
        guard isEnabled else { return }
        let key = "\(title)\u{1}\(artist)"
        guard key != lastAppliedTrackKey else { return }
        lastAppliedTrackKey = key
        apply(reason: "track")
    }

    func toggle() {
        isEnabled.toggle()
    }

    func cycleProfile() {
        let all = MediaAmplifyProfile.allCases
        guard let idx = all.firstIndex(of: profile) else {
            profile = .cinema
            return
        }
        profile = all[(idx + 1) % all.count]
    }

    // MARK: - Apply / Restore

    private func apply(reason: String) {
        lastError = nil
        captureBaselineIfNeeded()

        guard Self.isMusicRunning() else {
            activePresetName = nil
            statusLine = "\(profile.title) · open Music for EQ"
            #if DEBUG
            print("[MediaAmplify] \(reason): armed, Music not running")
            #endif
            return
        }

        if let preset = applyMusicEQWithFallbacks(profile.musicEQPresetCandidates) {
            activePresetName = preset
            UserDefaults.standard.set(preset, forKey: Self.activePresetKey)
            statusLine = "\(profile.title) · \(preset)"
            lastError = nil
        } else {
            activePresetName = nil
            statusLine = "\(profile.title) · EQ pending"
            lastError = "Couldn’t set Music EQ — allow Automation for Music"
        }

        #if DEBUG
        print("[MediaAmplify] \(reason) → \(statusLine) (volume untouched)")
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
        activePresetName = nil
        lastAppliedTrackKey = ""
        statusLine = "Off"
        lastError = nil
    }

    private func statusForEnabled() -> String {
        if let activePresetName {
            return "\(profile.title) · \(activePresetName)"
        }
        return "\(profile.title) · EQ"
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
        UserDefaults.standard.removeObject(forKey: Self.activePresetKey)
    }

    // MARK: - Music EQ

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

    /// Try each candidate preset; return the one that stuck (or first that returned ok).
    private func applyMusicEQWithFallbacks(_ candidates: [String]) -> String? {
        for name in candidates {
            if applyMusicEQ(enabled: true, preset: name) {
                // Verify when possible.
                if let state = Self.readMusicEQState(), state.enabled {
                    if state.preset.isEmpty || state.preset.localizedCaseInsensitiveContains(name)
                        || name.localizedCaseInsensitiveContains(state.preset) {
                        return state.preset.isEmpty ? name : state.preset
                    }
                    // EQ on but different name reported — still count as success.
                    if !state.preset.isEmpty { return state.preset }
                }
                return name
            }
        }
        // Last resort: enable EQ without preset change.
        if applyMusicEQ(enabled: true, preset: nil) {
            return Self.readMusicEQState()?.preset.nilIfEmpty ?? "EQ on"
        }
        return nil
    }

    @discardableResult
    private func applyMusicEQ(enabled: Bool, preset: String?) -> Bool {
        guard Self.isMusicRunning() else { return false }

        let presetLine: String
        if enabled, let preset, !preset.isEmpty {
            presetLine = """
            try
                set current EQ preset to EQ preset "\(preset.appleScriptEscaped)"
                set eq enabled to true
            on error
                set eq enabled to true
            end try
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

    var nilIfEmpty: String? { isEmpty ? nil : self }
}
