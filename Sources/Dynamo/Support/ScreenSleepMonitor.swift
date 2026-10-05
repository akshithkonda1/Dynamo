import AppKit
import Combine
import Foundation

/// Display sleep / wake for Ambient waveform. When the screens are asleep the
/// decorative TimelineView must not keep ticking.
@MainActor
final class ScreenSleepMonitor: ObservableObject {
    static let shared = ScreenSleepMonitor()

    @Published private(set) var isAsleep: Bool = false

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isAsleep = true }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.isAsleep = false }
        })
    }
}
