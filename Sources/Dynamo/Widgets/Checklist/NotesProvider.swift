import AppKit
import Foundation

/// A note row surfaced from Apple Notes (via AppleScript — no private Notes APIs).
struct NoteItem: Identifiable, Equatable {
    /// Notes AppleScript id (stable for the session).
    let id: String
    let title: String
    let bodyPreview: String
    let modified: Date?
    let folderName: String
}

/// Read/write bridge to **Apple Notes** using AppleScript.
/// Notes live in a dedicated folder named `Dynamo` (created on first write).
@MainActor
final class NotesProvider: ObservableObject {
    static let folderName = "Dynamo"

    @Published private(set) var items: [NoteItem] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastStatus: String = "Idle"
    @Published private(set) var isAvailable: Bool = true
    /// Optional hook so ChecklistPlugin can refresh chrome without owning @Published wiring.
    var onChangeWire: (() -> Void)?

    private var timer: Timer?

    func start() {
        refresh()
        // Notes is user-driven; background sync + onAppear refresh for instant open.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let script = """
        with timeout of 12 seconds
            try
                tell application "Notes"
                    if not (exists folder "\(Self.folderName)") then
                        return "OK|"
                    end if
                    set outLines to {}
                    tell folder "\(Self.folderName)"
                        repeat with n in notes
                            try
                                set nid to id of n as text
                                set nname to name of n as text
                                set nbody to ""
                                try
                                    set nbody to plaintext of n as text
                                end try
                                set AppleScript's text item delimiters to {linefeed, return, tab, ASCII character 30, "|"}
                                set bodyBits to text items of nbody
                                set nameBits to text items of nname
                                set AppleScript's text item delimiters to " "
                                set flatBody to bodyBits as text
                                set flatName to nameBits as text
                                set AppleScript's text item delimiters to ""
                                if length of flatBody > 100 then
                                    set flatBody to text 1 thru 100 of flatBody
                                end if
                                set end of outLines to nid & "||" & flatName & "||" & flatBody
                            end try
                        end repeat
                    end tell
                    set AppleScript's text item delimiters to ASCII character 30
                    set joined to outLines as text
                    set AppleScript's text item delimiters to ""
                    return "OK|" & joined
                end tell
            on error errMsg number errNum
                return "ERR|" & errNum & ":" & errMsg
            end try
        end timeout
        """
        guard let out = Self.runAppleScript(script) else {
            lastError = Self.friendlyError(from: "Could not talk to Notes")
            isAvailable = false
            lastStatus = "Unavailable"
            return
        }
        if out.hasPrefix("ERR|") {
            lastError = Self.friendlyError(from: String(out.dropFirst(4)))
            isAvailable = false
            lastStatus = "Notes error"
            items = []
            return
        }
        isAvailable = true
        lastError = nil
        lastStatus = "Synced"
        var payload = out
        if payload.hasPrefix("OK|") { payload = String(payload.dropFirst(3)) }
        var parsed: [NoteItem] = []
        let records = payload.components(separatedBy: "\u{1e}")
        for record in records {
            let fields = record.components(separatedBy: "||")
            guard fields.count >= 2 else { continue }
            let nid = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard !nid.isEmpty else { continue }
            let cleanPreview = (preview == title) ? "" : preview
            parsed.append(NoteItem(
                id: nid,
                title: title.isEmpty ? "Untitled" : title,
                bodyPreview: cleanPreview,
                modified: nil,
                folderName: Self.folderName
            ))
        }
        items = parsed
        objectWillChange.send()
        onChangeWire?()
    }

    @discardableResult
    func create(title: String, body: String? = nil) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }

        // If Automation previously failed, try to (re)establish the Dynamo folder first.
        if !isAvailable {
            ensureFolder()
            guard isAvailable else { return false }
        }

        let titleEsc = t.appleScriptEscaped
        let extra = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let htmlBody = "<div>\(t.htmlEscaped)</div>"
            + (extra.isEmpty ? "" : "<div>\(extra.htmlEscaped)</div>")
        let htmlEsc = htmlBody.appleScriptEscaped
        let script = """
        with timeout of 12 seconds
            try
                tell application "Notes"
                    if not (exists folder "\(Self.folderName)") then
                        make new folder with properties {name:"\(Self.folderName)"}
                    end if
                    tell folder "\(Self.folderName)"
                        make new note with properties {name:"\(titleEsc)", body:"\(htmlEsc)"}
                    end tell
                end tell
                return "OK"
            on error errMsg number errNum
                return "ERR|" & errNum & ":" & errMsg
            end try
        end timeout
        """
        guard let out = Self.runAppleScript(script) else {
            lastError = Self.friendlyError(from: "Could not create note")
            isAvailable = false
            return false
        }
        if out.hasPrefix("ERR") {
            let raw = out.replacingOccurrences(of: "ERR\t", with: "").replacingOccurrences(of: "ERR|||", with: "")
            lastError = Self.friendlyError(from: raw)
            isAvailable = false
            return false
        }
        lastError = nil
        isAvailable = true
        refresh()
        return true
    }

    @discardableResult
    func delete(id: String) -> Bool {
        let esc = id.appleScriptEscaped
        let script = """
        with timeout of 12 seconds
            try
                tell application "Notes"
                    delete note id "\(esc)"
                end tell
                return "OK"
            on error errMsg number errNum
                return "ERR|" & errNum & ":" & errMsg
            end try
        end timeout
        """
        guard let out = Self.runAppleScript(script) else {
            lastError = Self.friendlyError(from: "Could not delete note")
            isAvailable = false
            return false
        }
        if out.hasPrefix("ERR|||") {
            lastError = Self.friendlyError(from: String(out.dropFirst(6)))
            isAvailable = false
            return false
        }
        items.removeAll { $0.id == id }
        lastError = nil
        objectWillChange.send()
        onChangeWire?()
        return true
    }

    func open(id: String) {
        let esc = id.appleScriptEscaped
        let script = """
        try
            tell application "Notes"
                activate
                show note id "\(esc)"
            end tell
            return "OK"
        on error
            tell application "Notes" to activate
            return "OK"
        end try
        """
        _ = Self.runAppleScript(script)
    }

    func openApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Notes.app"))
        }
    }

    /// Ensure Dynamo folder exists (first Automation prompt). Always refreshes afterward.
    func ensureFolder() {
        let script = """
        with timeout of 12 seconds
            try
                tell application "Notes"
                    if not (exists folder "\(Self.folderName)") then
                        make new folder with properties {name:"\(Self.folderName)"}
                    end if
                end tell
                return "OK"
            on error errMsg number errNum
                return "ERR|" & errNum & ":" & errMsg
            end try
        end timeout
        """
        if let out = Self.runAppleScript(script), out.hasPrefix("ERR|||") {
            lastError = Self.friendlyError(from: String(out.dropFirst(6)))
            isAvailable = false
        } else {
            isAvailable = true
            lastError = nil
        }
        isAvailable = true
        lastError = nil
        lastStatus = "Connected"
        refresh()
    }

    /// Turns a raw AppleScript/AppleEvent error into an actionable sentence
    /// instead of surfacing a bare error code like "-1743:Not authorized…".
    private static func friendlyError(from raw: String) -> String {
        if raw.contains("-1743") {
            return "Notes access isn't allowed yet — open System Settings → Privacy & Security → Automation and turn on Notes for Dynamo."
        }
        if raw.contains("-600") || raw.contains("-609") {
            return "Notes isn't responding — open the Notes app once, then try again."
        }
        return "Couldn't reach Notes (\(raw))."
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            let num = error[NSAppleScript.errorNumber] as? Int
            let msg = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            if let num {
                return "ERR|\(num):\(msg)"
            }
            return "ERR|\(msg)"
        }
        return result.stringValue ?? "OK"
    }
}

private extension String {
    var appleScriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
