import AppKit
import SwiftUI

@MainActor
final class ChecklistPlugin: ObservableObject, NotchWidgetPlugin, NotchSneakPeekProviding, NotchAmbientProviding, WidgetSettingsProviding {
    let id = "checklist"
    let displayName = "Notes"
    let systemImage = "checklist"

    private static let showCompletedKey = "dynamo.checklist.showCompleted"
    private static let peekOnOverdueKey = "dynamo.checklist.peekOnOverdue"

    let store = ChecklistStore() // kept for migration / offline scratch if needed
    let reminders = RemindersProvider()
    let notes = NotesProvider()
    @Published var draft: String = ""
    /// Where the draft field writes: system Reminders (default) or Apple Notes.
    @Published var draftTarget: DraftTarget = .reminders
    /// When true, completed local checklist items appear under Reminders.
    @Published var showCompleted: Bool {
        didSet { UserDefaults.standard.set(showCompleted, forKey: Self.showCompletedKey) }
    }
    /// When true, overdue reminders still fire sneak peeks.
    @Published var peekOnOverdue: Bool {
        didSet { UserDefaults.standard.set(peekOnOverdue, forKey: Self.peekOnOverdueKey) }
    }
    var onSneakPeek: ((NotchSneakPeek) -> Void)?

    init() {
        if UserDefaults.standard.object(forKey: Self.showCompletedKey) == nil {
            showCompleted = false
        } else {
            showCompleted = UserDefaults.standard.bool(forKey: Self.showCompletedKey)
        }
        if UserDefaults.standard.object(forKey: Self.peekOnOverdueKey) == nil {
            peekOnOverdue = true
        } else {
            peekOnOverdue = UserDefaults.standard.bool(forKey: Self.peekOnOverdueKey)
        }
    }

    enum DraftTarget: String, CaseIterable, Identifiable {
        case reminders
        case notes
        var id: String { rawValue }
        var label: String {
            switch self {
            case .reminders: return "Reminders"
            case .notes: return "Notes"
            }
        }
    }

    private var notifiedReminderStages: [String: Set<String>] = [:]

    var expandedContentHeight: CGFloat { 268 }

    func start() {
        store.start()
        notes.onChangeWire = { [weak self] in
            self?.objectWillChange.send()
            self?.syncFocusAgenda()
        }
        notes.start()
        reminders.onChange = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.checkDueReminders()
            self.syncFocusAgenda()
            if FocusController.shared.effective == .dynamic {
                DynamicCompanion.shared.maybePulse(
                    events: [],
                    reminders: self.reminders.items
                ) { [weak self] peek in
                    self?.onSneakPeek?(peek)
                }
            }
        }
        reminders.start()
        if reminders.authState == .notDetermined || reminders.authState == .writeOnly {
            Task { await reminders.requestAccess() }
        } else if reminders.authState == .authorized {
            reminders.refresh()
        }
    }

    private func syncFocusAgenda() {
        // Notes titles feed True Focus as open “local” items (stable synthetic UUIDs).
        let noteOpen: [(UUID, String)] = notes.items.map { note in
            let u = UUID(uuidString: String(note.id.prefix(36))) ?? UUID()
            return (u, note.title)
        }
        FocusAgendaEngine.shared.updateReminders(
            reminders.items,
            localOpen: noteOpen
        )
    }

    func stop() {
        store.stop()
        notes.stop()
        reminders.stop()
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedChecklistView(plugin: self))
    }

    func settingsView() -> AnyView {
        AnyView(ChecklistSettingsView(plugin: self))
    }

    // MARK: - Ambient

    private var overdueCount: Int { reminders.items.filter { $0.isOverdue }.count }

    var isAmbientActive: Bool { overdueCount > 0 }
    var ambientPriority: Int { 24 }

    func ambientView() -> AnyView {
        AnyView(AmbientChecklistView(count: overdueCount))
    }

    /// Due preset for new Reminders.
    enum DuePreset: String, CaseIterable, Identifiable {
        case inOneHour
        case today
        case tomorrow
        case undated

        var id: String { rawValue }

        var title: String {
            switch self {
            case .inOneHour: return "1h"
            case .today: return "Today"
            case .tomorrow: return "Tomorrow"
            case .undated: return "None"
            }
        }

        func dueDate() -> Date? {
            let cal = Calendar.current
            let now = Date()
            switch self {
            case .inOneHour:
                return cal.date(byAdding: .hour, value: 1, to: now)
            case .today:
                var comps = cal.dateComponents([.year, .month, .day], from: now)
                comps.hour = 17
                comps.minute = 0
                return cal.date(from: comps) ?? now
            case .tomorrow:
                let day = cal.date(byAdding: .day, value: 1, to: now) ?? now
                var comps = cal.dateComponents([.year, .month, .day], from: day)
                comps.hour = 9
                comps.minute = 0
                return cal.date(from: comps)
            case .undated:
                return nil
            }
        }

        var allDay: Bool {
            switch self {
            case .today, .tomorrow: return false
            case .inOneHour, .undated: return false
            }
        }
    }

    @Published var duePreset: DuePreset = .inOneHour

    func submitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch draftTarget {
        case .reminders:
            guard reminders.authState == .authorized else {
                Task { await reminders.requestAccess() }
                return
            }
            Task {
                let due = duePreset.dueDate()
                let ok = await reminders.create(
                    title: text,
                    due: due,
                    allDay: duePreset == .today || duePreset == .tomorrow ? false : false,
                    notes: nil,
                    priority: 0
                )
                if ok {
                    draft = ""
                    objectWillChange.send()
                }
            }
        case .notes:
            if !notes.isAvailable {
                notes.ensureFolder()
            }
            if notes.create(title: text) {
                draft = ""
                refreshNotes()
            } else {
                objectWillChange.send()
            }
        }
    }

    func requestRemindersAccess() {
        Task { await reminders.requestAccess() }
    }

    func connectNotes() {
        notes.ensureFolder()
        notes.refresh()
        objectWillChange.send()
    }

    func refreshReminders() {
        reminders.refresh()
    }

    func refreshNotes() {
        notes.refresh()
        objectWillChange.send()
    }

    func updateNote(_ item: NoteItem, title: String, body: String?) {
        _ = notes.update(id: item.id, title: title, body: body)
        objectWillChange.send()
    }

    func deleteNote(_ item: NoteItem) {
        _ = notes.delete(id: item.id)
        objectWillChange.send()
    }

    func openNote(_ item: NoteItem) {
        notes.open(id: item.id)
    }

    func openNotesApp() {
        notes.openApp()
    }

    func completeReminder(_ item: ReminderItem) {
        Task {
            _ = await reminders.complete(id: item.id)
            objectWillChange.send()
        }
    }

    func deleteReminder(_ item: ReminderItem) {
        Task {
            _ = await reminders.delete(id: item.id)
            objectWillChange.send()
        }
    }

    func openReminder(_ item: ReminderItem) {
        reminders.open(id: item.id)
    }

    func openRemindersApp() {
        reminders.openApp()
    }

    // MARK: - Due peeks

    private func checkDueReminders() {
        let items = reminders.items
        let liveIDs = Set(items.map(\.id))
        notifiedReminderStages = notifiedReminderStages.filter { liveIDs.contains($0.key) }

        for reminder in items {
            guard let due = reminder.due else { continue }

            if reminder.isAllDay {
                let cal = Calendar.current
                guard cal.isDateInToday(due) || reminder.isOverdue else { continue }
                if reminder.isOverdue, !peekOnOverdue { continue }
                let stage = reminder.isOverdue ? "now" : "t15"
                var seen = notifiedReminderStages[reminder.id] ?? []
                guard !seen.contains(stage) else { continue }
                seen.insert(stage)
                notifiedReminderStages[reminder.id] = seen
            onSneakPeek?(NotchSneakPeek(
                    systemImage: "checklist",
                    title: reminder.title,
                    subtitle: reminder.isOverdue ? "Overdue · all day" : "Due today",
                    urgency: reminder.isOverdue ? .critical : .high,
                    detail: reminder.listName.isEmpty ? "Reminders" : reminder.listName,
                    category: "reminder"
                ))
                continue
            }

            let interval = due.timeIntervalSinceNow
            guard interval > -12 * 60 * 60 else { continue }
            if interval < -60, !peekOnOverdue { continue }

            let stage = CalendarPeekPolicy.stage(intervalUntilStart: interval, leadMinutes: 15)
            guard let stage else { continue }

            var seen = notifiedReminderStages[reminder.id] ?? []
            guard !seen.contains(stage) else { continue }
            seen.insert(stage)
            notifiedReminderStages[reminder.id] = seen

            let urgency: NotchSneakPeekUrgency =
                stage == "now" || interval <= 0 ? .critical : .high
            onSneakPeek?(NotchSneakPeek(
                systemImage: urgency == .critical ? "checklist.checked" : "checklist",
                title: reminder.title,
                subtitle: reminderDueLabel(interval: interval),
                urgency: urgency,
                detail: reminder.listName.isEmpty ? "Reminders" : reminder.listName,
                category: "reminder"
            ))
        }
    }

    private func reminderDueLabel(interval: TimeInterval) -> String {
        if interval < -60 {
            let mins = max(1, Int((-interval / 60).rounded()))
            if mins < 60 { return "Overdue by \(mins)m" }
            let hrs = mins / 60
            return hrs == 1 ? "Overdue by 1 hour" : "Overdue by \(hrs) hours"
        }
        if interval <= 0 { return "Due now" }
        let minutes = max(1, Int((interval / 60).rounded()))
        if minutes == 1 { return "Due in 1 minute" }
        return "Due in \(minutes) minutes"
    }
}

// MARK: - Views

private struct ExpandedChecklistView: View {
    @ObservedObject var plugin: ChecklistPlugin
    @ObservedObject private var notes: NotesProvider
    @ObservedObject private var reminders: RemindersProvider
    @ObservedObject private var permissions = PermissionsStore.shared
    @State private var hoveringID: String?
    @State private var editingNoteID: String?
    @State private var editTitle: String = ""
    @State private var editBody: String = ""

    init(plugin: ChecklistPlugin) {
        self.plugin = plugin
        self._notes = ObservedObject(wrappedValue: plugin.notes)
        self._reminders = ObservedObject(wrappedValue: plugin.reminders)
    }

    private var notesCount: Int { notes.items.count }
    private var reminderCount: Int { reminders.items.count }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 8)

            segmentBar
                .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    contentForSelectedTab
                }
                .padding(.bottom, 4)
            }

            composer
                .padding(.top, 8)
                .notchAppear(delay: 0.08)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchAppear()
        .onAppear {
            // Always refresh both sources when the tab appears.
            plugin.refreshReminders()
            plugin.refreshNotes()
            if reminders.authState == .notDetermined {
                plugin.requestRemindersAccess()
            } else if reminders.authState == .authorized {
                plugin.refreshReminders()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Notes & Reminders")
                    .font(NotchTheme.section)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.7)
                Text(headerSubtitle)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            Button {
                plugin.refreshReminders()
                plugin.refreshNotes()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            .buttonStyle(.notchIcon(diameter: 22))
            .help("Refresh Notes & Reminders")

            Button {
                switch plugin.draftTarget {
                case .reminders: plugin.openRemindersApp()
                case .notes: plugin.openNotesApp()
                }
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            .buttonStyle(.notchIcon(diameter: 22))
            .help(plugin.draftTarget == .reminders ? "Open Reminders" : "Open Notes")
        }
    }

    private var headerSubtitle: String {
        switch plugin.draftTarget {
        case .reminders:
            if reminders.authState != .authorized { return "Connect Apple Reminders" }
            if reminderCount == 0 { return "No open reminders" }
            return reminderCount == 1 ? "1 open reminder" : "\(reminderCount) open reminders"
        case .notes:
            if !notes.isAvailable {
                return permissions.status(for: .automationNotes) == .denied
                    ? "Notes access is off"
                    : "Connect Apple Notes"
            }
            if notesCount == 0 { return "Apple Notes · Dynamo folder" }
            return notesCount == 1 ? "1 note" : "\(notesCount) notes"
        }
    }

    // MARK: Segment control

    private var segmentBar: some View {
        HStack(spacing: 0) {
            ForEach(ChecklistPlugin.DraftTarget.allCases) { target in
                let selected = plugin.draftTarget == target
                let count: Int = {
                    switch target {
                    case .reminders: return reminders.authState == .authorized ? reminderCount : 0
                    case .notes: return notes.isAvailable ? notesCount : 0
                    }
                }()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        plugin.draftTarget = target
                        plugin.refreshReminders()
                        plugin.refreshNotes()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: target == .reminders ? "checklist" : "note.text")
                            .font(.system(size: 9, weight: .semibold))
                        Text(target.label)
                            .font(NotchTheme.micro.weight(.semibold))
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 9, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(selected ? NotchTheme.textPrimary : NotchTheme.textQuaternary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(selected ? Color.white.opacity(0.14) : Color.white.opacity(0.06))
                                )
                        }
                    }
                    .foregroundStyle(selected ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? NotchTheme.chipFillActive : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    // MARK: Content

    @ViewBuilder
    private var contentForSelectedTab: some View {
        switch plugin.draftTarget {
        case .reminders:
            remindersContent
        case .notes:
            notesContent
        }
    }

    @ViewBuilder
    private var remindersContent: some View {
        switch reminders.authState {
        case .notDetermined:
            accessCard(
                icon: "checklist",
                title: "Connect Reminders",
                body: "List, create, complete, and delete reminders from the notch.",
                primary: "Allow Access",
                primaryAction: { plugin.requestRemindersAccess() }
            )
        case .denied:
            accessCard(
                icon: "lock.fill",
                title: "Access turned off",
                body: "Enable Full Access for Dynamo in System Settings.",
                primary: "Open Settings",
                primaryAction: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                        NSWorkspace.shared.open(url)
                    }
                },
                secondary: "Retry",
                secondaryAction: { plugin.requestRemindersAccess() }
            )
        case .writeOnly:
            accessCard(
                icon: "pencil.slash",
                title: "Full access needed",
                body: "Write-only can’t list your reminders. Grant Full Access so Dynamo can show and complete them.",
                primary: "Open Settings",
                primaryAction: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                        NSWorkspace.shared.open(url)
                    }
                },
                secondary: "Retry",
                secondaryAction: { plugin.requestRemindersAccess() }
            )
        case .authorized:
            if let err = reminders.lastError {
                errorBanner(err)
            }
            if reminders.items.isEmpty {
                emptyStrip(
                    icon: "sparkles",
                    title: "No open reminders",
                    caption: "Type below and hit ↑ — saves to Apple Reminders."
                )
            } else {
                ForEach(Array(reminders.items.enumerated()), id: \.element.id) { index, item in
                    reminderRow(item)
                        .notchAppear(delay: Double(min(index, 8)) * 0.028)
                }
            }
            if plugin.showCompleted {
                let done = plugin.store.items.filter(\.isDone)
                if !done.isEmpty {
                    Text("Completed")
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .padding(.top, 8)
                    ForEach(done) { item in
                        localCompletedRow(item)
                    }
                }
            }
        }
    }

    private func localCompletedRow(_ item: ChecklistItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NotchTheme.positive.opacity(0.85))
            Text(item.text)
                .font(NotchTheme.body)
                .foregroundStyle(NotchTheme.textTertiary)
                .strikethrough()
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                plugin.store.remove(id: item.id)
                plugin.objectWillChange.send()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var notesContent: some View {
        if !notes.isAvailable {
            if permissions.status(for: .automationNotes) == .denied {
                accessCard(
                    icon: "note.text",
                    title: "Notes access is off",
                    body: "Dynamo was denied permission to automate Notes. Turn it on in System Settings → Privacy & Security → Automation.",
                    primary: "Open Settings",
                    primaryAction: { permissions.openSystemSettings(for: .automationNotes) },
                    secondary: "Open Notes",
                    secondaryAction: { plugin.openNotesApp() }
                )
            } else {
                accessCard(
                    icon: "note.text",
                    title: "Connect Apple Notes",
                    body: "Allow Automation so Dynamo can read and write notes in the “Dynamo” folder in Notes.",
                    primary: "Connect Notes",
                    primaryAction: { plugin.connectNotes() },
                    secondary: "Open Notes",
                    secondaryAction: { plugin.openNotesApp() }
                )
            }
        } else if notes.items.isEmpty {
            if let err = notes.lastError {
                errorBanner(err)
            }
            emptyStrip(
                icon: "pencil.and.outline",
                title: "No notes yet",
                caption: "Type below — saved to Apple Notes → Dynamo folder."
            )
        } else {
            if let err = notes.lastError {
                errorBanner(err)
            }
            ForEach(Array(notes.items.enumerated()), id: \.element.id) { index, item in
                noteRow(item)
                    .notchAppear(delay: Double(min(index, 8)) * 0.028)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.caution)
            Text(message)
                .font(NotchTheme.micro.weight(.medium))
                .foregroundStyle(NotchTheme.caution)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(NotchTheme.caution.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(NotchTheme.caution.opacity(0.25), lineWidth: 0.5)
                )
        )
    }

    private func accessCard(
        icon: String,
        title: String,
        body: String,
        primary: String,
        primaryAction: @escaping () -> Void,
        secondary: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(NotchTheme.caption.weight(.semibold))
                        .foregroundStyle(NotchTheme.textPrimary)
                    Text(body)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button(action: primaryAction) {
                    Text(primary)
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(NotchTheme.chipFillActive)
                        )
                }
                .buttonStyle(.plain)
                if let secondary, let secondaryAction {
                    Button(action: secondaryAction) {
                        Text(secondary)
                            .font(NotchTheme.micro.weight(.medium))
                            .foregroundStyle(NotchTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private func emptyStrip(icon: String, title: String, caption: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NotchTheme.textQuaternary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.05)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(NotchTheme.caption.weight(.medium))
                    .foregroundStyle(NotchTheme.textSecondary)
                Text(caption)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    // MARK: Rows

    private func reminderRow(_ item: ReminderItem) -> some View {
        let phase = item.phase()
        let accent = listAccent(for: item)
        let rowID = "r:\(item.id)"
        let hovering = hoveringID == rowID

        return HStack(alignment: .center, spacing: 10) {
            // Complete
            Button {
                plugin.completeReminder(item)
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(accent.opacity(0.85), lineWidth: 1.4)
                        .frame(width: 16, height: 16)
                    if item.isHighPriority {
                        Circle()
                            .fill(NotchTheme.caution)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Mark complete")

            // Title + meta
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(NotchTheme.body.weight(.medium))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                    if phase == .overdue || phase == .dueNow || phase == .soon {
                        phaseDot(phase)
                    }
                }
                Text(reminderSubtitle(item))
                    .font(NotchTheme.micro)
                    .foregroundStyle(
                        item.isOverdue ? NotchTheme.caution.opacity(0.95) : NotchTheme.textQuaternary
                    )
                    .lineLimit(1)
                if let notes = item.notes, !notes.isEmpty {
                    Text(notes)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textQuaternary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Delete — soft reveal on hover
            Button {
                plugin.deleteReminder(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(hovering ? 0.1 : 0)))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Delete")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.07 : 0.035))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(accent)
                        .frame(width: 2.5)
                        .padding(.vertical, 8)
                        .padding(.leading, 2)
                }
        )
        .contentShape(Rectangle())
        .onHover { hoveringID = $0 ? rowID : (hoveringID == rowID ? nil : hoveringID) }
        .onTapGesture { plugin.openReminder(item) }
        .contextMenu {
            Button("Mark Complete") { plugin.completeReminder(item) }
            Button("Open in Reminders") { plugin.openReminder(item) }
            Divider()
            Button("Delete", role: .destructive) { plugin.deleteReminder(item) }
        }
    }

    private func noteRow(_ item: NoteItem) -> some View {
        let rowID = "n:\(item.id)"
        let hovering = hoveringID == rowID

        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "note.text")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(NotchTheme.calmGlow)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                if editingNoteID == item.id {
                    TextField("Title", text: $editTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(NotchTheme.body)
                        .onSubmit { saveNoteEdit(item) }
                    TextField("Body", text: $editBody)
                        .textFieldStyle(.roundedBorder)
                        .font(NotchTheme.micro)
                        .onSubmit { saveNoteEdit(item) }
                    HStack {
                        Button("Save") { saveNoteEdit(item) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        Button("Cancel") { editingNoteID = nil }
                            .buttonStyle(.plain)
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textTertiary)
                    }
                } else {
                    Text(item.title)
                        .font(NotchTheme.body.weight(.medium))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                    if !item.bodyPreview.isEmpty {
                        Text(item.bodyPreview)
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textQuaternary)
                            .lineLimit(1)
                    } else {
                        Text("Notes · \(item.folderName)")
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textQuaternary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard editingNoteID != item.id else { return }
                editTitle = item.title
                editBody = item.bodyPreview
                editingNoteID = item.id
            }

            Button {
                plugin.deleteNote(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(hovering ? 0.1 : 0)))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Delete from Notes")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.07 : 0.035))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(NotchTheme.calmGlow.opacity(0.85))
                        .frame(width: 2.5)
                        .padding(.vertical, 8)
                        .padding(.leading, 2)
                }
        )
        .contentShape(Rectangle())
        .onHover { hoveringID = $0 ? rowID : (hoveringID == rowID ? nil : hoveringID) }
        .onTapGesture(count: 2) { plugin.openNote(item) }
        .contextMenu {
            Button("Open in Notes") { plugin.openNote(item) }
            Button("Edit") {
                editTitle = item.title
                editBody = item.bodyPreview
                editingNoteID = item.id
            }
            Divider()
            Button("Delete", role: .destructive) { plugin.deleteNote(item) }
        }
    }

    private func saveNoteEdit(_ item: NoteItem) {
        plugin.updateNote(item, title: editTitle, body: editBody)
        editingNoteID = nil
    }

    @ViewBuilder
    private func phaseDot(_ phase: ReminderItem.Phase) -> some View {
        let color: Color = {
            switch phase {
            case .overdue: return NotchTheme.negative
            case .dueNow: return NotchTheme.positive
            case .soon: return NotchTheme.caution
            default: return NotchTheme.textQuaternary
            }
        }()
        let label: String = {
            switch phase {
            case .overdue: return "Overdue"
            case .dueNow: return "Due"
            case .soon: return "Soon"
            default: return ""
            }
        }()
        if !label.isEmpty {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule(style: .continuous).fill(color.opacity(0.15)))
        }
    }

    private func listAccent(for item: ReminderItem) -> Color {
        if item.isOverdue { return NotchTheme.caution }
        if let c = item.listColor {
            return Color(red: c.red, green: c.green, blue: c.blue, opacity: max(0.55, c.alpha))
        }
        return NotchTheme.mediaGlow.opacity(0.9)
    }

    private func reminderSubtitle(_ item: ReminderItem) -> String {
        let time: String
        if let due = item.due {
            let cal = Calendar.current
            if item.isAllDay {
                if cal.isDateInToday(due) { time = "All day" }
                else if cal.isDateInTomorrow(due) { time = "Tomorrow" }
                else { time = Self.dayFormatter.string(from: due) }
            } else if cal.isDateInToday(due) {
                time = Self.timeFormatter.string(from: due)
            } else if cal.isDateInTomorrow(due) {
                time = "Tomorrow \(Self.timeFormatter.string(from: due))"
            } else {
                time = "\(Self.dayFormatter.string(from: due)) · \(Self.timeFormatter.string(from: due))"
            }
        } else {
            time = "No date"
        }
        let list = item.listName.isEmpty ? "Reminders" : item.listName
        return "\(time)  ·  \(list)"
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: plugin.draftTarget == .reminders ? "plus" : "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .frame(width: 16)

                TextField(
                    plugin.draftTarget == .reminders ? "Add to Reminders…" : "Add to Notes…",
                    text: Binding(
                        get: { plugin.draft },
                        set: { plugin.draft = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .font(NotchTheme.body)
                .foregroundStyle(NotchTheme.textPrimary)
                .onSubmit { plugin.submitDraft() }

                let canSubmit = !plugin.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button {
                    plugin.submitDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(canSubmit ? NotchTheme.textPrimary : NotchTheme.textQuaternary)
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .help(plugin.draftTarget == .reminders ? "Add to Reminders" : "Add to Apple Notes")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
            )

            if plugin.draftTarget == .reminders {
                HStack(spacing: 5) {
                    Text("Due")
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textQuaternary)
                    ForEach(ChecklistPlugin.DuePreset.allCases) { preset in
                        Button {
                            plugin.duePreset = preset
                        } label: {
                            NotchChipLabel(title: preset.title, active: plugin.duePreset == preset)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }

            if plugin.draftTarget == .reminders, reminders.authState != .authorized {
                Text(reminders.authState == .denied
                     ? "Reminders access is off — tap Allow Access or Open Settings above."
                     : reminders.authState == .writeOnly
                     ? "Full Reminders access is required to list items."
                     : "Allow Reminders access to save here.")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.caution.opacity(0.9))
            }

            if plugin.draftTarget == .notes, !notes.isAvailable {
                Text(permissions.status(for: .automationNotes) == .denied
                     ? "Notes access is off — open Settings from the tab above."
                     : "Allow Automation for Notes when prompted (System Settings → Privacy → Automation).")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.caution.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = reminders.lastError, plugin.draftTarget == .reminders {
                Text(err)
                    .font(NotchTheme.micro.weight(.medium))
                    .foregroundStyle(NotchTheme.negative)
                    .lineLimit(3)
            }
            if let err = notes.lastError, plugin.draftTarget == .notes, notes.isAvailable {
                Text(err)
                    .font(NotchTheme.micro.weight(.medium))
                    .foregroundStyle(NotchTheme.negative)
                    .lineLimit(3)
            }
        }
    }
}

private struct AmbientChecklistView: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Label(
                count == 1 ? "1 overdue" : "\(count) overdue",
                systemImage: "exclamationmark.circle.fill"
            )
            .font(NotchTheme.micro.weight(.semibold))
            .foregroundStyle(NotchTheme.caution)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchTheme.ambientInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Settings

private struct ChecklistSettingsView: View {
    @ObservedObject var plugin: ChecklistPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show completed local items", isOn: $plugin.showCompleted)
            Text("Lists finished items from Dynamo’s local checklist under Reminders.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Peek on overdue", isOn: $plugin.peekOnOverdue)
            Text("When off, overdue reminders stay in the list but won’t interrupt with a Peek.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
