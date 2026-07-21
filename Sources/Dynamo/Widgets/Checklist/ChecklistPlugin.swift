import AppKit
import SwiftUI

@MainActor
final class ChecklistPlugin: ObservableObject, NotchWidgetPlugin, NotchSneakPeekProviding {
    let id = "checklist"
    let displayName = "Checklist"
    let systemImage = "checklist"

    let store = ChecklistStore()
    let reminders = RemindersProvider()
    @Published var draft: String = ""
    /// Where the draft field writes: system Reminders (default) or local JSON list.
    @Published var draftTarget: DraftTarget = .reminders
    var onSneakPeek: ((NotchSneakPeek) -> Void)?

    enum DraftTarget: String, CaseIterable, Identifiable {
        case reminders
        case local
        var id: String { rawValue }
        var label: String {
            switch self {
            case .reminders: return "Reminders"
            case .local: return "Local"
            }
        }
    }

    private var notifiedReminderStages: [String: Set<String>] = [:]
    private let leadTime: TimeInterval = 15 * 60

    var expandedContentHeight: CGFloat { 255 }

    func start() {
        store.start()
        reminders.onChange = { [weak self] in
            self?.objectWillChange.send()
            self?.checkDueReminders()
        }
        reminders.start()
        if reminders.authState == .notDetermined {
            Task { await reminders.requestAccess() }
        } else if reminders.authState == .authorized {
            reminders.refresh()
        }
    }

    func stop() {
        store.stop()
        reminders.stop()
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedChecklistView(plugin: self))
    }

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
                // Default: due today end-of-business-ish (next hour rounded) for timed, or today.
                let due = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
                let ok = await reminders.create(title: text, due: due, allDay: false)
                if ok {
                    draft = ""
                    objectWillChange.send()
                }
            }
        case .local:
            store.add(text: text)
            draft = ""
        }
    }

    func requestRemindersAccess() {
        Task { await reminders.requestAccess() }
    }

    func refreshReminders() {
        reminders.refresh()
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
                    detail: reminder.listName.isEmpty ? "Reminders" : reminder.listName
                ))
                continue
            }

            let interval = due.timeIntervalSinceNow
            guard interval <= leadTime, interval > -12 * 60 * 60 else { continue }

            let stage: String
            if interval <= 45 { stage = "now" }
            else if interval <= 5 * 60 + 20 { stage = "t5" }
            else { stage = "t15" }

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
                detail: reminder.listName.isEmpty ? "Reminders" : reminder.listName
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
    @ObservedObject private var store: ChecklistStore
    @ObservedObject private var reminders: RemindersProvider

    init(plugin: ChecklistPlugin) {
        self.plugin = plugin
        self._store = ObservedObject(wrappedValue: plugin.store)
        self._reminders = ObservedObject(wrappedValue: plugin.reminders)
    }

    private var doneCount: Int { store.items.filter(\.isDone).count }
    private var totalCount: Int { store.items.count }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
                    remindersSection
                    localSection
                }
            }

            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack {
            NotchSectionHeader(
                "Checklist",
                trailing: totalCount > 0
                    ? AnyView(
                        Text("\(doneCount)/\(totalCount) local")
                            .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                            .foregroundStyle(NotchTheme.textTertiary)
                    )
                    : nil
            )
            Spacer(minLength: 0)
            if reminders.authState == .authorized {
                Button {
                    plugin.refreshReminders()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
                .buttonStyle(.notchIcon(diameter: 22))
                .help("Refresh Reminders")

                Button {
                    plugin.openRemindersApp()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
                .buttonStyle(.notchIcon(diameter: 22))
                .help("Open Reminders app")
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Target picker: system Reminders vs local-only list.
            HStack(spacing: 6) {
                ForEach(ChecklistPlugin.DraftTarget.allCases) { target in
                    let selected = plugin.draftTarget == target
                    Button {
                        plugin.draftTarget = target
                    } label: {
                        Text(target.label)
                            .font(NotchTheme.micro.weight(selected ? .semibold : .medium))
                            .foregroundStyle(selected ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selected ? NotchTheme.chipFillActive : NotchTheme.chipFill)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if plugin.draftTarget == .reminders, reminders.authState != .authorized {
                    Text(reminders.authState == .denied ? "No access" : "Needs access")
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.caution)
                }
            }

            HStack(spacing: 8) {
                TextField(
                    plugin.draftTarget == .reminders ? "New reminder…" : "New local item…",
                    text: Binding(
                        get: { plugin.draft },
                        set: { plugin.draft = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { plugin.submitDraft() }

                Button {
                    plugin.submitDraft()
                } label: {
                    Image(systemName: plugin.draftTarget == .reminders
                          ? "plus.circle.fill"
                          : "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(NotchTheme.textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(plugin.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(plugin.draftTarget == .reminders
                      ? "Add to Apple Reminders"
                      : "Add to local list")
            }

            if let err = reminders.lastError, plugin.draftTarget == .reminders {
                Text(err)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.negative)
                    .lineLimit(2)
            }
        }
    }

    // MARK: Reminders

    @ViewBuilder
    private var remindersSection: some View {
        HStack(spacing: 6) {
            Text("Reminders")
                .font(NotchTheme.micro.weight(.semibold))
                .foregroundStyle(NotchTheme.textQuaternary)
            if reminders.authState == .authorized, !reminders.items.isEmpty {
                Text("\(reminders.items.count)")
                    .font(NotchTheme.micro.monospacedDigit())
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            Spacer(minLength: 0)
        }

        switch reminders.authState {
        case .notDetermined:
            VStack(alignment: .leading, spacing: 4) {
                Text("Allow full access so Dynamo can list, create, complete, and delete reminders.")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow Reminders Access") {
                    plugin.requestRemindersAccess()
                }
                .font(NotchTheme.micro.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(NotchTheme.textPrimary)
            }
        case .denied:
            VStack(alignment: .leading, spacing: 4) {
                Text("Reminders access is off. Grant Full Access in System Settings.")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                HStack(spacing: 8) {
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(NotchTheme.micro)
                    .buttonStyle(.plain)
                    Button("Retry") { plugin.requestRemindersAccess() }
                        .font(NotchTheme.micro)
                        .buttonStyle(.plain)
                }
                .foregroundStyle(NotchTheme.textTertiary)
            }
        case .authorized:
            if reminders.items.isEmpty {
                Text("No open reminders — type above to add one.")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
            } else {
                ForEach(reminders.items) { item in
                    reminderRow(item)
                }
            }
        }
    }

    private func reminderRow(_ item: ReminderItem) -> some View {
        let phase = item.phase()
        return HStack(alignment: .top, spacing: 8) {
            Button {
                plugin.completeReminder(item)
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(
                        item.isOverdue
                            ? NotchTheme.caution
                            : (item.listColor.map {
                                Color(red: $0.red, green: $0.green, blue: $0.blue, opacity: max(0.55, $0.alpha))
                            } ?? NotchTheme.textSecondary)
                    )
            }
            .buttonStyle(.plain)
            .help("Mark complete")
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(NotchTheme.body.weight(.semibold))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                    reminderPhaseChip(phase)
                    if item.isHighPriority {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(NotchTheme.caution)
                    }
                }
                Text(reminderSubtitle(item))
                    .font(NotchTheme.micro)
                    .foregroundStyle(
                        item.isOverdue ? NotchTheme.caution.opacity(0.9) : NotchTheme.textTertiary
                    )
                    .lineLimit(1)
                if let notes = item.notes {
                    Text(notes)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            Button {
                plugin.deleteReminder(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 22))
            .help("Delete from Reminders")
        }
        .notchRowBackground()
        .contentShape(Rectangle())
        .onTapGesture { plugin.openReminder(item) }
        .contextMenu {
            Button("Mark Complete") { plugin.completeReminder(item) }
            Button("Open in Reminders") { plugin.openReminder(item) }
            Divider()
            Button("Delete", role: .destructive) { plugin.deleteReminder(item) }
        }
        .help("Open in Reminders")
    }

    @ViewBuilder
    private func reminderPhaseChip(_ phase: ReminderItem.Phase) -> some View {
        switch phase {
        case .overdue:
            NotchStatusChip(text: "Overdue", kind: .danger)
        case .dueNow:
            NotchStatusChip(text: "Due", kind: .now)
        case .soon:
            NotchStatusChip(text: "Soon", kind: .soon)
        case .later, .undated:
            EmptyView()
        }
    }

    private func reminderSubtitle(_ item: ReminderItem) -> String {
        let time: String
        if let due = item.due {
            if item.isAllDay {
                if Calendar.current.isDateInToday(due) {
                    time = item.isOverdue ? "Overdue · all day" : "All day"
                } else {
                    time = Self.dayFormatter.string(from: due)
                }
            } else if Calendar.current.isDateInToday(due) {
                time = Self.timeFormatter.string(from: due)
            } else {
                time = "\(Self.dayFormatter.string(from: due)) \(Self.timeFormatter.string(from: due))"
            }
        } else {
            time = "No date"
        }
        let list = item.listName.isEmpty ? "Reminders" : item.listName
        return "\(time) · \(list)"
    }

    // MARK: Local

    @ViewBuilder
    private var localSection: some View {
        Text("Local")
            .font(NotchTheme.micro.weight(.semibold))
            .foregroundStyle(NotchTheme.textQuaternary)
            .padding(.top, 4)

        if store.items.isEmpty {
            Text("Scratch list on this Mac only — switch target to Local to add.")
                .font(NotchTheme.micro)
                .foregroundStyle(NotchTheme.textQuaternary)
        } else {
            ForEach(store.items) { item in
                localRow(item)
            }
        }
    }

    private func localRow(_ item: ChecklistItem) -> some View {
        HStack(spacing: 8) {
            Button {
                store.toggle(id: item.id)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(item.isDone ? NotchTheme.positive : NotchTheme.textSecondary)
            }
            .buttonStyle(.notchIcon(diameter: 22))

            Text(item.text)
                .font(NotchTheme.body)
                .foregroundStyle(item.isDone ? NotchTheme.textQuaternary : NotchTheme.textPrimary)
                .strikethrough(item.isDone)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                store.remove(id: item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .buttonStyle(.notchIcon(diameter: 22))
        }
        .notchRowBackground()
    }
}
