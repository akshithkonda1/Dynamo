import AppKit
import Combine
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
        if f.baseMode == .dynamic, !DynamicPrioritiesStore.shared.priorities.isEmpty { return true }
        if f.baseMode == .trueFocus, FocusAgendaEngine.shared.snapshot.now != nil { return true }
        if f.baseMode == .trueFocus, FocusTimerStore.shared.isRunning { return true }
        return false
    }

    var ambientPriority: Int {
        if FocusController.shared.isMeetingActive { return 88 }
        if FocusController.shared.baseMode == .trueFocus,
           FocusAgendaEngine.shared.snapshot.now != nil { return 70 }
        if FocusController.shared.baseMode == .trueFocus,
           FocusTimerStore.shared.isRunning { return 72 }
        if FocusController.shared.baseMode == .dynamic { return 35 }
        return 0
    }

    func start() {
        FocusController.shared.start()
        FocusTimerStore.shared.onComplete = {
            let suppressed = FocusController.shared.distractionLog.count
            let subtitle = suppressed > 0
                ? "Take a break · \(suppressed) distraction\(suppressed == 1 ? "" : "s") blocked"
                : "Take a break · you earned it"
            FocusController.shared.emitPeek?(NotchSneakPeek(
                systemImage: "checkmark.circle.fill",
                title: "Focus block complete",
                subtitle: subtitle,
                urgency: .high,
                detail: "True Focus"
            ))
        }
        FocusTimerStore.shared.onPomodoroTransition = { phase in
            let peek: NotchSneakPeek
            switch phase {
            case .shortBreak:
                peek = NotchSneakPeek(systemImage: "cup.and.saucer", title: "Short break", subtitle: "5 minutes · step away", urgency: .normal, detail: "Pomodoro")
            case .longBreak:
                peek = NotchSneakPeek(systemImage: "figure.walk", title: "Long break", subtitle: "15 minutes · great work!", urgency: .high, detail: "Pomodoro")
            case .work:
                peek = NotchSneakPeek(systemImage: "timer", title: "Back to work", subtitle: "New Pomodoro block starting", urgency: .normal, detail: "Pomodoro")
            }
            FocusController.shared.emitPeek?(peek)
        }
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
    @ObservedObject private var focusTimer = FocusTimerStore.shared
    @ObservedObject private var top3 = DynamicPrioritiesStore.shared

    /// Cycles 0…N-1 for Dynamic ambient rotation (increments on a 5-second timer).
    @State private var cycleIndex: Int = 0
    private let cycleTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            if focus.isMeetingActive {
                meetingAmbient
            } else if focusTimer.isRunning {
                timerAmbient
            } else if focus.baseMode == .dynamic {
                dynamicAmbient
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
        .onReceive(cycleTimer) { _ in
            let count = top3.priorities.count
            guard count > 1 else { return }
            cycleIndex = (cycleIndex + 1) % count
        }
    }

    private var meetingAmbient: some View {
        Group {
            Image(systemName: "video.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchTheme.caution)
            Text("Meeting")
                .font(NotchTheme.micro.weight(.semibold))
                .foregroundStyle(NotchTheme.textPrimary)
            if let end = focus.calendarMeetingEnd(), end > Date() {
                let left = max(1, Int(end.timeIntervalSince(Date()) / 60))
                Text("\(left)m left")
                    .font(NotchTheme.micro.monospacedDigit())
                    .foregroundStyle(NotchTheme.textTertiary)
            } else if let app = focus.suggestedCallApp {
                Text(app)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var timerAmbient: some View {
        Group {
            Image(systemName: focusTimer.isPomodoroMode ? focusTimer.pomodoroPhase.systemImage : "timer")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchTheme.positive)
            Text(focusTimer.formattedRemaining)
                .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                .foregroundStyle(NotchTheme.textPrimary)
            if focusTimer.isPomodoroMode {
                Text(focusTimer.pomodoroPhase.label)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                if focusTimer.completedCycles > 0 {
                    Text("×\(focusTimer.completedCycles)")
                        .font(NotchTheme.micro.monospacedDigit())
                        .foregroundStyle(NotchTheme.textQuaternary)
                }
            } else {
                Text("Focus block")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var dynamicAmbient: some View {
        let items = top3.priorities.filter { !$0.isDone }
        if let item = items.isEmpty ? nil : items[min(cycleIndex, items.count - 1)] {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchTheme.mediaGlow)
            Text(item.text)
                .font(NotchTheme.micro.weight(.semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
                .transition(.opacity)
                .id(item.id)
        }
    }
}

// MARK: - Expanded

private struct ExpandedFocusView: View {
    @ObservedObject private var focus = FocusController.shared
    @ObservedObject private var agenda = FocusAgendaEngine.shared
    @ObservedObject private var notes = MeetingNotesStore.shared
    @ObservedObject private var speech = MeetingSpeechCapture.shared
    @ObservedObject private var volume = SystemVolumeController.shared
    @ObservedObject private var focusTimer = FocusTimerStore.shared
    @ObservedObject private var top3 = DynamicPrioritiesStore.shared

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
                focusFooter.padding(.top, 6)
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
        case .trueFocus:
            if focusTimer.isRunning { return "Block · \(focusTimer.formattedRemaining) remaining" }
            return "Agenda from Calendar & Reminders"
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

    // MARK: - Meeting companion

    private var meetingCompanion: some View {
        VStack(alignment: .leading, spacing: 8) {
            meetingContextStrip
            agendaStripCard
            talkSuggestions
            actionItemsSection
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
                HStack(spacing: 5) {
                    Text(focus.calendarMeetingTitle() ?? "Meeting companion")
                        .font(NotchTheme.caption.weight(.semibold))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                    if let end = focus.calendarMeetingEnd(), end > Date() {
                        let mins = max(1, Int(end.timeIntervalSince(Date()) / 60))
                        Text("\(mins)m left")
                            .font(NotchTheme.micro.monospacedDigit())
                            .foregroundStyle(mins <= 5 ? NotchTheme.caution : NotchTheme.textTertiary)
                    }
                }
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

    // MARK: Agenda strip (event notes + attendees)

    @ViewBuilder
    private var agendaStripCard: some View {
        let eventNotes = focus.calendarMeetingNotes()
        let attendees = focus.calendarMeetingAttendees()
        if eventNotes != nil || !attendees.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                if let notes = eventNotes {
                    Text(notes)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textSecondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !attendees.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            Image(systemName: "person.2")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(NotchTheme.textQuaternary)
                            ForEach(attendees.prefix(6), id: \.self) { name in
                                Button {
                                    notes.draft = "@\(name.components(separatedBy: " ").first ?? name): "
                                } label: {
                                    Text(name.components(separatedBy: " ").first ?? name)
                                        .font(NotchTheme.micro)
                                        .foregroundStyle(NotchTheme.textSecondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.white.opacity(0.07)))
                                }
                                .buttonStyle(.plain)
                                .help("Mention \(name) in notes")
                            }
                            if attendees.count > 6 {
                                Text("+\(attendees.count - 6)")
                                    .font(NotchTheme.micro)
                                    .foregroundStyle(NotchTheme.textQuaternary)
                            }
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
    }

    // MARK: Talk suggestions

    private var talkSuggestions: some View {
        TalkCoachView(
            calendarTitle: focus.calendarMeetingTitle() ?? notes.session?.calendarTitle,
            callApp: focus.suggestedCallApp ?? notes.session?.callApp,
            elapsed: focus.meetingElapsed
        )
    }

    // MARK: Action item extraction

    @ViewBuilder
    private var actionItemsSection: some View {
        let actions = MeetingActionExtractor.extract(from: notes.bullets)
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Action items")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                ForEach(actions) { bullet in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(NotchTheme.positive)
                        Text(bullet.text)
                            .font(NotchTheme.micro.weight(.medium))
                            .foregroundStyle(NotchTheme.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(NotchTheme.positive.opacity(0.08))
                    )
                }
            }
        }
    }

    // MARK: Notes panel

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

    // MARK: - Other modes

    @ViewBuilder
    private var modeBody: some View {
        switch focus.baseMode {
        case .normal:
            tipCard(
                "circle",
                "Normal",
                "Default Dynamo. Select Meeting for notes & quiet island when you're on a call — Dynamo never joins the meeting."
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
            dynamicBody
        case .trueFocus:
            trueFocusBody
        case .meeting:
            EmptyView()
        }
    }

    // MARK: Dynamic — Today's Top 3

    private var dynamicBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            top3Section
            tipCard("bolt.horizontal.circle", "Dynamic", "Peeks surface what's next. Media stays first-class.")
            if let next = agenda.snapshot.upNext.first {
                miniRow("Up next", next.title, timeLabel(next.when))
            }
        }
    }

    private var top3Section: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Today's focus")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                Spacer(minLength: 0)
                if !top3.priorities.isEmpty {
                    Text("\(top3.priorities.filter(\.isDone).count)/\(top3.priorities.count)")
                        .font(NotchTheme.micro.monospacedDigit())
                        .foregroundStyle(NotchTheme.textQuaternary)
                }
            }

            ForEach(top3.priorities) { p in
                HStack(spacing: 7) {
                    Button { top3.toggle(p.id) } label: {
                        Image(systemName: p.isDone ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(p.isDone ? NotchTheme.positive : NotchTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    Text(p.text)
                        .font(NotchTheme.micro.weight(.medium))
                        .foregroundStyle(p.isDone ? NotchTheme.textQuaternary : NotchTheme.textPrimary)
                        .strikethrough(p.isDone, color: NotchTheme.textQuaternary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button { top3.remove(p.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(NotchTheme.textQuaternary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
            }

            if top3.priorities.count < 3 {
                HStack(spacing: 6) {
                    TextField("Add priority…", text: $top3.draft)
                        .textFieldStyle(.plain)
                        .font(NotchTheme.micro)
                        .onSubmit { top3.submitDraft() }
                    Button { top3.submitDraft() } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(
                                top3.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? NotchTheme.textQuaternary
                                    : NotchTheme.textPrimary
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
            }
        }
    }

    // MARK: True Focus — agenda + timer

    private var trueFocusBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if focusTimer.isRunning {
                timerProgressCard
            }
            if let now = agenda.snapshot.now {
                agendaRow("Now", now, NotchTheme.positive)
            }
            ForEach(agenda.snapshot.upNext.prefix(3)) { item in
                agendaRow(nil, item, NotchTheme.mediaGlow)
            }
            ForEach(agenda.snapshot.needsAttention.prefix(2)) { item in
                agendaRow("Due", item, NotchTheme.caution)
            }
            if agenda.snapshot.now == nil && agenda.snapshot.upNext.isEmpty && !focusTimer.isRunning {
                tipCard("target", "No agenda yet", "Allow Calendar & Reminders to fill True Focus.")
            }
            distractionLogSection
        }
    }

    @ViewBuilder
    private var distractionLogSection: some View {
        if !focus.distractionLog.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Blocked")
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textQuaternary)
                    Text("\(focus.distractionLog.count)")
                        .font(NotchTheme.micro.monospacedDigit())
                        .foregroundStyle(NotchTheme.textQuaternary)
                    Spacer(minLength: 0)
                    Button { focus.clearDistractionLog() } label: {
                        Text("Clear")
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textQuaternary)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(focus.distractionLog.prefix(3)) { entry in
                    HStack(spacing: 5) {
                        Image(systemName: "hand.raised")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(NotchTheme.textQuaternary)
                        Text(entry.title)
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textQuaternary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var timerProgressCard: some View {
        let phaseColor: Color = {
            guard focusTimer.isPomodoroMode else { return NotchTheme.positive }
            switch focusTimer.pomodoroPhase {
            case .work: return NotchTheme.positive
            case .shortBreak: return NotchTheme.mediaGlow
            case .longBreak: return NotchTheme.caution
            }
        }()
        return HStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: focusTimer.progressFraction)
                    .stroke(phaseColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if focusTimer.isPomodoroMode {
                    Image(systemName: focusTimer.pomodoroPhase.systemImage)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(phaseColor)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(focusTimer.formattedRemaining)
                    .font(NotchTheme.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(NotchTheme.textPrimary)
                HStack(spacing: 4) {
                    Text(focusTimer.isPomodoroMode ? focusTimer.pomodoroPhase.label : "Focus block")
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                    if focusTimer.isPomodoroMode && focusTimer.completedCycles > 0 {
                        Text("·")
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textQuaternary)
                        Text("\(focusTimer.completedCycles) done")
                            .font(NotchTheme.micro.monospacedDigit())
                            .foregroundStyle(NotchTheme.textQuaternary)
                    }
                }
            }
            Spacer(minLength: 0)
            Button { focusTimer.cancel() } label: {
                Text("Cancel")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(phaseColor.opacity(0.08))
        )
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

    // MARK: - Footer

    private var focusFooter: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if focus.baseMode == .trueFocus {
                    trueFocusTimerButtons
                } else {
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
                }
                Spacer()
            }
            if focus.baseMode == .trueFocus || focus.baseMode == .meeting {
                breakNudgeRow
            }
            if focus.baseMode == .trueFocus {
                dndSyncRow
            }
        }
    }

    private var breakNudgeRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "figure.stand")
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textQuaternary)
            Text("Break every")
                .font(NotchTheme.micro)
                .foregroundStyle(NotchTheme.textQuaternary)
            Button { if focus.breakNudgeMinutes > 5 { focus.breakNudgeMinutes -= 5 } } label: {
                Image(systemName: "minus").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(NotchTheme.textQuaternary)
            Text("\(focus.breakNudgeMinutes)m")
                .font(NotchTheme.micro.monospacedDigit().weight(.semibold))
                .foregroundStyle(NotchTheme.textTertiary)
                .frame(minWidth: 28)
            Button { if focus.breakNudgeMinutes < 90 { focus.breakNudgeMinutes += 5 } } label: {
                Image(systemName: "plus").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(NotchTheme.textQuaternary)
            Spacer(minLength: 0)
        }
    }

    private var dndSyncRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.fill")
                .font(.system(size: 9))
                .foregroundStyle(focus.dndSyncEnabled ? NotchTheme.mediaGlow : NotchTheme.textQuaternary)
            Button {
                focus.dndSyncEnabled.toggle()
            } label: {
                Text(focus.dndSyncEnabled ? "DND → True Focus: on" : "Sync macOS DND")
                    .font(NotchTheme.micro)
                    .foregroundStyle(focus.dndSyncEnabled ? NotchTheme.mediaGlow : NotchTheme.textQuaternary)
            }
            .buttonStyle(.plain)
            .help("When macOS Do Not Disturb is on, automatically enter True Focus mode")
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var trueFocusTimerButtons: some View {
        if focusTimer.isRunning {
            chipButton("Cancel", "xmark.circle") { focusTimer.cancel() }
        } else {
            chipButton("25 min", "timer") { focusTimer.start(minutes: 25) }
            chipButton("50 min", "timer") { focusTimer.start(minutes: 50) }
            chipButton("Pomodoro", "cup.and.saucer") { focusTimer.startPomodoro() }
            chipButton("Refresh", "arrow.clockwise") {
                focus.reevaluateMeeting()
                FocusAgendaEngine.shared.rebuild()
            }
        }
    }

    // MARK: - Helpers

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
