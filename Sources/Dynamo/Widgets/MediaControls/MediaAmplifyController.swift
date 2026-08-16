import AppKit
import AVFoundation
import Foundation

/// Dolby-like **intent** profiles — reshape how music *hits*, not the volume fader.
///
/// Curves designed by `Tools/DynamoEQ/dynamo_eq.py` (pure local DSP, no network APIs)
/// and applied in real time by `LocalAmplifyEngine` (process tap + multi-band EQ).
enum MediaAmplifyProfile: String, CaseIterable, Identifiable {
    case symphony
    case presence
    case cinema
    case impact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .symphony: return "Symphony"
        case .presence: return "Presence"
        case .cinema: return "Cinema"
        case .impact: return "Impact"
        }
    }

    var subtitle: String {
        switch self {
        case .symphony: return "Adaptive concert-hall path — media + device aware"
        case .presence: return "Dialogue clarity & air — local multi-band EQ"
        case .cinema: return "Loudness contour + soft mid scoop — local EQ"
        case .impact: return "Bass body & punch — local EQ, not the volume fader"
        }
    }

    var systemImage: String {
        switch self {
        case .symphony: return "music.quarternote.3"
        case .presence: return "ear"
        case .cinema: return "film"
        case .impact: return "waveform.path.ecg"
        }
    }

    static func resolved(fromStored raw: String?) -> MediaAmplifyProfile {
        guard let raw else { return .symphony }
        if let p = MediaAmplifyProfile(rawValue: raw) { return p }
        switch raw {
        case "crisp": return .presence
        case "balanced": return .cinema
        case "visceral": return .impact
        default: return .symphony
        }
    }
}

/// Local Amplify controller — **no Music Automation, no cloud APIs**.
///
/// On macOS 14.2+: process-tap capture → DynamoEQ biquads → muted source + EQ’d output.
/// Coefficients from embedded curves (always) or optional `dynamo_eq.py` helper.
@MainActor
final class MediaAmplifyController: ObservableObject {
    static let shared = MediaAmplifyController()

    private static let enabledKey = "dynamo.media.amplify.enabled"
    private static let profileKey = "dynamo.media.amplify.profile"
    private static let deviceKey = "dynamo.media.amplify.device"
    private static let legacySavedVolumeKey = "dynamo.media.amplify.savedVolume"
    private static let legacySavedEQKey = "dynamo.media.amplify.savedEQ"
    private static let legacySavedPresetKey = "dynamo.media.amplify.savedPreset"
    private static let legacyActivePresetKey = "dynamo.media.amplify.activePreset"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                startEngine(reason: "enable")
            } else {
                stopEngine()
            }
        }
    }

    @Published var profile: MediaAmplifyProfile {
        didSet {
            UserDefaults.standard.set(profile.rawValue, forKey: Self.profileKey)
            if isEnabled {
                updateEngineProfile()
            } else {
                statusLine = "Off"
            }
        }
    }

    /// Headphones / wireless / speakers / external — auto-detect from system output name.
    @Published var outputDevice: AmplifyOutputDevice {
        didSet {
            UserDefaults.standard.set(outputDevice.rawValue, forKey: Self.deviceKey)
            if isEnabled {
                updateEngineProfile()
            }
        }
    }

    @Published private(set) var statusLine: String = "Off"
    @Published private(set) var lastError: String?
    @Published private(set) var activePresetName: String?
    @Published private(set) var needsAutomationPermission: Bool = false

    /// Bundle id of the player to tap (Music / Spotify); nil = auto.
    var preferredPlayerBundleID: String?

    private var pollTimer: Timer?

    private init() {
        // Drop legacy Music-EQ / volume-boost state.
        UserDefaults.standard.removeObject(forKey: Self.legacySavedVolumeKey)
        UserDefaults.standard.removeObject(forKey: Self.legacySavedEQKey)
        UserDefaults.standard.removeObject(forKey: Self.legacySavedPresetKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyActivePresetKey)

        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        profile = MediaAmplifyProfile.resolved(
            fromStored: UserDefaults.standard.string(forKey: Self.profileKey)
        )
        if let raw = UserDefaults.standard.string(forKey: Self.deviceKey),
           let d = AmplifyOutputDevice(rawValue: raw) {
            outputDevice = d
        } else {
            outputDevice = .auto
        }
        statusLine = isEnabled ? "\(profile.title) · Symphony EQ" : "Off"
        if isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.startEngine(reason: "launch")
            }
        }
    }

    private var resolvedDevice: AmplifyOutputDevice {
        if outputDevice != .auto { return outputDevice }
        let out = AudioOutputController.shared
        out.refresh()
        let name: String?
        if let sel = out.selectedID {
            name = out.devices.first(where: { $0.id == sel })?.name
        } else {
            name = out.devices.first?.name
        }
        return AmplifyOutputDevice.infer(fromDeviceName: name)
    }

    func reapplyForSource() {
        guard isEnabled else { return }
        startEngine(reason: "source")
    }

    func reapplyForTrack(title: String, artist: String) {
        // Local EQ is continuous — no per-track re-script needed.
        _ = title
        _ = artist
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

    func retryApply() {
        guard isEnabled else { return }
        startEngine(reason: "retry")
    }

    func openAutomationSettings() {
        // Legacy button — local EQ uses Audio capture privacy, not Automation.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Engine

    private func startEngine(reason: String) {
        needsAutomationPermission = false
        lastError = nil

        guard #available(macOS 14.2, *) else {
            statusLine = "\(profile.title) · needs macOS 14.2+"
            lastError = "Local Amplify EQ requires macOS 14.2 or later (process audio tap)."
            activePresetName = nil
            return
        }

        // Request audio capture once (same path as live peek EQ).
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard self.isEnabled else { return }
                guard granted else {
                    self.lastError = "Allow Microphone / audio capture for Dynamo to run Local Amplify EQ."
                    self.statusLine = "\(self.profile.title) · audio access"
                    self.activePresetName = nil
                    return
                }
                let bundle = self.preferredPlayerBundleID
                    ?? Self.guessPlayerBundleID()
                let device = self.resolvedDevice
                LocalAmplifyEngine.shared.start(
                    profile: self.profile,
                    device: device,
                    preferredBundleID: bundle
                )
                self.syncFromEngine()
                self.startPolling()
                #if DEBUG
                print("[MediaAmplify] \(reason) → symphony engine device=\(device.rawValue)")
                #endif
            }
        }
    }

    private static func guessPlayerBundleID() -> String? {
        let apps = NSWorkspace.shared.runningApplications
        if apps.contains(where: { $0.bundleIdentifier == "com.apple.Music" && !$0.isTerminated }) {
            return "com.apple.Music"
        }
        if apps.contains(where: { $0.bundleIdentifier == "com.spotify.client" && !$0.isTerminated }) {
            return "com.spotify.client"
        }
        return nil
    }

    private func updateEngineProfile() {
        guard #available(macOS 14.2, *) else { return }
        LocalAmplifyEngine.shared.setProfile(profile, device: resolvedDevice)
        syncFromEngine()
    }

    private func stopEngine() {
        pollTimer?.invalidate()
        pollTimer = nil
        if #available(macOS 14.2, *) {
            LocalAmplifyEngine.shared.stop()
        }
        statusLine = "Off"
        lastError = nil
        activePresetName = nil
        needsAutomationPermission = false
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncFromEngine() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func syncFromEngine() {
        guard #available(macOS 14.2, *) else { return }
        let engine = LocalAmplifyEngine.shared
        if engine.isRunning {
            statusLine = engine.statusLine
            activePresetName = "Local EQ"
            lastError = engine.lastError
        } else if isEnabled {
            statusLine = engine.statusLine
            lastError = engine.lastError
            activePresetName = nil
        }
    }
}

import AVFoundation
