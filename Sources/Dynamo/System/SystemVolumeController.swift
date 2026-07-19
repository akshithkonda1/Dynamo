import CoreAudio
import Foundation

/// Live system output volume: reads machine state continuously and can set
/// volume / mute from Dynamo. Drives the notch HUD and Media volume slider.
@MainActor
final class SystemVolumeController: ObservableObject {
    static let shared = SystemVolumeController()

    @Published private(set) var level: Float = 0
    @Published private(set) var isMuted: Bool = false
    @Published private(set) var deviceName: String?

    /// Fired when volume/mute changes from outside Dynamo (keys, Control Center).
    var onExternalChange: (() -> Void)?

    private var started = false
    private var listeningDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var suppressExternalUntil: Date?
    private var pollTimer: Timer?

    private init() {
        refreshFromSystem()
    }

    func start() {
        guard !started else { return }
        started = true
        refreshFromSystem()
        installHardwareListener()
        rebindDeviceListeners()
        // Fallback poll if a device doesn't deliver volume property notifications.
        let t = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFromSystem(announceExternal: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func stop() {
        started = false
        pollTimer?.invalidate()
        pollTimer = nil
        removeDeviceListeners()
        removeHardwareListener()
    }

    // MARK: - Control

    func setLevel(_ value: Float) {
        suppressExternalUntil = Date().addingTimeInterval(0.35)
        let clamped = min(1, max(0, value))
        _ = SystemLevelReader.setOutputVolume(clamped)
        level = SystemLevelReader.outputVolume() ?? clamped
        isMuted = SystemLevelReader.isMuted()
    }

    func setMuted(_ muted: Bool) {
        suppressExternalUntil = Date().addingTimeInterval(0.35)
        _ = SystemLevelReader.setMuted(muted)
        isMuted = SystemLevelReader.isMuted()
        level = SystemLevelReader.outputVolume() ?? level
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func nudge(by delta: Float) {
        setLevel(level + delta)
    }

    // MARK: - Refresh

    func refreshFromSystem(announceExternal: Bool = false) {
        let newLevel = SystemLevelReader.outputVolume() ?? level
        let newMuted = SystemLevelReader.isMuted()
        let newName = SystemLevelReader.defaultOutputDeviceName()
        let changed = abs(newLevel - level) > 0.004 || newMuted != isMuted || newName != deviceName
        level = newLevel
        isMuted = newMuted
        deviceName = newName

        guard announceExternal, changed else { return }
        if let until = suppressExternalUntil, Date() < until { return }
        onExternalChange?()
    }

    // MARK: - Core Audio listeners

    private var hardwareListenerBlock: AudioObjectPropertyListenerBlock?
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?

    private func installHardwareListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.rebindDeviceListeners()
                self?.refreshFromSystem(announceExternal: true)
            }
        }
        hardwareListenerBlock = block
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    private func removeHardwareListener() {
        guard let block = hardwareListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        hardwareListenerBlock = nil
    }

    private func rebindDeviceListeners() {
        removeDeviceListeners()
        guard let deviceID = SystemLevelReader.defaultOutputDeviceID() else { return }
        listeningDeviceID = deviceID

        let volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshFromSystem(announceExternal: true) }
        }
        let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshFromSystem(announceExternal: true) }
        }
        volumeListenerBlock = volumeBlock
        muteListenerBlock = muteBlock

        // Virtual main volume
        var vvol = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(0x7676_6F6C),
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &vvol, DispatchQueue.main, volumeBlock)

        // Channel-1 scalar (fallback devices)
        var scalar = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 1
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &scalar, DispatchQueue.main, volumeBlock)

        var mute = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &mute, DispatchQueue.main, muteBlock)
    }

    private func removeDeviceListeners() {
        guard listeningDeviceID != kAudioObjectUnknown else { return }
        let deviceID = listeningDeviceID
        if let block = volumeListenerBlock {
            var vvol = AudioObjectPropertyAddress(
                mSelector: AudioObjectPropertySelector(0x7676_6F6C),
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &vvol, DispatchQueue.main, block)
            var scalar = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: 1
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &scalar, DispatchQueue.main, block)
        }
        if let block = muteListenerBlock {
            var mute = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &mute, DispatchQueue.main, block)
        }
        volumeListenerBlock = nil
        muteListenerBlock = nil
        listeningDeviceID = kAudioObjectUnknown
    }
}
