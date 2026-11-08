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

/// Shows a brief volume/brightness Peek-HUD in the notch and, when enabled,
/// **replaces** the stock macOS OSD by intercepting the keys before the OS
/// handles them (`MediaKeyInterceptor`). Falls back to observe + kill
/// `OSDUIHelper` if Accessibility is not granted.
@MainActor
final class SystemHUDController: ObservableObject {
    @Published private(set) var state: SystemHUDState?

    /// True when HID interception is active (system HUD will not appear for keys).
    @Published private(set) var isInterceptingKeys = false

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hideWorkItem: DispatchWorkItem?
    private weak var notch: NotchWindowController?
    private let volume = SystemVolumeController.shared
    private let interceptor = MediaKeyInterceptor()
    /// True while this controller has claimed the notch overlay session.
    private var holdingOverlay = false
    /// Coalesce rapid dual-fire (key monitor + poll) into one present/hide cycle.
    private var lastPresentAt: Date = .distantPast
    private var lastBrightness: Float?
    private var brightnessPoll: Timer?
    private var defaultsObserver: NSObjectProtocol?

    func attach(notch: NotchWindowController) {
        self.notch = notch
        volume.start()

        interceptor.onVolumeHUD = { [weak self] level, muted in
            self?.show(SystemHUDState(kind: .volume, level: muted ? 0 : level, isMuted: muted))
        }
        interceptor.onBrightnessHUD = { [weak self] level in
            self?.lastBrightness = level
            self?.show(SystemHUDState(kind: .brightness, level: level, isMuted: false))
        }

        // One callback for Control Center / Dynamo slider → notch Peek HUD.
        // Skipped while we own the keys (interceptor already presented).
        volume.onHUDRelevantChange = { [weak self] in
            guard let self, !self.isInterceptingKeys else { return }
            self.presentVolumeFromLiveState()
        }

        startBrightnessPoll()
        refreshInterceptionMode()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: SystemOSDSuppressor.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshInterceptionMode() }
        }
    }

    func teardown() {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        stopObserveMonitors()
        interceptor.stop()
        isInterceptingKeys = false
        brightnessPoll?.invalidate()
        brightnessPoll = nil
        hideWorkItem?.cancel()
        if holdingOverlay {
            holdingOverlay = false
            notch?.overlayDidHide()
        }
        volume.onHUDRelevantChange = nil
        interceptor.onVolumeHUD = nil
        interceptor.onBrightnessHUD = nil
        volume.stop()
        state = nil
    }

    /// Re-evaluate whether we can own the keys. Call after Accessibility grant
    /// or when the Preferences toggle flips.
    func refreshInterceptionMode() {
        let wantReplace = SystemOSDSuppressor.isEnabled
        if wantReplace {
            if !interceptor.isActive {
                // Prompt once if needed so takeover can actually work.
                _ = MediaKeyInterceptor.requestAccessibilityIfNeeded()
                if interceptor.start() {
                    isInterceptingKeys = true
                    // Observation monitors would double-fire with interception.
                    stopObserveMonitors()
                    return
                }
            } else {
                isInterceptingKeys = true
                stopObserveMonitors()
                return
            }
        } else if interceptor.isActive {
            interceptor.stop()
        }

        isInterceptingKeys = false
        // Observe-only path: show Dynamo HUD alongside (or after killing) system OSD.
        installObserveMonitors()
    }

    // MARK: - Observe-only monitors (fallback when interception unavailable)

    private func installObserveMonitors() {
        guard localMonitor == nil, globalMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handleObservedSystemDefined(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            Task { @MainActor in
                self?.handleObservedSystemDefined(event)
            }
        }
    }

    private func stopObserveMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func startBrightnessPoll() {
        brightnessPoll?.invalidate()
        lastBrightness = SystemLevelReader.displayBrightness()
        // Catch Control Center / trackpad brightness when keys aren’t used /
        // interception isn’t active.
        let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollBrightnessIfChanged()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        brightnessPoll = t
    }

    private func pollBrightnessIfChanged() {
        // When we own brightness keys, poll only catches Control Center / ambient.
        // Still useful; suppress system OSD if we can.
        guard let current = SystemLevelReader.displayBrightness() else { return }
        defer { lastBrightness = current }
        guard let previous = lastBrightness else { return }
        guard abs(current - previous) >= 0.008 else { return }
        if holdingOverlay, state?.kind == .volume,
           Date().timeIntervalSince(lastPresentAt) < 0.35 {
            return
        }
        // Skip tiny changes we ourselves just applied via interceptor.
        if isInterceptingKeys, Date().timeIntervalSince(lastPresentAt) < 0.4 {
            return
        }
        SystemOSDSuppressor.suppressIfEnabled()
        show(SystemHUDState(kind: .brightness, level: current, isMuted: false))
    }

    private func handleObservedSystemDefined(_ event: NSEvent) {
        guard event.subtype.rawValue == 8 else { return }
        let data1 = event.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0x0000_FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        guard keyState == 0xA else { return }

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
            presentBrightnessObserved()
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

    private func presentBrightnessObserved() {
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
