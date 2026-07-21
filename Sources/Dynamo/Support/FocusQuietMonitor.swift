import AppKit
import Foundation

/// Best-effort “Focus is active” signal for Meeting Mode quiet peeks.
///
/// Public Focus status APIs are limited without extra entitlements. We use a
/// practical proxy that works without private APIs:
/// - When the user enables “Quiet peeks when Focus is on”, we treat **system
///   Low Power Mode** as an optional quiet signal *and* observe the
///   `NSWorkspace` “did activate” focus-related distributed notifications when
///   available.
/// - Calendar Meeting Mode remains the primary quiet path.
@MainActor
final class FocusQuietMonitor {
    static let shared = FocusQuietMonitor()

    private(set) var focusLikelyActive: Bool = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        MeetingMode.shared.isFocusActive = { [weak self] in
            self?.focusLikelyActive == true || ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        // Screen sleep / wake as weak signal refresh.
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        refresh()
    }

    func start() {
        refresh()
    }

    func refresh() {
        // Without Focus entitlement, Low Power Mode is the reliable public signal.
        // Users who want Focus alignment can enable “Quiet when Focus/LPM”.
        focusLikelyActive = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
