import AppKit
import Foundation

/// Detects call / meeting apps for Meeting **suggestions** and **Peek** alerts.
/// Never force-joins calls. Emits notch Peeks when a call app becomes active.
@MainActor
final class CallSessionProbe {
    static let defaultAllowlist: [String: String] = [
        "com.apple.FaceTime": "FaceTime",
        "com.apple.InCallService": "Phone",
        "com.apple.MobileSMS": "Messages",
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Teams",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.SkypeForBusiness": "Skype",
        "com.webex.meetingmanager": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.hnc.Discord": "Discord",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.loom.desktop": "Loom"
    ]

    /// Apps that should fire a high-urgency Peek when they launch / come frontmost.
    private static let peekOnActivate: Set<String> = [
        "com.apple.FaceTime",
        "com.apple.InCallService",
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2"
    ]

    private(set) var activeCallAppName: String?
    /// Frontmost allowlisted app only — used for “Enter Meeting?” offers.
    private(set) var suggestedFrontmostCallApp: String?
    private var timer: Timer?
    private var onChange: (() -> Void)?
    private var lastPeekedApp: String?
    private var lastPeekAt: Date = .distantPast

    /// When true (default), FaceTime / Zoom / Teams activation → Peek.
    var emitCallPeeks: Bool = true

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        refresh()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                self?.refresh()
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self?.maybePeekCallApp(app, reason: "activated")
                }
            }
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                self?.refresh()
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self?.maybePeekCallApp(app, reason: "launched")
                }
            }
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

    private func maybePeekCallApp(_ app: NSRunningApplication, reason: String) {
        guard emitCallPeeks else { return }
        guard let bid = app.bundleIdentifier, Self.peekOnActivate.contains(bid) else { return }
        let name = Self.defaultAllowlist[bid] ?? app.localizedName ?? "Call"
        // Coalesce: one peek per app per 45s.
        if lastPeekedApp == bid, Date().timeIntervalSince(lastPeekAt) < 45 { return }
        lastPeekedApp = bid
        lastPeekAt = Date()

        let isFaceTimeOrPhone = bid.contains("FaceTime") || bid.contains("InCall")
        DynamoNotificationRouter.shared.route(
            title: isFaceTimeOrPhone ? "\(name) active" : "\(name) opened",
            subtitle: reason == "launched" ? "App launched" : "Brought to front",
            detail: "Call · \(name)",
            systemImage: isFaceTimeOrPhone ? "phone.fill" : "video.fill",
            urgency: .critical,
            source: .call,
            category: "call",
            id: "call|\(bid)|\(Int(Date().timeIntervalSince1970 / 45))"
        )
    }

    var isInCall: Bool { suggestedFrontmostCallApp != nil }
}
