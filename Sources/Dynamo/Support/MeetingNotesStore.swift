import AppKit
import Foundation

struct MeetingNoteBullet: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var createdAt: Date
    var source: Source

    enum Source: String, Codable {
        case typed
        case speech
        case suggestion
    }

    init(id: UUID = UUID(), text: String, createdAt: Date = Date(), source: Source) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.source = source
    }
}

struct MeetingNoteSession: Identifiable, Codable, Equatable {
    let id: UUID
    var startedAt: Date
    var endedAt: Date?
    var calendarTitle: String?
    var callApp: String?
    var bullets: [MeetingNoteBullet]

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        calendarTitle: String? = nil,
        callApp: String? = nil,
        bullets: [MeetingNoteBullet] = []
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.calendarTitle = calendarTitle
        self.callApp = callApp
        self.bullets = bullets
    }
}

/// Local-only meeting notes (App Support). Free, no network.
@MainActor
final class MeetingNotesStore: ObservableObject {
    static let shared = MeetingNotesStore()

    @Published private(set) var session: MeetingNoteSession?
    @Published var draft: String = ""

    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let d = base.appendingPathComponent("Dynamo/MeetingNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private init() {}

    func ensureSession(calendarTitle: String? = nil, callApp: String? = nil) {
        // Ended sessions must not be reused — start a fresh note pad.
        if let existing = session, existing.endedAt == nil {
            if let calendarTitle { session?.calendarTitle = calendarTitle }
            if let callApp { session?.callApp = callApp }
            persist()
            objectWillChange.send()
            return
        }
        session = MeetingNoteSession(calendarTitle: calendarTitle, callApp: callApp)
        draft = ""
        persist()
        objectWillChange.send()
    }

    func endSession() {
        guard var s = session, s.endedAt == nil else {
            draft = ""
            return
        }
        s.endedAt = Date()
        session = s
        persist()
        draft = ""
        objectWillChange.send()
    }

    @discardableResult
    func addBullet(_ text: String, source: MeetingNoteBullet.Source) -> MeetingNoteBullet? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        ensureSession()
        guard session?.endedAt == nil else { return nil }
        let bullet = MeetingNoteBullet(text: trimmed, source: source)
        session?.bullets.append(bullet)
        persist()
        objectWillChange.send()
        return bullet
    }

    func submitDraft() {
        if addBullet(draft, source: .typed) != nil {
            draft = ""
        }
    }

    func pinSuggestion(_ text: String) {
        _ = addBullet(text, source: .suggestion)
    }

    func clearBullets() {
        session?.bullets = []
        persist()
        objectWillChange.send()
    }

    func copyAllToPasteboard() {
        let allBullets = session?.bullets ?? []
        let lines = allBullets.map { b in
            let t = Self.time.string(from: b.createdAt)
            return "• [\(t)] \(b.text)"
        }
        let actions = MeetingActionExtractor.extract(from: allBullets)
        var header: [String] = ["# Meeting notes"]
        if let title = session?.calendarTitle { header.append("Event: \(title)") }
        if let app = session?.callApp { header.append("App: \(app)") }
        if let start = session?.startedAt {
            header.append("Started: \(Self.time.string(from: start))")
        }
        header.append("")
        var sections = header + lines
        if !actions.isEmpty {
            sections += ["", "## Action items"]
            sections += actions.map { "- [ ] \($0.text)" }
        }
        let body = sections.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }

    var bullets: [MeetingNoteBullet] { session?.bullets ?? [] }

    private func persist() {
        guard let session else { return }
        let url = dir.appendingPathComponent("\(session.id.uuidString).json")
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
