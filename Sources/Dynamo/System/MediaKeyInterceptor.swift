import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import Foundation

/// Intercepts volume / mute / brightness keys at the HID level so macOS never
/// sees them — and therefore never draws its own OSD. Dynamo applies the
/// change and shows the notch Peek HUD instead.
///
/// Requires Accessibility (TCC). Without it, `start()` returns false and the
/// caller should fall back to observe-only + `OSDUIHelper` kill.
///
/// Pattern matches volumeHUD / SlimHUD: `CGEvent.tapCreate` at
/// `cghidEventTap` with `.defaultTap` so events can be consumed (`return nil`).
@MainActor
final class MediaKeyInterceptor {
    private enum NXKeyType: Int {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
    }

    /// Called after a successful intercepted volume/mute change.
    var onVolumeHUD: ((Float, Bool) -> Void)?
    /// Called after a successful intercepted brightness change.
    var onBrightnessHUD: ((Float) -> Void)?

    /// Touched from the CGEvent tap callback (non-MainActor) — marked unsafe
    /// the same way volumeHUD does for its interception flags.
    nonisolated(unsafe) private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRunning = false
    nonisolated(unsafe) private var volumeOK = true
    nonisolated(unsafe) private var brightnessOK = true

    private let standardStep: Float = 1.0 / 16.0
    private let fineStep: Float = 1.0 / 64.0

    private static let eventTapCallback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
        guard let userInfo else {
            return Unmanaged.passRetained(cgEvent)
        }
        let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = interceptor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(cgEvent)
        }

        // NX_SYSDEFINED = 14
        guard type.rawValue == 14 else {
            return Unmanaged.passRetained(cgEvent)
        }
        return interceptor.handleEvent(cgEvent)
    }

    /// Whether Accessibility is currently granted (no prompt).
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt once for Accessibility if needed. Returns current trust state.
    @discardableResult
    static func requestAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    var isActive: Bool { isRunning }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard Self.isAccessibilityTrusted else { return false }

        volumeOK = true
        brightnessOK = true

        let mask: CGEventMask = 1 << 14
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        isRunning = false
    }

    // MARK: - Event handling

    private nonisolated func handleEvent(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        guard
            let nsEvent = NSEvent(cgEvent: cgEvent),
            nsEvent.type == .systemDefined,
            nsEvent.subtype.rawValue == 8
        else {
            return Unmanaged.passRetained(cgEvent)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0x0000_FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        // 0xA = key down — ignore key-up so we don't double-step.
        guard keyState == 0xA else {
            // Still consume key-up for keys we own so the system doesn't act on it.
            if let keyType = NXKeyType(rawValue: keyCode) {
                switch keyType {
                case .soundUp, .soundDown, .mute:
                    return volumeOK ? nil : Unmanaged.passRetained(cgEvent)
                case .brightnessUp, .brightnessDown:
                    return brightnessOK ? nil : Unmanaged.passRetained(cgEvent)
                }
            }
            return Unmanaged.passRetained(cgEvent)
        }

        guard let keyType = NXKeyType(rawValue: keyCode) else {
            return Unmanaged.passRetained(cgEvent)
        }

        let flags = nsEvent.modifierFlags.union(NSEvent.ModifierFlags(rawValue: UInt(cgEvent.flags.rawValue)))
        let useFine = flags.contains(.option) && flags.contains(.shift)

        switch keyType {
        case .soundUp, .soundDown, .mute:
            guard volumeOK else { return Unmanaged.passRetained(cgEvent) }
            Task { @MainActor [weak self] in
                self?.handleVolume(keyType, fine: useFine)
            }
            return nil

        case .brightnessUp, .brightnessDown:
            guard brightnessOK else { return Unmanaged.passRetained(cgEvent) }
            Task { @MainActor [weak self] in
                self?.handleBrightness(keyType, fine: useFine)
            }
            return nil
        }
    }

    // MARK: - Volume (Core Audio — same scale as keyboard)

    private func handleVolume(_ key: NXKeyType, fine: Bool) {
        let step = fine ? fineStep : standardStep
        switch key {
        case .soundUp:
            adjustVolume(delta: step)
        case .soundDown:
            adjustVolume(delta: -step)
        case .mute:
            toggleMute()
        default:
            break
        }
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
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

    private func readVolume(_ deviceID: AudioDeviceID) -> Float? {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(0x7676_6F6C), // 'vvol'
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr else {
            return nil
        }
        return Float(volume)
    }

    @discardableResult
    private func writeVolume(_ volume: Float, deviceID: AudioDeviceID) -> Float? {
        var value = Float32(min(1, max(0, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(0x7676_6F6C),
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr else {
            return nil
        }
        return readVolume(deviceID)
    }

    private func readMute(_ deviceID: AudioDeviceID) -> Bool? {
        var mute: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &mute) == noErr else {
            return nil
        }
        return mute != 0
    }

    @discardableResult
    private func writeMute(_ muted: Bool, deviceID: AudioDeviceID) -> Bool {
        var mute: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mute) == noErr
    }

    private func adjustVolume(delta: Float) {
        guard let deviceID = defaultOutputDevice(),
              let current = readVolume(deviceID)
        else {
            volumeOK = false
            return
        }

        let steps = 1.0 / abs(delta)
        var target = current + delta
        target = (target * steps).rounded() / steps
        target = min(1, max(0, target))
        let atBoundary = (current <= 0.001 && delta < 0) || (current >= 0.999 && delta > 0)

        if let muted = readMute(deviceID), muted, target > 0.001 {
            _ = writeMute(false, deviceID: deviceID)
        }

        guard let actual = writeVolume(target, deviceID: deviceID) else {
            volumeOK = false
            return
        }

        if target <= 0.001 {
            _ = writeMute(true, deviceID: deviceID)
        }

        if !atBoundary, abs(actual - current) < 0.001, abs(target - actual) > 0.001 {
            // Hardware quantized plateau — keep intercepting; still show HUD.
        }

        let muted = readMute(deviceID) ?? (target <= 0.001)
        // Keep SystemVolumeController in sync without announcing as external.
        SystemVolumeController.shared.suppressExternalAnnouncements(for: 0.55)
        SystemVolumeController.shared.refreshFromSystem(announceExternal: false)
        onVolumeHUD?(target, muted)
    }

    private func toggleMute() {
        guard let deviceID = defaultOutputDevice(),
              let muted = readMute(deviceID),
              let volume = readVolume(deviceID)
        else {
            volumeOK = false
            return
        }
        guard writeMute(!muted, deviceID: deviceID) else {
            volumeOK = false
            return
        }
        SystemVolumeController.shared.suppressExternalAnnouncements(for: 0.55)
        SystemVolumeController.shared.refreshFromSystem(announceExternal: false)
        onVolumeHUD?(volume, !muted)
    }

    // MARK: - Brightness

    private func handleBrightness(_ key: NXKeyType, fine: Bool) {
        let step = fine ? fineStep : standardStep
        guard let current = SystemLevelReader.displayBrightness() else {
            brightnessOK = false
            return
        }
        let delta: Float = key == .brightnessUp ? step : -step
        let steps = 1.0 / abs(delta)
        var target = current + delta
        target = (target * steps).rounded() / steps
        target = min(1, max(0, target))
        let atBoundary = (current <= 0.001 && delta < 0) || (current >= 0.999 && delta > 0)

        guard SystemLevelReader.setDisplayBrightness(target) else {
            brightnessOK = false
            return
        }
        let actual = SystemLevelReader.displayBrightness() ?? target
        if !atBoundary, abs(actual - current) < 0.001 {
            brightnessOK = false
        }
        onBrightnessHUD?(actual)
    }
}
