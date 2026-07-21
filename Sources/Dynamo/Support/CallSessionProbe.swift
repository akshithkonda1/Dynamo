import AppKit
import Foundation

/// Detects call apps for Meeting **suggestions** and context (never force-joins).
@MainActor
final class CallSessionProbe {
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
    /// Frontmost allowlisted app only — used for “Enter Meeting?” offers.
    private(set) var suggestedFrontmostCallApp: String?
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

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
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
        var anyRunning: String?
        var frontmost: String?

        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier,
           let name = Self.defaultAllowlist[bid],
           !front.isTerminated {
            // Require a visible window when possible.
            if front.activationPolicy == .regular {
                frontmost = name
            }
        }

        for app in apps where !app.isTerminated {
            guard let bid = app.bundleIdentifier,
                  let name = Self.defaultAllowlist[bid]
            else { continue }
            anyRunning = name
            break
        }

        let prevFront = suggestedFrontmostCallApp
        let prevAny = activeCallAppName
        suggestedFrontmostCallApp = frontmost
        activeCallAppName = anyRunning
        if prevFront != frontmost || prevAny != anyRunning {
            onChange?()
        }
    }

    var isInCall: Bool { suggestedFrontmostCallApp != nil }
}
