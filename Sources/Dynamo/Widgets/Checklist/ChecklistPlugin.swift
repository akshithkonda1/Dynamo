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
            guard let self else { return }
            self.objectWillChange.send()
            self.checkDueReminders()
            // Feed True Focus agenda + Dynamic pulses.
            FocusAgendaEngine.shared.updateReminders(
                self.reminders.items,
                localOpen: self.store.items.filter { !$0.isDone }.map { ($0.id, $0.text) }
            )
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
    @State private var hoveringID: String?

    init(plugin: ChecklistPlugin) {
        self.plugin = plugin
        self._store = ObservedObject(wrappedValue: plugin.store)
        self._reminders = ObservedObject(wrappedValue: plugin.reminders)
    }

    private var doneCount: Int { store.items.filter(\.isDone).count }
    private var totalCount: Int { store.items.count }
    private var openLocal: Int { totalCount - doneCount }
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Checklist")
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

            if reminders.authState == .authorized {
                Button {
                    plugin.refreshReminders()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
                .buttonStyle(.notchIcon(diameter: 22))
                .help("Refresh")

                Button {
                    plugin.openRemindersApp()
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
                .buttonStyle(.notchIcon(diameter: 22))
                .help("Open Reminders")
            }
        }
    }

    private var headerSubtitle: String {
        switch plugin.draftTarget {
        case .reminders:
            if reminders.authState != .authorized { return "Connect Apple Reminders" }
            if reminderCount == 0 { return "No open reminders" }
            return reminderCount == 1 ? "1 open reminder" : "\(reminderCount) open reminders"
        case .local:
            if totalCount == 0 { return "Private to this Mac" }
            return "\(openLocal) open · \(doneCount) done"
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
                    case .local: return openLocal
                    }
                }()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        plugin.draftTarget = target
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: target == .reminders ? "checklist" : "tray")
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
        case .local:
            localContent
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
        case .authorized:
            if reminders.items.isEmpty {
                emptyStrip(
                    icon: "sparkles",
                    title: "All clear",
                    caption: "Add one below — it syncs to Reminders."
                )
            } else {
                ForEach(reminders.items) { item in
                    reminderRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private var localContent: some View {
        if store.items.isEmpty {
            emptyStrip(
                icon: "tray",
                title: "Local list is empty",
                caption: "Private scratch items stay on this Mac."
            )
        } else {
            ForEach(store.items) { item in
                localRow(item)
            }
        }
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

    private func localRow(_ item: ChecklistItem) -> some View {
        let rowID = "l:\(item.id.uuidString)"
        let hovering = hoveringID == rowID

        return HStack(alignment: .center, spacing: 10) {
            Button {
                store.toggle(id: item.id)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(item.isDone ? NotchTheme.positive : NotchTheme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(item.text)
                .font(NotchTheme.body.weight(.medium))
                .foregroundStyle(item.isDone ? NotchTheme.textQuaternary : NotchTheme.textPrimary)
                .strikethrough(item.isDone, color: NotchTheme.textQuaternary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                store.remove(id: item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(hovering ? 0.1 : 0)))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.07 : 0.035))
        )
        .onHover { hoveringID = $0 ? rowID : (hoveringID == rowID ? nil : hoveringID) }
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
                    plugin.draftTarget == .reminders ? "Add to Reminders…" : "Add local item…",
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
                .help(plugin.draftTarget == .reminders ? "Add to Reminders" : "Add local item")
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

            if plugin.draftTarget == .reminders, reminders.authState != .authorized {
                Text(reminders.authState == .denied
                     ? "Reminders access is off — open Settings from the tab above."
                     : "Allow Reminders access to save here.")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.caution.opacity(0.9))
            }

            if let err = reminders.lastError, plugin.draftTarget == .reminders {
                Text(err)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.negative)
                    .lineLimit(2)
            }
        }
    }
}
