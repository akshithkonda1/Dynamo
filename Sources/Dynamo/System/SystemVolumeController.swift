import CoreAudio
import Foundation

/// Live system output volume using the **same 0…100 scale as the menu bar /
/// volume keys**. Polls + Core Audio listeners keep Dynamo in lockstep with
/// the machine; set/mute write through AppleScript so 10% in Dynamo is 10%
/// on the Mac.
@MainActor
final class SystemVolumeController: ObservableObject {
    static let shared = SystemVolumeController()

    /// Exact system UI percent 0…100 (what Control Center shows).
    @Published private(set) var percent: Int = 0
    /// 0…1 convenience for sliders (`percent / 100`).
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
        // Fast poll so keyboard / Control Center changes show immediately.
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
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

    /// Set volume to an exact UI percent (10 → system is 10%).
    func setPercent(_ value: Int) {
        suppressExternalUntil = Date().addingTimeInterval(0.45)
        let p = min(100, max(0, value))
        _ = SystemLevelReader.setOutputVolumePercent(p)
        applyLocal(percent: p, muted: p == 0 ? isMuted : false)
        // Confirm from system after the change settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.refreshFromSystem(announceExternal: false)
        }
    }

    func setLevel(_ value: Float) {
        let p = Int((min(1, max(0, value)) * 100).rounded())
        setPercent(p)
    }

    func setMuted(_ muted: Bool) {
        suppressExternalUntil = Date().addingTimeInterval(0.45)
        _ = SystemLevelReader.setMuted(muted)
        isMuted = muted
        if let settings = SystemLevelReader.systemVolumeSettings() {
            percent = settings.percent
            level = Float(settings.percent) / 100.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.refreshFromSystem(announceExternal: false)
        }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    /// One keyboard-like step (~6–7%).
    func nudge(by delta: Float) {
        let step = Int((delta * 100).rounded())
        let base = SystemLevelReader.systemVolumeSettings()?.percent ?? percent
        setPercent(base + (step == 0 ? (delta > 0 ? 1 : -1) : step))
    }

    // MARK: - Refresh

    func refreshFromSystem(announceExternal: Bool = false) {
        guard let settings = SystemLevelReader.systemVolumeSettings() else { return }
        let newName = SystemLevelReader.defaultOutputDeviceName()
        let changed = settings.percent != percent
            || settings.muted != isMuted
            || newName != deviceName
        guard changed else { return }

        applyLocal(percent: settings.percent, muted: settings.muted)
        deviceName = newName

        guard announceExternal else { return }
        if let until = suppressExternalUntil, Date() < until { return }
        onExternalChange?()
    }

    private func applyLocal(percent p: Int, muted: Bool) {
        percent = min(100, max(0, p))
        level = Float(percent) / 100.0
        isMuted = muted
    }

    // MARK: - Core Audio listeners (detect change; value comes from AppleScript)

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

        var vvol = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(0x7676_6F6C),
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &vvol, DispatchQueue.main, volumeBlock)

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
