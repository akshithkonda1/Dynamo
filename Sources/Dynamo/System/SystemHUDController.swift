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

/// Shows a brief volume/brightness HUD in the notch. Tracks real machine
/// volume via `SystemVolumeController` (keys, Control Center, Dynamo slider).
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

    func attach(notch: NotchWindowController) {
        self.notch = notch
        volume.start()
        volume.onExternalChange = { [weak self] in
            self?.presentVolumeFromLiveState()
        }
        installKeyMonitor()
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
        hideWorkItem?.cancel()
        if holdingOverlay {
            holdingOverlay = false
            notch?.overlayDidHide()
        }
        volume.onExternalChange = nil
        volume.stop()
        state = nil
    }

    private func installKeyMonitor() {
        // Volume / brightness keys as system-defined NSEvents.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleSystemDefined(event)
            return event
        }
        // Also watch globally so we see keys when Dynamo is not key. The
        // returned token must be captured so teardown() can actually remove it —
        // addGlobalMonitorForEvents has no other way to unregister, and a
        // discarded token would leak this monitor for the life of the process.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            Task { @MainActor in
                self?.handleSystemDefined(event)
            }
        }
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

        switch keyCode {
        case 0, 1, 7: // sound up, sound down, mute
            // Suppress poll-driven onExternalChange so we don't double-present.
            volume.suppressExternalAnnouncements(for: 0.55)
            // Sample after the system applies the key (a few ms lag).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
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
        volume.refreshFromSystem(announceExternal: false)
        let level = volume.level
        let muted = volume.isMuted
        show(SystemHUDState(kind: .volume, level: muted ? 0 : level, isMuted: muted))
    }

    private func presentBrightness() {
        // Single delayed sample — a second show() used to stack overlay refcount.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            let level = SystemLevelReader.displayBrightness() ?? 0.5
            self?.show(SystemHUDState(kind: .brightness, level: level, isMuted: false))
        }
        // Optional level refresh only (no second present) once the OS settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, self.holdingOverlay, self.state?.kind == .brightness else { return }
            let level = SystemLevelReader.displayBrightness() ?? 0.5
            self.state = SystemHUDState(kind: .brightness, level: level, isMuted: false)
        }
    }

    private func show(_ newState: SystemHUDState) {
        // Coalesce key+poll dual-fire: only claim the overlay once per session.
        let now = Date()
        lastPresentAt = now
        state = newState

        if !holdingOverlay {
            holdingOverlay = true
            notch?.presentForOverlay()
        }
        // Refresh: update state + reschedule hide only — do NOT re-present
        // (that stacked refcount and left the tray stuck at overlay height).

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}
