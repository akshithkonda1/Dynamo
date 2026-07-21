import Foundation

struct TalkSuggestion: Identifiable, Equatable {
    let id: String
    let text: String
    let reason: String
}

/// Free local “what to say” coach — no network, no AI required.
enum MeetingTalkCoach {
    static func suggestions(
        calendarTitle: String?,
        callApp: String?,
        notes: [MeetingNoteBullet],
        elapsed: TimeInterval
    ) -> [TalkSuggestion] {
        var out: [TalkSuggestion] = []
        let title = (calendarTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = title.lowercased()
        let mins = Int(elapsed / 60)

        // Playbook from title keywords
        if lower.contains("standup") || lower.contains("stand-up") || lower.contains("daily") {
            out.append(contentsOf: [
                .init(id: "su1", text: "Any blockers I can help clear?", reason: "Standup"),
                .init(id: "su2", text: "What shipped since yesterday?", reason: "Standup"),
                .init(id: "su3", text: "What’s the one focus for today?", reason: "Standup")
            ])
        } else if lower.contains("1:1") || lower.contains("1-1") || lower.contains("one on one") {
            out.append(contentsOf: [
                .init(id: "oo1", text: "How are you feeling about workload this week?", reason: "1:1"),
                .init(id: "oo2", text: "Is there support you need from me?", reason: "1:1"),
                .init(id: "oo3", text: "What should we prioritize before next time?", reason: "1:1")
            ])
        } else if lower.contains("interview") {
            out.append(contentsOf: [
                .init(id: "iv1", text: "Walk me through a recent project you’re proud of.", reason: "Interview"),
                .init(id: "iv2", text: "What would you do differently next time?", reason: "Interview")
            ])
        } else if lower.contains("demo") || lower.contains("review") {
            out.append(contentsOf: [
                .init(id: "dm1", text: "What decision do we need by the end of this?", reason: "Review"),
                .init(id: "dm2", text: "Any risks we haven’t named yet?", reason: "Review")
            ])
        }

        if !title.isEmpty {
            out.insert(
                .init(id: "goal", text: "Just to align — success today looks like: \(title).", reason: "Agenda"),
                at: 0
            )
        } else if let app = callApp {
            out.insert(
                .init(id: "open", text: "Thanks for joining on \(app). What’s the top outcome for this call?", reason: "Open"),
                at: 0
            )
        } else {
            out.insert(
                .init(id: "open2", text: "What would make this meeting a win?", reason: "Open"),
                at: 0
            )
        }

        // Time-based
        if mins >= 8, mins < 15 {
            out.append(.init(id: "t1", text: "Can we park side threads and lock the main decision?", reason: "Mid-meeting"))
        }
        if mins >= 20 {
            out.append(.init(id: "t2", text: "Before we wrap — owners and due dates?", reason: "Close"))
            out.append(.init(id: "t3", text: "I’ll recap next steps in the notes — anything missing?", reason: "Close"))
        }

        // From recent notes
        if let last = notes.suffix(3).last {
            let snippet = String(last.text.prefix(80))
            out.append(.init(
                id: "note-\(last.id.uuidString.prefix(6))",
                text: "On “\(snippet)” — what’s the next concrete step?",
                reason: "From notes"
            ))
        }

        // Dedupe by text, cap 5
        var seen = Set<String>()
        var unique: [TalkSuggestion] = []
        for s in out {
            if seen.insert(s.text).inserted {
                unique.append(s)
            }
            if unique.count >= 5 { break }
        }
        return unique
    }
}
