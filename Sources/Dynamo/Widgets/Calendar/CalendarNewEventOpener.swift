import AppKit
import Foundation

/// Opens Calendar’s new-event UI as reliably as macOS allows without Accessibility
/// spam. Shared by Local DB + EventKit providers so “New” always behaves the same.
enum CalendarNewEventOpener {
    @MainActor
    static func open() {
        // Always activate Calendar, then ⌘N — bare ical:// opens the app but
        // is not a compose deep link, so we never treat open() alone as success.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.open(url)
        } else if let ical = URL(string: "ical://") {
            NSWorkspace.shared.open(ical)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            sendCommandNViaAppleScript()
        }
    }

    /// Uses System Events keystroke — more reliable than CGEvent from an accessory app.
    private static func sendCommandNViaAppleScript() {
        let source = """
        tell application "Calendar" to activate
        delay 0.15
        try
            tell application "System Events"
                tell process "Calendar"
                    keystroke "n" using command down
                end tell
            end tell
        end try
        """
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            _ = script.executeAndReturnError(&error)
        }
    }
}
