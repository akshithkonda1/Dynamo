import AppKit
import Foundation

/// Opens Calendar’s new-event UI as reliably as macOS allows without Accessibility
/// spam. Shared by Local DB + EventKit providers so “New” always behaves the same.
enum CalendarNewEventOpener {
    @MainActor
    static func open() {
        // 1) Try known compose deep-links (vary by macOS / Calendar build).
        let candidates = [
            "ical://ekevent",
            "webcal://",
            "ical://"
        ]
        var opened = false
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) {
                opened = true
                break
            }
        }
        if !opened {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                NSWorkspace.shared.open(app)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
            }
        }

        // 2) After Calendar is frontmost, send ⌘N via System Events (best-effort).
        //    Requires Automation permission for System Events once; fails quietly otherwise.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            sendCommandNViaAppleScript()
        }
        // Retry once — Calendar cold-launch is slow on some machines.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
            sendCommandNViaAppleScript()
        }
    }

    /// Uses System Events keystroke — more reliable than CGEvent from an accessory app.
    private static func sendCommandNViaAppleScript() {
        let source = """
        tell application "Calendar" to activate
        delay 0.2
        try
            tell application "System Events"
                if exists process "Calendar" then
                    tell process "Calendar"
                        set frontmost to true
                        keystroke "n" using command down
                    end tell
                end if
            end tell
        end try
        """
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            _ = script.executeAndReturnError(&error)
        }
    }
}
