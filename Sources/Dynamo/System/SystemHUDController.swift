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

/// Shows a brief volume/brightness HUD in the notch without adding a third
/// hover expansion state. Triggered by system-defined media keys.
@MainActor
final class SystemHUDController: ObservableObject {
    @Published private(set) var state: SystemHUDState?

    private var localMonitor: Any?
    private var hideWorkItem: DispatchWorkItem?
    private weak var notch: NotchWindowController?

    func attach(notch: NotchWindowController) {
        self.notch = notch
        installKeyMonitor()
    }

    func teardown() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        hideWorkItem?.cancel()
        state = nil
    }

    private func installKeyMonitor() {
        // System-defined events (volume / brightness keys) arrive as NSEvents
        // with subtype .screenChanged (or raw 8) on many macOS versions.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleSystemDefined(event)
            return event
        }
        // Also watch globally so we see keys when Dynamo is not key.
        NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
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
            presentVolume()
        case 2, 3: // brightness up / down
            presentBrightness()
        default:
            break
        }
    }

    private func presentVolume() {
        let level = SystemLevelReader.outputVolume() ?? 0
        let muted = SystemLevelReader.isMuted()
        show(SystemHUDState(kind: .volume, level: muted ? 0 : level, isMuted: muted))
    }

    private func presentBrightness() {
        // Brightness may lag the keypress by a frame; sample after a tiny delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            let level = SystemLevelReader.displayBrightness() ?? 0.5
            self?.show(SystemHUDState(kind: .brightness, level: level, isMuted: false))
        }
    }

    private func show(_ newState: SystemHUDState) {
        state = newState
        // Ensure the notch is visible for the meter even in Hidden mode.
        notch?.presentForOverlay()
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.state = nil
            self?.notch?.overlayDidHide()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}
