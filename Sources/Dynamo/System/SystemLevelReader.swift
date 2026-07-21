import AppKit
import CoreAudio
import CoreGraphics
import Foundation

/// Reads and writes machine state Dynamo surfaces in the notch.
///
/// **Volume:** macOS menu-bar / keyboard volume is **not** the same as a raw
/// Core Audio scalar on every device. AppleScript `get volume settings` /
/// `set volume output volume N` is the same 0…100 scale Control Center shows,
/// so that is the source of truth for UI. Core Audio is used only as a
/// fallback and for change notifications.
///
/// **Brightness:** CoreDisplay / DisplayServices user brightness (0…1).
enum SystemLevelReader {
    private static let virtualMainVolume = AudioObjectPropertySelector(0x7676_6F6C)

    // MARK: - Output device

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func defaultOutputDeviceName() -> String? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfName) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfName else { return nil }
        return cfName as String
    }

    // MARK: - Volume (system UI scale 0…100)

    /// Exact menu-bar output volume 0…100, and mute flag.
    static func systemVolumeSettings() -> (percent: Int, muted: Bool)? {
        // AppleScript matches the volume keys / Control Center percentage.
        let source = """
        set s to get volume settings
        return (output volume of s as integer as text) & "|" & (output muted of s as boolean as text)
        """
        guard let raw = runAppleScript(source)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return coreAudioVolumeSettings()
        }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard let p = Int(parts[0].trimmingCharacters(in: .whitespaces)) else {
            return coreAudioVolumeSettings()
        }
        let muted: Bool
        if parts.count > 1 {
            muted = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("true")
        } else {
            muted = isMuted()
        }
        return (min(100, max(0, p)), muted)
    }

    /// Output volume in 0…1 for sliders (derived from system UI percent).
    static func outputVolume() -> Float? {
        if let settings = systemVolumeSettings() {
            return Float(settings.percent) / 100.0
        }
        return coreAudioVolumeSettings().map { Float($0.percent) / 100.0 }
    }

    /// Set volume to an exact UI percentage 0…100 (what the user sees).
    @discardableResult
    static func setOutputVolumePercent(_ percent: Int) -> Bool {
        let p = min(100, max(0, percent))
        // Unmute when raising above silence.
        let source: String
        if p > 0 {
            source = "set volume output volume \(p) output muted false"
        } else {
            source = "set volume output volume 0"
        }
        if runAppleScript(source) != nil {
            // Also mirror to Core Audio so hardware/listeners stay in sync.
            _ = setCoreAudioVolumeScalar(Float(p) / 100.0)
            return true
        }
        return setCoreAudioVolumeScalar(Float(p) / 100.0)
    }

    /// Set volume from a 0…1 slider value — quantized to whole percents.
    @discardableResult
    static func setOutputVolume(_ value: Float) -> Bool {
        let percent = Int((min(1, max(0, value)) * 100).rounded())
        return setOutputVolumePercent(percent)
    }

    static func isMuted() -> Bool {
        if let settings = systemVolumeSettings() { return settings.muted }
        guard let deviceID = defaultOutputDeviceID() else { return false }
        return isMuted(deviceID: deviceID)
    }

    static func isMuted(deviceID: AudioDeviceID) -> Bool {
        var mute: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &mute) == noErr else {
            return false
        }
        return mute != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool, deviceID: AudioDeviceID? = nil) -> Bool {
        let source = muted
            ? "set volume output muted true"
            : "set volume output muted false"
        if runAppleScript(source) != nil {
            if let deviceID = deviceID ?? defaultOutputDeviceID() {
                var mute: UInt32 = muted ? 1 : 0
                let size = UInt32(MemoryLayout<UInt32>.size)
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyMute,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                )
                _ = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mute)
            }
            return true
        }
        guard let deviceID = deviceID ?? defaultOutputDeviceID() else { return false }
        var mute: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mute) == noErr
    }

    @discardableResult
    static func toggleMute() -> Bool {
        setMuted(!isMuted())
    }

    // MARK: - Core Audio helpers

    private static func coreAudioVolumeSettings() -> (percent: Int, muted: Bool)? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var volume: Float32?
        // Prefer virtual main volume
        if let v = floatProperty(deviceID, selector: virtualMainVolume, element: kAudioObjectPropertyElementMain) {
            volume = v
        } else {
            var samples: [Float32] = []
            for ch: UInt32 in [1, 2] {
                if let v = floatProperty(deviceID, selector: kAudioDevicePropertyVolumeScalar, element: ch) {
                    samples.append(v)
                }
            }
            if !samples.isEmpty {
                volume = samples.reduce(0, +) / Float32(samples.count)
            }
        }
        guard let volume else { return nil }
        let percent = Int((min(1, max(0, volume)) * 100).rounded())
        return (percent, isMuted(deviceID: deviceID))
    }

    private static func floatProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    @discardableResult
    private static func setCoreAudioVolumeScalar(_ value: Float) -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return false }
        let clamped = min(1, max(0, value))
        if clamped > 0.001 {
            _ = setMuted(false, deviceID: deviceID)
        }
        var volume = Float32(clamped)
        var size = UInt32(MemoryLayout<Float32>.size)
        var anyOK = false

        var address = AudioObjectPropertyAddress(
            mSelector: virtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume) == noErr {
            anyOK = true
        }
        address.mSelector = kAudioDevicePropertyVolumeScalar
        for channel: UInt32 in [1, 2] {
            address.mElement = channel
            size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume) == noErr {
                anyOK = true
            }
        }
        return anyOK
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    // MARK: - Brightness

    /// Main display brightness in 0...1 when readable; nil otherwise.
    static func displayBrightness() -> Float? {
        let handle = dlopen("/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
        defer { if let handle { dlclose(handle) } }
        if let handle,
           let sym = dlsym(handle, "CoreDisplay_Display_GetUserBrightness") {
            typealias GetBrightness = @convention(c) (CGDirectDisplayID) -> Double
            let fn = unsafeBitCast(sym, to: GetBrightness.self)
            let value = fn(CGMainDisplayID())
            if value >= 0, value <= 1.5 {
                return Float(min(1, max(0, value)))
            }
        }

        let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        defer { if let ds { dlclose(ds) } }
        if let ds,
           let sym = dlsym(ds, "DisplayServicesGetBrightness") {
            typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
            let fn = unsafeBitCast(sym, to: GetBrightness.self)
            var brightness: Float = 0
            if fn(CGMainDisplayID(), &brightness) == 0 {
                return min(1, max(0, brightness))
            }
        }
        return nil
    }

    /// Brightness as 0…100 for UI labels.
    static func displayBrightnessPercent() -> Int? {
        guard let b = displayBrightness() else { return nil }
        return Int((b * 100).rounded())
    }

    @discardableResult
    static func setDisplayBrightness(_ value: Float) -> Bool {
        let clamped = min(1, max(0, value))
        let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        defer { if let ds { dlclose(ds) } }
        if let ds,
           let sym = dlsym(ds, "DisplayServicesSetBrightness") {
            typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
            let fn = unsafeBitCast(sym, to: SetBrightness.self)
            return fn(CGMainDisplayID(), clamped) == 0
        }
        let handle = dlopen("/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
        defer { if let handle { dlclose(handle) } }
        if let handle,
           let sym = dlsym(handle, "CoreDisplay_Display_SetUserBrightness") {
            typealias SetBrightness = @convention(c) (CGDirectDisplayID, Double) -> Void
            let fn = unsafeBitCast(sym, to: SetBrightness.self)
            fn(CGMainDisplayID(), Double(clamped))
            return true
        }
        return false
    }
}
