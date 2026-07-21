import AppKit
import Foundation

/// Detects likely meeting/call apps for auto Meeting Mode.
@MainActor
final class CallSessionProbe {
    enum Reason: Equatable {
        case calendar
        case call(appName: String)
    }

    /// Bundle IDs treated as “in a call” when running (not terminated).
    static let defaultAllowlist: [String: String] = [
        "com.apple.FaceTime": "FaceTime",
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Teams",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.SkypeForBusiness": "Skype",
        "com.webex.meetingmanager": "Webex",
        "com.cisco.webexmeetingsapp": "Webex"
    ]

    private(set) var activeCallAppName: String?
    private var timer: Timer?
    private var onChange: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        refresh()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onChange = nil
    }

    func refresh() {
        let apps = NSWorkspace.shared.runningApplications
        var found: String?
        for app in apps where !app.isTerminated {
            guard let bid = app.bundleIdentifier,
                  let name = Self.defaultAllowlist[bid]
            else { continue }
            found = name
            break
        }
        if found != activeCallAppName {
            activeCallAppName = found
            onChange?()
        }
    }

    var isInCall: Bool { activeCallAppName != nil }
}
