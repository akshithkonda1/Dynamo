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
    /// Names match Music’s built-in EQ preset list (macOS).
    var musicEQPresetCandidates: [String] {
        switch self {
        case .presence:
            return ["Vocal Booster", "Treble Booster", "Pop", "Jazz"]
        case .cinema:
            // “Loudness” is not always present — prefer built-ins that lift lows/highs.
            return ["R&B", "Electronic", "Dance", "Classical", "Pop", "Flat"]
        case .impact:
            return ["Bass Booster", "Hip-Hop", "Electronic", "Rock", "Dance", "Deep"]
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
/// Never touches system volume. Pipeline:
/// 1. Capture prior Music EQ baseline once per enable session.
/// 2. Apply intent-matched built-in Music EQ preset (with fallbacks).
/// 3. Re-apply on source / track changes so skips stay consistent.
/// 4. Restore baseline on disable.
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
    /// True when last failure looks like missing Automation permission.
    @Published private(set) var needsAutomationPermission: Bool = false

    private var didCaptureBaseline = false
    private var lastAppliedTrackKey: String = ""
    private var cachedPresetNames: [String] = []
    private var lastPresetListAt: Date = .distantPast

    private init() {
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

    /// Retry apply (e.g. after user grants Automation).
    func retryApply() {
        guard isEnabled else { return }
        cachedPresetNames = []
        lastPresetListAt = .distantPast
        apply(reason: "retry")
    }

    func openAutomationSettings() {
        PermissionsStore.shared.openSystemSettings(for: .automationMusic)
    }

    // MARK: - Apply / Restore

    private func apply(reason: String) {
        lastError = nil
        needsAutomationPermission = false
        captureBaselineIfNeeded()

        guard Self.isMusicRunning() else {
            // Launch Music in background so EQ can attach next tick (no UI focus steal if already open).
            activePresetName = nil
            statusLine = "\(profile.title) · open Music for EQ"
            #if DEBUG
            print("[MediaAmplify] \(reason): armed, Music not running")
            #endif
            return
        }

        // Warm Automation: a no-op read often triggers the first TCC prompt.
        _ = Self.pingMusicScripting()

        if let preset = applyMusicEQWithFallbacks(profile.musicEQPresetCandidates) {
            activePresetName = preset
            UserDefaults.standard.set(preset, forKey: Self.activePresetKey)
            statusLine = "\(profile.title) · \(preset)"
            lastError = nil
            needsAutomationPermission = false
            PermissionsStore.shared.recordGranted(.automationMusic)
        } else {
            activePresetName = nil
            statusLine = "\(profile.title) · EQ pending"
            let detail = Self.lastScriptError?.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.looksLikeAutomationDenial(detail) {
                needsAutomationPermission = true
                lastError = "Couldn’t set Music EQ — allow Automation for Music in System Settings"
            } else if let detail, !detail.isEmpty {
                lastError = "Music EQ failed: \(detail)"
            } else {
                needsAutomationPermission = true
                lastError = "Couldn’t set Music EQ — allow Automation for Music in System Settings"
            }
            if needsAutomationPermission {
                PermissionsStore.shared.recordDenied(.automationMusic)
            }
        }

        #if DEBUG
        print("[MediaAmplify] \(reason) → \(statusLine) err=\(lastError ?? "nil")")
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
        needsAutomationPermission = false
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

    /// Lightweight scripting probe — triggers Automation prompt if needed.
    @discardableResult
    private static func pingMusicScripting() -> Bool {
        let source = """
        try
            tell application id "com.apple.Music"
                return (name as text)
            end tell
        on error errMsg number errNum
            return "err:" & errNum & ":" & errMsg
        end try
        """
        guard let out = runAppleScript(source) else { return false }
        if out.hasPrefix("err:") {
            lastScriptError = String(out.dropFirst(4))
            return false
        }
        return true
    }

    private static func readMusicEQState() -> MusicEQState? {
        let source = """
        try
            tell application id "com.apple.Music"
                set e to eq enabled
                set p to ""
                try
                    set p to name of current EQ preset as text
                end try
                return (e as integer as text) & "|" & p
            end tell
        on error errMsg number errNum
            return "err:" & errNum & ":" & errMsg
        end try
        """
        guard let out = runAppleScript(source), !out.isEmpty else { return nil }
        if out.hasPrefix("err:") {
            lastScriptError = String(out.dropFirst(4))
            return nil
        }
        let parts = out.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let enabled = (parts.first.map(String.init) ?? "0") != "0"
        let preset = parts.count > 1 ? String(parts[1]) : ""
        return MusicEQState(enabled: enabled, preset: preset)
    }

    /// Names of EQ presets currently in Music (cached ~30s).
    private func musicEQPresetNames() -> [String] {
        if !cachedPresetNames.isEmpty, Date().timeIntervalSince(lastPresetListAt) < 30 {
            return cachedPresetNames
        }
        let source = """
        try
            tell application id "com.apple.Music"
                set names to {}
                repeat with p in EQ presets
                    set end of names to (name of p as text)
                end repeat
                set AppleScript's text item delimiters to linefeed
                set out to names as text
                set AppleScript's text item delimiters to ""
                return out
            end tell
        on error errMsg number errNum
            return "err:" & errNum & ":" & errMsg
        end try
        """
        guard let out = Self.runAppleScript(source), !out.isEmpty else { return cachedPresetNames }
        if out.hasPrefix("err:") {
            Self.lastScriptError = String(out.dropFirst(4))
            return cachedPresetNames
        }
        let names = out
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !names.isEmpty {
            cachedPresetNames = names
            lastPresetListAt = Date()
        }
        return cachedPresetNames
    }

    /// Resolve a candidate to an actual Music preset name (case-insensitive / fuzzy).
    private func resolvePresetName(_ candidate: String, in available: [String]) -> String? {
        if available.isEmpty { return candidate }
        if let exact = available.first(where: { $0 == candidate }) { return exact }
        if let ci = available.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            return ci
        }
        // Hip-Hop vs Hip Hop, R&B variants, etc.
        let norm = { (s: String) -> String in
            s.lowercased()
                .replacingOccurrences(of: "&", with: "and")
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        let target = norm(candidate)
        return available.first { norm($0) == target }
            ?? available.first { norm($0).contains(target) || target.contains(norm($0)) }
    }

    /// Try each candidate preset; return the one that stuck.
    private func applyMusicEQWithFallbacks(_ candidates: [String]) -> String? {
        let available = musicEQPresetNames()
        var tried: [String] = []
        for name in candidates {
            let resolved = resolvePresetName(name, in: available) ?? name
            if tried.contains(where: { $0.caseInsensitiveCompare(resolved) == .orderedSame }) { continue }
            tried.append(resolved)
            if applyMusicEQ(enabled: true, preset: resolved) {
                if let state = Self.readMusicEQState(), state.enabled {
                    if state.preset.isEmpty { return resolved }
                    if state.preset.localizedCaseInsensitiveContains(resolved)
                        || resolved.localizedCaseInsensitiveContains(state.preset) {
                        return state.preset
                    }
                    // EQ on under a different reported name — still success.
                    return state.preset
                }
                return resolved
            }
        }
        // Last resort: enable EQ without changing preset.
        if applyMusicEQ(enabled: true, preset: nil) {
            return Self.readMusicEQState()?.preset.nilIfEmpty ?? "EQ on"
        }
        return nil
    }

    @discardableResult
    private func applyMusicEQ(enabled: Bool, preset: String?) -> Bool {
        guard Self.isMusicRunning() else { return false }

        let source: String
        if enabled, let preset, !preset.isEmpty {
            let esc = preset.appleScriptEscaped
            // Prefer EQ preset by name; fall back to whose-name matching if direct fails.
            source = """
            try
                tell application id "com.apple.Music"
                    try
                        set current EQ preset to EQ preset "\(esc)"
                    on error
                        try
                            set current EQ preset to (first EQ preset whose name is "\(esc)")
                        end try
                    end try
                    set eq enabled to true
                end tell
                return "ok"
            on error errMsg number errNum
                return "err:" & errNum & ":" & errMsg
            end try
            """
        } else if enabled {
            source = """
            try
                tell application id "com.apple.Music"
                    set eq enabled to true
                end tell
                return "ok"
            on error errMsg number errNum
                return "err:" & errNum & ":" & errMsg
            end try
            """
        } else {
            source = """
            try
                tell application id "com.apple.Music"
                    set eq enabled to false
                end tell
                return "ok"
            on error errMsg number errNum
                return "err:" & errNum & ":" & errMsg
            end try
            """
        }

        // Prefer NSAppleScript; fall back to osascript (sometimes surfaces TCC better).
        if let out = Self.runAppleScript(source) {
            if out.hasPrefix("ok") { return true }
            if out.hasPrefix("err:") {
                Self.lastScriptError = String(out.dropFirst(4))
            }
        }
        if let out = Self.runOsascript(source) {
            if out.hasPrefix("ok") { return true }
            if out.hasPrefix("err:") {
                Self.lastScriptError = String(out.dropFirst(4))
            }
            // osascript may return bare error text
            if !out.hasPrefix("ok") && !out.isEmpty {
                Self.lastScriptError = out
            }
        }
        return false
    }

    /// Last AppleScript / osascript error fragment (process-wide for this controller).
    private static var lastScriptError: String?

    private static func looksLikeAutomationDenial(_ detail: String?) -> Bool {
        guard let d = detail?.lowercased(), !d.isEmpty else { return true }
        if d.contains("not authorized") || d.contains("not allowed") { return true }
        if d.contains("1002") || d.contains("-1743") || d.contains("errae") { return true }
        if d.contains("permission") || d.contains("denied") || d.contains("access") { return true }
        if d.contains("application isn't running") { return false }
        return false
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String
            let num = error[NSAppleScript.errorNumber] as? Int
            if let num, let msg {
                lastScriptError = "\(num):\(msg)"
            } else if let msg {
                lastScriptError = msg
            } else {
                lastScriptError = "\(error)"
            }
            return "err:" + (lastScriptError ?? "unknown")
        }
        return result.stringValue
    }

    /// Shell `osascript` fallback — can prompt Automation more reliably on some macOS builds.
    private static func runOsascript(_ source: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            lastScriptError = error.localizedDescription
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if proc.terminationStatus != 0 {
            lastScriptError = err.isEmpty ? out : err
            return lastScriptError.map { "err:" + $0 }
        }
        return out.isEmpty ? nil : out
    }
}

private extension String {
    var appleScriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    var nilIfEmpty: String? { isEmpty ? nil : self }
}
