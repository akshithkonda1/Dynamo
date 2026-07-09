import CoreAudio
import CoreGraphics
import Foundation

/// Reads system output volume and display brightness without privileged entitlements.
enum SystemLevelReader {
    /// Output volume in 0...1, or nil if unavailable.
    static func outputVolume() -> Float? {
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

        // 'vvol' — VirtualMainVolume (not always exported as a Swift constant).
        let virtualMainVolume = AudioObjectPropertySelector(0x7676_6F6C)
        var volume: Float32 = 0
        size = UInt32(MemoryLayout<Float32>.size)
        address = AudioObjectPropertyAddress(
            mSelector: virtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        if volStatus != noErr {
            // Fallback: channel 1 scalar volume.
            address.mSelector = kAudioDevicePropertyVolumeScalar
            address.mElement = 1
            size = UInt32(MemoryLayout<Float32>.size)
            volStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        }
        guard volStatus == noErr else { return nil }
        return min(1, max(0, volume))
    }

    static func isMuted() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else { return false }

        var mute: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &mute) == noErr else {
            return false
        }
        return mute != 0
    }

    /// Main display brightness in 0...1 when readable; nil otherwise.
    static func displayBrightness() -> Float? {
        // Prefer CoreDisplay private symbol when present (no public API).
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

        // Fallback: DisplayServices
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
}
