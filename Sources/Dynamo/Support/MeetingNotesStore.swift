import AppKit
import Foundation
import UniformTypeIdentifiers

enum BulletTag: String, Codable, CaseIterable {
    case decision, action, risk

    var label: String { rawValue.capitalized }

    var systemImage: String {
        switch self {
        case .decision: return "checkmark.seal"
        case .action:   return "arrow.right.circle"
        case .risk:     return "exclamationmark.triangle"
        }
    }

    /// Cycles to the next tag, wrapping back to nil after .risk.
    var next: BulletTag? {
        let all = BulletTag.allCases
        guard let idx = all.firstIndex(of: self) else { return nil }
        let next = all.index(after: idx)
        return next < all.endIndex ? all[next] : nil
    }
}

struct MeetingNoteBullet: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var createdAt: Date
    var source: Source
    var tag: BulletTag?

    enum Source: String, Codable {
        case typed
        case speech
        case suggestion
    }

    init(id: UUID = UUID(), text: String, createdAt: Date = Date(), source: Source, tag: BulletTag? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.source = source
        self.tag = tag
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

    // MARK: - Session lifecycle

    func ensureSession(calendarTitle: String? = nil, callApp: String? = nil) {
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

    // MARK: - Bullet CRUD

    @discardableResult
    func addBullet(_ text: String, source: MeetingNoteBullet.Source, tag: BulletTag? = nil) -> MeetingNoteBullet? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        ensureSession()
        guard session?.endedAt == nil else { return nil }
        let bullet = MeetingNoteBullet(text: trimmed, source: source, tag: tag)
        session?.bullets.append(bullet)
        persist()
        objectWillChange.send()
        return bullet
    }

    func deleteBullet(id: UUID) {
        session?.bullets.removeAll { $0.id == id }
        persist()
        objectWillChange.send()
    }

    func editBullet(id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = session?.bullets.firstIndex(where: { $0.id == id }) else { return }
        session?.bullets[idx].text = trimmed
        persist()
        objectWillChange.send()
    }

    func tagBullet(id: UUID, tag: BulletTag?) {
        guard let idx = session?.bullets.firstIndex(where: { $0.id == id }) else { return }
        session?.bullets[idx].tag = tag
        persist()
        objectWillChange.send()
    }

    func submitDraft() {
        if addBullet(draft, source: .typed) != nil {
            draft = ""
        }
    }

    func pinSuggestion(_ text: String) {
        _ = addBullet(text, source: .suggestion, tag: .action)
    }

    func clearBullets() {
        session?.bullets = []
        persist()
        objectWillChange.send()
    }

    var bullets: [MeetingNoteBullet] { session?.bullets ?? [] }

    // MARK: - History

    /// Returns all persisted sessions except the current one, newest first.
    func loadPastSessions() -> [MeetingNoteSession] {
        let currentID = session?.id
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> MeetingNoteSession? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(MeetingNoteSession.self, from: data)
            }
            .filter { $0.id != currentID }
            .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Export

    func copyAllToPasteboard() {
        copySession(session)
    }

    func copySession(_ session: MeetingNoteSession?) {
        guard let session else { return }
        let text = buildMarkdown(session)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func saveToFile() {
        saveSession(session)
    }

    func saveSession(_ session: MeetingNoteSession?) {
        guard let session else { return }
        let markdown = buildMarkdown(session)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        let dateStr = DateFormatter.localizedString(from: session.startedAt, dateStyle: .medium, timeStyle: .none)
        let title = session.calendarTitle ?? "Meeting Notes"
        panel.nameFieldStringValue = "\(title) \(dateStr).md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func buildMarkdown(_ session: MeetingNoteSession) -> String {
        var lines: [String] = []

        var header = "# Meeting Notes"
        if let title = session.calendarTitle { header += ": \(title)" }
        lines.append(header)

        var meta: [String] = []
        meta.append(Self.datetime.string(from: session.startedAt))
        if let app = session.callApp { meta.append(app) }
        if !meta.isEmpty { lines.append(meta.joined(separator: " · ")) }
        lines.append("")

        let untagged = session.bullets.filter { $0.tag == nil }
        let decisions = session.bullets.filter { $0.tag == .decision }
        let actions   = session.bullets.filter { $0.tag == .action }
        let risks     = session.bullets.filter { $0.tag == .risk }

        if !untagged.isEmpty {
            lines.append("## Notes")
            for b in untagged {
                lines.append("• [\(Self.time.string(from: b.createdAt))] \(b.text)")
            }
            lines.append("")
        }

        if !decisions.isEmpty {
            lines.append("## Decisions")
            for b in decisions { lines.append("• \(b.text)") }
            lines.append("")
        }

        if !actions.isEmpty {
            lines.append("## Action Items")
            for b in actions { lines.append("- [ ] \(b.text)") }
            lines.append("")
        }

        if !risks.isEmpty {
            lines.append("## Risks")
            for b in risks { lines.append("⚠ \(b.text)") }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

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

    private static let datetime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
