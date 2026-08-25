import AppKit
import Combine
import Foundation

enum SystemHUDKind: Equatable {
    case volume
    case brightness
}

struct SystemHUDState: Equatable {
    var kind: SystemHUDKind
    var level: Float // 0...1
    var isMuted: Bool
}

/// Shows a brief volume/brightness Peek-HUD in the notch and optionally
/// suppresses the stock macOS OSD so Dynamo is the only feedback surface.
@MainActor
final class SystemHUDController: ObservableObject {
    @Published private(set) var state: SystemHUDState?

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hideWorkItem: DispatchWorkItem?
    private weak var notch: NotchWindowController?
    private let volume = SystemVolumeController.shared
    /// True while this controller has claimed the notch overlay session.
    private var holdingOverlay = false
    /// Coalesce rapid dual-fire (key monitor + poll) into one present/hide cycle.
    private var lastPresentAt: Date = .distantPast
    private var lastBrightness: Float?
    private var brightnessPoll: Timer?

    func attach(notch: NotchWindowController) {
        self.notch = notch
        volume.start()
        // One callback for keys / Control Center / Dynamo slider → notch Peek HUD.
        volume.onHUDRelevantChange = { [weak self] in
            self?.presentVolumeFromLiveState()
        }
        installKeyMonitor()
        startBrightnessPoll()
    }

    func teardown() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        brightnessPoll?.invalidate()
        brightnessPoll = nil
        hideWorkItem?.cancel()
        if holdingOverlay {
            holdingOverlay = false
            notch?.overlayDidHide()
        }
        volume.onHUDRelevantChange = nil
        volume.stop()
        state = nil
    }

    private func installKeyMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleSystemDefined(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            Task { @MainActor in
                self?.handleSystemDefined(event)
            }
        }
    }

    private func startBrightnessPoll() {
        brightnessPoll?.invalidate()
        lastBrightness = SystemLevelReader.displayBrightness()
        // Catch Control Center / trackpad brightness when keys aren’t used.
        let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollBrightnessIfChanged()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        brightnessPoll = t
    }

    private func pollBrightnessIfChanged() {
        guard let current = SystemLevelReader.displayBrightness() else { return }
        defer { lastBrightness = current }
        guard let previous = lastBrightness else { return }
        // Ignore tiny sensor jitter.
        guard abs(current - previous) >= 0.008 else { return }
        // Don’t steal focus from an active volume HUD mid-gesture.
        if holdingOverlay, state?.kind == .volume,
           Date().timeIntervalSince(lastPresentAt) < 0.35 {
            return
        }
        SystemOSDSuppressor.suppressIfEnabled()
        show(SystemHUDState(kind: .brightness, level: current, isMuted: false))
    }

    private func handleSystemDefined(_ event: NSEvent) {
        // NX data1 encodes key type in high byte and key flags in low bits.
        // See IOKit/hidsystem/ev_keymap.h: NX_KEYTYPE_SOUND_UP = 0, etc.
        guard event.subtype.rawValue == 8 else { return }
        let data1 = event.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0x0000_FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        // 0xA = key down, 0xB = key up — react on key down only.
        guard keyState == 0xA else { return }

        // Kill the stock OSD ASAP so Dynamo’s notch Peek is what the user sees.
        SystemOSDSuppressor.suppressIfEnabled()

        switch keyCode {
        case 0, 1, 7: // sound up, sound down, mute
            volume.suppressExternalAnnouncements(for: 0.55)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                SystemOSDSuppressor.suppressIfEnabled()
                self?.volume.refreshFromSystem(announceExternal: false)
                self?.presentVolumeFromLiveState()
            }
        case 2, 3: // brightness up / down
            presentBrightness()
        default:
            break
        }
    }

    private func presentVolumeFromLiveState() {
        SystemOSDSuppressor.suppressIfEnabled()
        volume.refreshFromSystem(announceExternal: false)
        let level = volume.level
        let muted = volume.isMuted
        show(SystemHUDState(kind: .volume, level: muted ? 0 : level, isMuted: muted))
    }

    private func presentBrightness() {
        SystemOSDSuppressor.suppressIfEnabled()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            SystemOSDSuppressor.suppressIfEnabled()
            let level = SystemLevelReader.displayBrightness() ?? 0.5
            self?.lastBrightness = level
            self?.show(SystemHUDState(kind: .brightness, level: level, isMuted: false))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.holdingOverlay, self.state?.kind == .brightness else { return }
            let level = SystemLevelReader.displayBrightness() ?? 0.5
            self.lastBrightness = level
            self.state = SystemHUDState(kind: .brightness, level: level, isMuted: false)
        }
    }

    private func show(_ newState: SystemHUDState) {
        let now = Date()
        lastPresentAt = now
        state = newState

        if !holdingOverlay {
            holdingOverlay = true
            notch?.presentForOverlay()
        }

        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.state = nil
            if self.holdingOverlay {
                self.holdingOverlay = false
                self.notch?.overlayDidHide()
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.35, execute: work)
    }
}
