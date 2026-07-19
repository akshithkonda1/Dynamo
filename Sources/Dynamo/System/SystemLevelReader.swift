import CoreAudio
import CoreGraphics
import Foundation

/// Reads and writes system output volume / mute and display brightness.
/// Uses public Core Audio for volume; private Display frameworks for brightness
/// when available (read-only is enough for the HUD).
enum SystemLevelReader {
    // 'vvol' — VirtualMainVolume (not always exported as a Swift constant).
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

    // MARK: - Volume

    /// Output volume in 0...1 matching the menu-bar / keyboard volume as closely
    /// as Core Audio allows. Tries virtual main volume, then channel scalars.
    static func outputVolume() -> Float? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }

        // 1) Virtual main volume ('vvol') — same scalar the system UI uses on most devices.
        if let v = floatProperty(
            deviceID,
            selector: virtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ) {
            return min(1, max(0, v))
        }

        // 2) Average left/right scalar (or first available channel).
        var samples: [Float] = []
        for channel: UInt32 in [1, 2] {
            if let v = floatProperty(
                deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: channel
            ) {
                samples.append(v)
            }
        }
        if !samples.isEmpty {
            let avg = samples.reduce(0, +) / Float(samples.count)
            return min(1, max(0, avg))
        }

        // 3) Last resort: main-element scalar.
        if let v = floatProperty(
            deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ) {
            return min(1, max(0, v))
        }
        return nil
    }

    private static func floatProperty(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    /// Set system output volume (0...1). Unmutes when setting above silence.
    /// Writes virtual main **and** per-channel scalars so read-back matches.
    @discardableResult
    static func setOutputVolume(_ value: Float) -> Bool {
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

        // Always try channel scalars too — some devices only honor these.
        address.mSelector = kAudioDevicePropertyVolumeScalar
        for channel: UInt32 in [1, 2] {
            address.mElement = channel
            size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume) == noErr {
                anyOK = true
            }
        }

        address.mElement = kAudioObjectPropertyElementMain
        size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume) == noErr {
            anyOK = true
        }

        return anyOK
    }

    static func isMuted() -> Bool {
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
