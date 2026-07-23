import Foundation

struct TalkSuggestion: Identifiable, Equatable {
    let id: String
    let text: String
    let reason: String
}

/// Free local "what to say" coach — no network, no AI required.
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

        // Opening suggestion based on meeting title or app
        if !title.isEmpty {
            out.append(.init(id: "goal", text: "Just to align — success today looks like: \(title).", reason: "Agenda"))
        } else if let app = callApp {
            out.append(.init(id: "open", text: "Thanks for joining on \(app). What's the top outcome for this call?", reason: "Open"))
        } else {
            out.append(.init(id: "open2", text: "What would make this meeting a win?", reason: "Open"))
        }

        // Meeting-type playbooks from title keywords
        if lower.contains("standup") || lower.contains("stand-up") || lower.contains("daily") {
            out += [
                .init(id: "su1", text: "Any blockers I can help clear?", reason: "Standup"),
                .init(id: "su2", text: "What shipped since yesterday?", reason: "Standup"),
                .init(id: "su3", text: "What's the one focus for today?", reason: "Standup"),
            ]
        } else if lower.contains("retro") || lower.contains("retrospective") {
            out += [
                .init(id: "re1", text: "What went well that we should keep doing?", reason: "Retro"),
                .init(id: "re2", text: "What slowed us down or needs to change?", reason: "Retro"),
                .init(id: "re3", text: "What's the one concrete change for next sprint?", reason: "Retro"),
            ]
        } else if lower.contains("planning") || lower.contains("sprint") {
            out += [
                .init(id: "pl1", text: "What's the definition of done for this sprint?", reason: "Planning"),
                .init(id: "pl2", text: "Any dependencies we haven't mapped yet?", reason: "Planning"),
                .init(id: "pl3", text: "Who's the owner for each item?", reason: "Planning"),
            ]
        } else if lower.contains("1:1") || lower.contains("1-1") || lower.contains("one on one") {
            out += [
                .init(id: "oo1", text: "How are you feeling about workload this week?", reason: "1:1"),
                .init(id: "oo2", text: "Is there support you need from me?", reason: "1:1"),
                .init(id: "oo3", text: "What should we prioritize before next time?", reason: "1:1"),
            ]
        } else if lower.contains("interview") {
            out += [
                .init(id: "iv1", text: "Walk me through a recent project you're proud of.", reason: "Interview"),
                .init(id: "iv2", text: "What would you do differently next time?", reason: "Interview"),
                .init(id: "iv3", text: "What does good look like in this role to you?", reason: "Interview"),
            ]
        } else if lower.contains("demo") || lower.contains("review") || lower.contains("design") {
            out += [
                .init(id: "dm1", text: "What decision do we need by the end of this?", reason: "Review"),
                .init(id: "dm2", text: "What assumptions are we making here?", reason: "Review"),
                .init(id: "dm3", text: "Any risks we haven't named yet?", reason: "Review"),
            ]
        } else if lower.contains("sync") || lower.contains("check-in") || lower.contains("checkin") {
            out += [
                .init(id: "sy1", text: "Anything blocking that we can resolve right now?", reason: "Sync"),
                .init(id: "sy2", text: "What's changed since we last spoke?", reason: "Sync"),
            ]
        } else if lower.contains("all-hands") || lower.contains("allhands") || lower.contains("townhall") || lower.contains("town hall") {
            out += [
                .init(id: "ah1", text: "What question would you most want leadership to answer?", reason: "All-Hands"),
                .init(id: "ah2", text: "What should we start, stop, or continue as a company?", reason: "All-Hands"),
            ]
        }

        // Content-aware triggers from recent notes
        let noteTexts = notes.map { $0.text.lowercased() }
        let recentNoteTexts = notes.suffix(5).map { $0.text.lowercased() }

        if noteTexts.contains(where: { $0.contains("blocked") || $0.contains("waiting on") || $0.contains("dependency") }) {
            out.append(.init(id: "block", text: "Who owns unblocking this — and what's the timeline?", reason: "Blocker"))
        }

        if noteTexts.contains(where: { containsMetric($0) }) {
            out.append(.init(id: "metric", text: "Can we add context behind that number — baseline and target?", reason: "From notes"))
        }

        if noteTexts.contains(where: { $0.contains("agreed") || $0.contains("decided") || $0.contains("we'll") }) {
            out.append(.init(id: "decision", text: "Should we capture that as a formal decision with an owner?", reason: "From notes"))
        }

        // Surface the last note ending in "?" as a discussion point
        if let questionNote = notes.suffix(5).last(where: { $0.text.hasSuffix("?") }) {
            let snippet = String(questionNote.text.prefix(60))
            out.append(.init(
                id: "q-\(questionNote.id.uuidString.prefix(6))",
                text: "You flagged: \"\(snippet)\" — want to dig into that now?",
                reason: "Open question"
            ))
        }

        // From most recent note (not a question — already handled above)
        if let last = notes.suffix(3).last(where: { !$0.text.hasSuffix("?") }) {
            let snippet = String(last.text.prefix(60))
            out.append(.init(
                id: "note-\(last.id.uuidString.prefix(6))",
                text: "On \"\(snippet)\" — what's the next concrete step?",
                reason: "From notes"
            ))
        }

        // Time-based milestones
        if mins >= 5, mins < 10 {
            out.append(.init(id: "t5", text: "Have we covered the agenda items?", reason: "5 min check"))
        }
        if mins >= 15, mins < 20 {
            out.append(.init(id: "t15", text: "Halfway — are we still on track for the main goal?", reason: "Mid-meeting"))
        }
        if mins >= 25, mins < 30 {
            out.append(.init(id: "t25", text: "Five minutes left — decisions and owners before we close?", reason: "Closing"))
        }
        if mins >= 20 {
            out.append(.init(id: "t_close1", text: "Before we wrap — owners and due dates for action items?", reason: "Close"))
            out.append(.init(id: "t_close2", text: "I'll recap next steps in the notes — anything missing?", reason: "Close"))
        }

        // Dedupe by text, cap at 5
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

    // MARK: - Helpers

    private static func containsMetric(_ text: String) -> Bool {
        if text.contains("%") { return true }
        // digit followed by k, m, x, or units like "ms", "rpm"
        let pattern = try? NSRegularExpression(pattern: #"\d+[kmx]|\d+ms|\d+rpm"#)
        let range = NSRange(text.startIndex..., in: text)
        return pattern?.firstMatch(in: text, range: range) != nil
    }
}
