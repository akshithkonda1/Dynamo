import Contacts
import Foundation
import Intents
import MusicKit

/// Connects Dynamo to Apple’s first-party frameworks.
///
/// Native path (no AppKit, no AppleScript):
/// EventKit calendars + reminders, MusicKit, WeatherKit, Contacts, Core Location,
/// INFocusStatusCenter.
///
/// AppleScript stays only where Apple still has no public API: Notes, Spotify,
/// and the Control Center volume scale.
@MainActor
final class AppleServicesHub {
    static let shared = AppleServicesHub()

    private var started = false

    private init() {}

    func connect(registry: WidgetRegistry) {
        guard !started else { return }
        started = true

        _ = registry
        if #available(macOS 12.0, *) {
            Task { await MusicKitBridge.shared.requestAuthorizationIfNeeded() }
        }

        ContactPhotoResolver.requestAccessOnLaunchIfNeeded()
        AppleFocusMirror.shared.start()
        PermissionsStore.shared.refreshFromSystem()
    }
}

/// Reads Apple Focus (Do Not Disturb and Focus modes) through Intents.
@MainActor
final class AppleFocusMirror: ObservableObject {
    static let shared = AppleFocusMirror()

    @Published private(set) var isFocused: Bool = false
    @Published private(set) var authorization: INFocusStatusAuthorizationStatus = .notDetermined

    private var timer: Timer?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let center = INFocusStatusCenter.default
        authorization = center.authorizationStatus
        if authorization == .notDetermined {
            center.requestAuthorization { [weak self] status in
                Task { @MainActor in
                    self?.authorization = status
                    self?.refresh()
                    PermissionsStore.shared.refreshFromSystem()
                }
            }
        } else {
            refresh()
        }
        let t = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let center = INFocusStatusCenter.default
        authorization = center.authorizationStatus
        let focused = center.focusStatus.isFocused ?? false
        if focused != isFocused {
            isFocused = focused
        }
    }
}
