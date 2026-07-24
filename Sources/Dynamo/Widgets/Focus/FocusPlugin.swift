import AppKit
import SwiftUI

@MainActor
final class FocusPlugin: ObservableObject, NotchWidgetPlugin, NotchAmbientProviding {
    let id = "focus"
    let displayName = "Focus"
    let systemImage = "scope"

    var expandedContentHeight: CGFloat { 255 }

    var isAmbientActive: Bool {
        let f = FocusController.shared
        if f.isMeetingActive { return true }
        if f.baseMode == .trueFocus, FocusAgendaEngine.shared.snapshot.now != nil { return true }
        return false
    }

    var ambientPriority: Int {
        if FocusController.shared.isMeetingActive { return 88 }
        if FocusController.shared.baseMode == .trueFocus,
           FocusAgendaEngine.shared.snapshot.now != nil { return 70 }
        return 0
    }

    func start() {
        FocusController.shared.start()
    }

    func stop() {
        FocusController.shared.stop()
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedFocusView())
    }

    func ambientView() -> AnyView {
        AnyView(AmbientFocusView())
    }
}

// MARK: - Ambient

private struct AmbientFocusView: View {
    @ObservedObject private var focus = FocusController.shared
    @ObservedObject private var agenda = FocusAgendaEngine.shared

    var body: some View {
        HStack(spacing: 6) {
            if focus.isMeetingActive {
                Image(systemName: "video.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.caution)
                Text("Meeting")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                if let app = focus.suggestedCallApp {
                    Text(app)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                        .lineLimit(1)
                }
            } else if let now = agenda.snapshot.now {
                Image(systemName: "target")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.positive)
                Text(now.title)
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchTheme.ambientInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Expanded

private struct ExpandedFocusView: View {
    @ObservedObject private var focus = FocusController.shared
    @ObservedObject private var agenda = FocusAgendaEngine.shared
    @ObservedObject private var notes = MeetingNotesStore.shared
    @ObservedObject private var speech = MeetingSpeechCapture.shared
    @ObservedObject private var volume = SystemVolumeController.shared
    @State private var showAllAgenda = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 6)
            modePicker.padding(.bottom, 6)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    if focus.baseMode == .meeting {
                        meetingCompanion
                    } else {
                        modeBody
                    }
                }
            }

            if focus.baseMode != .meeting {
                footerActions.padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            SystemVolumeController.shared.start()
            FocusController.shared.reevaluateMeeting()
            speech.refreshAuth()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Focus")
                    .font(NotchTheme.section)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.7)
                Text(statusLine)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(focus.effectiveTitle)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(focus.isMeetingActive ? NotchTheme.caution : NotchTheme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(focus.isMeetingActive
                              ? NotchTheme.caution.opacity(0.18)
                              : NotchTheme.chipFillActive)
                )
        }
    }

    private var statusLine: String {
        switch focus.baseMode {
        case .meeting:
            let m = Int(focus.meetingElapsed / 60)
            let s = Int(focus.meetingElapsed) % 60
            return String(format: "Companion · %d:%02d · vol %d%%", m, s, volume.percent)
        case .dynamic: return "Next actions & peeks"
        case .trueFocus: return "Agenda from Calendar & Reminders"
        case .normal: return "Default Dynamo"
        }
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(FocusBaseMode.allCases) { mode in
                let selected = focus.baseMode == mode
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { focus.baseMode = mode }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 10, weight: .semibold))
                        Text(mode.title)
                            .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(selected ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? NotchTheme.chipFillActive : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    // MARK: Meeting companion

    private var meetingCompanion: some View {
        VStack(alignment: .leading, spacing: 8) {
            meetingContextStrip
            talkSuggestions
            notesPanel
            meetingFooter
        }
    }

    private var meetingContextStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.fill")
                .foregroundStyle(NotchTheme.caution)
                .font(.system(size: 11, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(focus.calendarMeetingTitle() ?? "Meeting companion")
                    .font(NotchTheme.caption.weight(.semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                Text(contextSubtitle)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Button { focus.duckPercent = max(10, focus.duckPercent - 5) } label: {
                    Image(systemName: "minus").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                Text("\(focus.duckPercent)%")
                    .font(NotchTheme.micro.monospacedDigit().weight(.semibold))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .frame(width: 30)
                Button { focus.duckPercent = min(40, focus.duckPercent + 5) } label: {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(NotchTheme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .help("Music duck level while in Meeting Mode")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(NotchTheme.caution.opacity(0.1))
        )
    }

    private var contextSubtitle: String {
        if let app = focus.suggestedCallApp {
            return "\(app) open · notes stay on this Mac"
        }
        return "Notetaker + talk tips · never joins the call"
    }

    private var talkSuggestions: some View {
        TalkCoachView(
            calendarTitle: focus.calendarMeetingTitle() ?? notes.session?.calendarTitle,
            callApp: focus.suggestedCallApp ?? notes.session?.callApp,
            elapsed: focus.meetingElapsed
        )
    }

    private var notesPanel: some View {
        MeetingNotesPanel()
    }

    private var meetingFooter: some View {
        HStack(spacing: 8) {
            chipButton("Copy", "doc.on.doc") { notes.copyAllToPasteboard() }
            chipButton("Save", "square.and.arrow.down") { notes.saveToFile() }
            chipButton("Clear", "trash") { notes.clearBullets() }
            Spacer(minLength: 0)
            Button {
                speech.stop()
                focus.leaveMeetingMode()
            } label: {
                Text("Leave Meeting")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.caution)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(NotchTheme.caution.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Other modes

    @ViewBuilder
    private var modeBody: some View {
        switch focus.baseMode {
        case .normal:
            tipCard(
                "circle",
                "Normal",
                "Default Dynamo. Select Meeting for notes & quiet island when you’re on a call — Dynamo never joins the meeting."
            )
            if let app = focus.suggestedCallApp {
                Button { focus.enterMeetingMode() } label: {
                    HStack {
                        Image(systemName: "video.fill")
                        Text("\(app) is open — Enter Meeting Mode")
                            .font(NotchTheme.micro.weight(.semibold))
                        Spacer()
                    }
                    .foregroundStyle(NotchTheme.caution)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(NotchTheme.caution.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        case .dynamic:
            tipCard("bolt.horizontal.circle", "Dynamic", "Peeks surface what’s next. Media stays first-class.")
            if let next = agenda.snapshot.upNext.first {
                miniRow("Up next", next.title, timeLabel(next.when))
            }
            if !focus.recentDynamicPeeks.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recent nudges")
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textQuaternary)
                    ForEach(focus.recentDynamicPeeks, id: \.self) { item in
                        Text("· \(item)")
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 4)
            }
        case .trueFocus:
            trueFocusBody
        case .meeting:
            EmptyView()
        }
    }

    private var trueFocusBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let now = agenda.snapshot.now {
                agendaRow("Now", now, NotchTheme.positive)
            }
            let upNext = agenda.snapshot.upNext
            ForEach(upNext.prefix(showAllAgenda ? upNext.count : 3)) { item in
                agendaRow(nil, item, NotchTheme.mediaGlow)
            }
            ForEach(agenda.snapshot.needsAttention.prefix(2)) { item in
                agendaRow("Due", item, NotchTheme.caution)
            }
            if upNext.count > 3 {
                Button(showAllAgenda ? "Show less" : "Show all \(upNext.count)") {
                    showAllAgenda.toggle()
                }
                .font(NotchTheme.micro)
                .foregroundStyle(NotchTheme.textTertiary)
                .buttonStyle(.plain)
            }
            if agenda.snapshot.now == nil && agenda.snapshot.upNext.isEmpty {
                tipCard("target", "No agenda yet", "Allow Calendar & Reminders to fill True Focus.")
            }
        }
    }

    private func agendaRow(_ label: String?, _ item: FocusAgendaItem, _ accent: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(accent).frame(width: 2.5, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if let label {
                        Text(label.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(accent)
                    }
                    Text(item.title)
                        .font(NotchTheme.caption.weight(.medium))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                }
                Text(item.detail)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            Spacer()
            if let when = item.when {
                Text(timeLabel(when))
                    .font(NotchTheme.micro.monospacedDigit())
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }

    private func tipCard(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.07)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(NotchTheme.caption.weight(.semibold)).foregroundStyle(NotchTheme.textPrimary)
                Text(body).font(NotchTheme.micro).foregroundStyle(NotchTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private func miniRow(_ k: String, _ v: String, _ d: String) -> some View {
        HStack {
            Text(k).font(NotchTheme.micro.weight(.semibold)).foregroundStyle(NotchTheme.textQuaternary)
            Text(v).font(NotchTheme.caption.weight(.medium)).foregroundStyle(NotchTheme.textPrimary).lineLimit(1)
            Spacer()
            Text(d).font(NotchTheme.micro).foregroundStyle(NotchTheme.textTertiary)
        }
    }

    private var footerActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                chipButton("Refresh", "arrow.clockwise") {
                    focus.reevaluateMeeting()
                    FocusAgendaEngine.shared.rebuild()
                }
                chipButton("Calendar", "calendar") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                        NSWorkspace.shared.open(url)
                    }
                }
                chipButton("Reminders", "checklist") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
            }
            Toggle(isOn: Binding(
                get: { focus.suggestMeetingOnCall },
                set: { focus.suggestMeetingOnCall = $0 }
            )) {
                Text("Suggest Meeting Mode on calls")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }

    private func chipButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(NotchTheme.micro.weight(.semibold))
            }
            .foregroundStyle(NotchTheme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func timeLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        let mins = Int(date.timeIntervalSinceNow / 60)
        if mins > 0, mins < 180 { return "in \(mins)m" }
        if mins <= 0, mins > -120 { return "now" }
        return Self.timeFormatter.string(from: date)
    }
}

// MARK: - Meeting Notes Panel

private struct MeetingNotesPanel: View {
    @ObservedObject private var notes = MeetingNotesStore.shared
    @ObservedObject private var speech = MeetingSpeechCapture.shared

    @State private var editingID: UUID? = nil
    @State private var editDraft: String = ""
    @State private var historyVisible: Bool = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            panelHeader

            if !speech.partialText.isEmpty {
                Text(speech.partialText)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .lineLimit(2)
            } else if !speech.statusMessage.isEmpty {
                Text(speech.statusMessage)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.caution.opacity(0.9))
            }

            if notes.bullets.isEmpty {
                Text("No notes yet — type below or tap Listen")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(notes.bullets.reversed()) { b in
                        bulletRow(b)
                    }
                }
            }

            draftRow

            if historyVisible {
                Divider().overlay(NotchTheme.separator).padding(.vertical, 2)
                MeetingHistoryPanel(onDismiss: { historyVisible = false })
            }
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 6) {
            Text("Notes")
                .font(NotchTheme.micro.weight(.semibold))
                .foregroundStyle(NotchTheme.textQuaternary)
            Spacer(minLength: 0)
            Button {
                historyVisible.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 8, weight: .semibold))
                    Text("History")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(historyVisible ? NotchTheme.mediaGlow : NotchTheme.textQuaternary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            Button {
                speech.toggleListen()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: speech.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 9, weight: .bold))
                    Text(speech.isListening ? "Listening" : "Listen")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(speech.isListening ? NotchTheme.positive : NotchTheme.textTertiary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(speech.isListening ? NotchTheme.positive.opacity(0.15) : Color.white.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
            .help("Free Apple Speech recognition for meeting notes")
        }
    }

    private func bulletRow(_ b: MeetingNoteBullet) -> some View {
        HStack(alignment: .center, spacing: 5) {
            // Tag chip — cycles on tap
            Button {
                let next: BulletTag?
                if let current = b.tag { next = current.next } else { next = .decision }
                notes.tagBullet(id: b.id, tag: next)
            } label: {
                if let tag = b.tag {
                    Image(systemName: tag.systemImage)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(tagColor(tag))
                        .frame(width: 14)
                } else {
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 8))
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .frame(width: 14)
                }
            }
            .buttonStyle(.plain)
            .help("Tap to tag: Decision / Action / Risk")

            // Text or inline edit field
            if editingID == b.id {
                TextField("", text: $editDraft)
                    .textFieldStyle(.plain)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textPrimary)
                    .onSubmit { commitEdit(b.id) }
                    .onExitCommand { editingID = nil }
            } else {
                Text(b.text)
                    .font(NotchTheme.micro)
                    .foregroundStyle(b.tag == nil ? NotchTheme.textSecondary : NotchTheme.textPrimary)
                    .lineLimit(2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editDraft = b.text
                        editingID = b.id
                    }
            }

            Spacer(minLength: 0)

            // Timestamp
            Text(Self.timeFmt.string(from: b.createdAt))
                .font(.system(size: 7.5).monospacedDigit())
                .foregroundStyle(NotchTheme.textQuaternary)

            // Source icon
            Image(systemName: sourceIcon(b.source))
                .font(.system(size: 7.5))
                .foregroundStyle(NotchTheme.textQuaternary)

            // Delete
            Button { notes.deleteBullet(id: b.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.plain)
            .help("Remove note")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(b.tag.map { tagColor($0).opacity(0.07) } ?? Color.white.opacity(0.03))
        )
    }

    private var draftRow: some View {
        HStack(spacing: 6) {
            TextField("Add note…", text: $notes.draft)
                .textFieldStyle(.plain)
                .font(NotchTheme.micro)
                .onSubmit { notes.submitDraft() }
            Button { notes.submitDraft() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(
                        notes.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? NotchTheme.textQuaternary
                            : NotchTheme.textPrimary
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func commitEdit(_ id: UUID) {
        notes.editBullet(id: id, text: editDraft)
        editingID = nil
    }

    private func tagColor(_ tag: BulletTag) -> Color {
        switch tag {
        case .decision: return NotchTheme.mediaGlow
        case .action:   return NotchTheme.positive
        case .risk:     return NotchTheme.caution
        }
    }

    private func sourceIcon(_ s: MeetingNoteBullet.Source) -> String {
        switch s {
        case .typed:      return "keyboard"
        case .speech:     return "mic.fill"
        case .suggestion: return "text.bubble"
        }
    }
}

// MARK: - Talk Coach View (dismissible suggestions)

private struct TalkCoachView: View {
    let calendarTitle: String?
    let callApp: String?
    let elapsed: TimeInterval
    @ObservedObject private var notes = MeetingNotesStore.shared
    @State private var dismissed: Set<String> = []
    @State private var collapsed = false

    var body: some View {
        let tips = MeetingTalkCoach.suggestions(
            calendarTitle: calendarTitle,
            callApp: callApp,
            notes: notes.bullets,
            elapsed: elapsed
        ).filter { !dismissed.contains($0.id) }

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("What to say")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { collapsed.toggle() }
                } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(NotchTheme.textQuaternary)
                }
                .buttonStyle(.plain)
            }

            if !collapsed {
                if tips.isEmpty {
                    Text("No suggestions yet — add notes to unlock more.")
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textQuaternary)
                } else {
                    ForEach(tips.prefix(3)) { tip in
                        HStack(alignment: .top, spacing: 5) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(tip.text, forType: .string)
                                notes.pinSuggestion(tip.text)
                            } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "text.bubble")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(NotchTheme.mediaGlow)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(tip.text)
                                            .font(NotchTheme.micro.weight(.medium))
                                            .foregroundStyle(NotchTheme.textPrimary)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(tip.reason + " · tap to copy & pin")
                                            .font(.system(size: 8, weight: .medium))
                                            .foregroundStyle(NotchTheme.textQuaternary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(7)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.white.opacity(0.05))
                                )
                            }
                            .buttonStyle(.plain)

                            Button { dismissed.insert(tip.id) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(NotchTheme.textQuaternary)
                            }
                            .buttonStyle(.plain)
                            .help("Dismiss suggestion")
                            .padding(.top, 9)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Meeting History Panel

private struct MeetingHistoryPanel: View {
    var onDismiss: () -> Void
    @State private var sessions: [MeetingNoteSession] = []
    @State private var expanded: UUID? = nil

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Past sessions")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                Spacer(minLength: 0)
                Button("Done") { onDismiss() }
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .buttonStyle(.plain)
            }

            if sessions.isEmpty {
                Text("No past sessions found.")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .padding(.vertical, 4)
            } else {
                ForEach(sessions.prefix(6)) { s in
                    sessionRow(s)
                }
            }
        }
        .onAppear {
            sessions = MeetingNotesStore.shared.loadPastSessions()
        }
    }

    private func sessionRow(_ s: MeetingNoteSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.calendarTitle ?? "Untitled")
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                    Text("\(Self.dateFmt.string(from: s.startedAt)) · \(s.bullets.count) note\(s.bullets.count == 1 ? "" : "s")")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(NotchTheme.textQuaternary)
                }
                Spacer(minLength: 0)
                Button { MeetingNotesStore.shared.copySession(s) } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Copy notes")
                Button { MeetingNotesStore.shared.saveSession(s) } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 9))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Save as Markdown")
                Button {
                    withAnimation(.easeOut(duration: 0.1)) {
                        expanded = expanded == s.id ? nil : s.id
                    }
                } label: {
                    Image(systemName: expanded == s.id ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(NotchTheme.textQuaternary)
                }
                .buttonStyle(.plain)
            }

            if expanded == s.id {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(s.bullets.prefix(10)) { b in
                        HStack(spacing: 5) {
                            if let tag = b.tag {
                                Image(systemName: tag.systemImage)
                                    .font(.system(size: 7.5))
                                    .foregroundStyle(tagColor(tag))
                            } else {
                                Image(systemName: "circle.dotted")
                                    .font(.system(size: 7.5))
                                    .foregroundStyle(NotchTheme.textQuaternary)
                            }
                            Text(b.text)
                                .font(.system(size: 9))
                                .foregroundStyle(NotchTheme.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(Self.timeFmt.string(from: b.createdAt))
                                .font(.system(size: 7.5).monospacedDigit())
                                .foregroundStyle(NotchTheme.textQuaternary)
                        }
                    }
                    if s.bullets.count > 10 {
                        Text("+ \(s.bullets.count - 10) more")
                            .font(.system(size: 8))
                            .foregroundStyle(NotchTheme.textQuaternary)
                    }
                }
                .padding(.leading, 6)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func tagColor(_ tag: BulletTag) -> Color {
        switch tag {
        case .decision: return NotchTheme.mediaGlow
        case .action:   return NotchTheme.positive
        case .risk:     return NotchTheme.caution
        }
    }
}
