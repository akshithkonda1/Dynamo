import SwiftUI

/// **Peek Hub** — inbox for everything Dynamo routes into the notch.
///
/// Dynamo is the **router**; this tab is the **hub inbox**. Live Peeks still
/// fire from the island; history + unread + replay live here.
@MainActor
final class NotificationsPlugin: ObservableObject, NotchWidgetPlugin, NotchAmbientProviding, WidgetSettingsProviding {
    let id = "peek-hub"
    let displayName = "Hub"
    let systemImage = "bell.badge.fill"

    @ObservedObject private var hub = PeekNotificationCenter.shared
    @ObservedObject private var router = DynamoNotificationRouter.shared
    @ObservedObject private var mirror = SystemNotificationMirror.shared

    var expandedContentHeight: CGFloat { 320 }

    func start() {}
    func stop() {}

    func expandedView() -> AnyView {
        AnyView(ExpandedPeekHubView(hub: hub, router: router, mirror: mirror))
    }

    func settingsView() -> AnyView {
        AnyView(NotificationsSettingsView())
    }

    // MARK: Ambient — unread badge in the collapsed notch

    var isAmbientActive: Bool {
        hub.unreadCount > 0 || hub.pendingCount > 0
    }

    var ambientPriority: Int {
        if hub.unreadCount > 0 { return 75 }
        if hub.pendingCount > 0 { return 55 }
        return 5
    }

    func ambientView() -> AnyView {
        AnyView(AmbientPeekHubView(
            unread: hub.unreadCount,
            pending: hub.pendingCount,
            lastTitle: hub.lastDelivered?.title
        ))
    }
}

// MARK: - Ambient

private struct AmbientPeekHubView: View {
    let unread: Int
    let pending: Int
    let lastTitle: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: unread > 0 ? "bell.badge.fill" : "bell.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(unread > 0 ? NotchTheme.caution : NotchTheme.textSecondary)
            if unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(NotchTheme.micro.weight(.bold).monospacedDigit())
                    .foregroundStyle(NotchTheme.caution)
            }
            if let lastTitle, !lastTitle.isEmpty {
                Text(lastTitle)
                    .font(NotchTheme.micro.weight(.medium))
                    .foregroundStyle(NotchTheme.textTertiary)
                    .lineLimit(1)
            } else if pending > 0 {
                Text("\(pending) queued")
                    .font(NotchTheme.micro.monospacedDigit())
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchTheme.ambientInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Expanded hub

private struct ExpandedPeekHubView: View {
    @ObservedObject var hub: PeekNotificationCenter
    @ObservedObject var router: DynamoNotificationRouter
    @ObservedObject var mirror: SystemNotificationMirror
    @State private var filter: HubInboxFilter = .all

    private var filteredHistory: [PeekNotificationCenter.PeekHistoryItem] {
        hub.history.filter { filter.matches($0) }
    }

    private var filterCounts: [HubInboxFilter: Int] {
        Dictionary(uniqueKeysWithValues: HubInboxFilter.allCases.map { f in
            (f, hub.history.filter { f.matches($0) }.count)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            controlCard
            filterStrip

            if filteredHistory.isEmpty {
                NotchEmptyState(
                    systemImage: filter == .all ? "bell.badge" : "line.3.horizontal.decrease.circle",
                    title: emptyTitle,
                    caption: emptyCaption,
                    prominent: true
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 5) {
                        if hub.pendingCount > 0, filter == .all || filter == .unread {
                            pendingBanner
                        }
                        ForEach(Array(filteredHistory.prefix(30).enumerated()), id: \.element.id) { index, item in
                            hubRow(item)
                                .notchAppear(delay: Double(min(index, 8)) * 0.025, rise: 4)
                        }
                    }
                }
            }

            actionRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notchAppear()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Notifications")
                .font(NotchTheme.section)
                .foregroundStyle(NotchTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(NotchTheme.sectionTracking)
            Text(statusPlainEnglish)
                .font(NotchTheme.micro)
                .foregroundStyle(NotchTheme.textQuaternary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if hub.unreadCount > 0 {
                Text("\(hub.unreadCount) unread")
                    .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                    .foregroundStyle(NotchTheme.caution)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(NotchTheme.caution.opacity(0.16))
                            .overlay(Capsule().strokeBorder(NotchTheme.caution.opacity(0.25), lineWidth: 0.5))
                    )
            }
        }
    }

    /// One plain-English line so the control strip isn’t cryptic.
    private var statusPlainEnglish: String {
        if !router.isEnabled { return "Delivery paused" }
        if router.peekOnlyDelivery {
            return mirror.accessDenied ? "Peek-only · grant Disk Access for Messages" : "Peek-only · notch alerts"
        }
        return "Routing into Peek + hub inbox"
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick controls")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(NotchTheme.textQuaternary)
                .textCase(.uppercase)
                .tracking(0.5)
            HStack(spacing: 5) {
                hubToggle(
                    title: "On",
                    help: "Master switch — when off, Dynamo won’t deliver Peeks",
                    systemImage: "power",
                    isOn: Binding(get: { router.isEnabled }, set: { router.isEnabled = $0 })
                )
                hubToggle(
                    title: "Notch only",
                    help: "Prefer Peeks in the notch instead of corner banners",
                    systemImage: "menubar.rectangle",
                    isOn: Binding(get: { router.peekOnlyDelivery }, set: { router.peekOnlyDelivery = $0 })
                )
                hubToggle(
                    title: "Messages",
                    help: "Route Messages / FaceTime into Dynamo (needs Full Disk Access)",
                    systemImage: mirror.accessDenied ? "exclamationmark.shield" : "message.fill",
                    isOn: Binding(get: { router.routeSystemApps }, set: { router.routeSystemApps = $0 })
                )
                hubToggle(
                    title: "Tap feel",
                    help: "Haptic feedback when a Peek appears",
                    systemImage: "hand.tap",
                    isOn: Binding(get: { hub.hapticsEnabled }, set: { hub.hapticsEnabled = $0 })
                )
                Spacer(minLength: 0)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(NotchTheme.chipFill.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    private func hubToggle(title: String, help: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Button {
            withAnimation(NotchTheme.snappy) { isOn.wrappedValue.toggle() }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isOn.wrappedValue ? NotchTheme.textPrimary : NotchTheme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOn.wrappedValue ? NotchTheme.chipFillActive : Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                isOn.wrappedValue ? NotchTheme.neonCyan.opacity(0.35) : Color.white.opacity(0.06),
                                lineWidth: 0.6
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(HubInboxFilter.allCases) { f in
                    let count = filterCounts[f] ?? 0
                    let label = (f == .all || count == 0) ? f.title : "\(f.title) \(count)"
                    Button {
                        withAnimation(NotchTheme.snappy) { filter = f }
                    } label: {
                        NotchChipLabel(title: label, active: filter == f)
                    }
                    .buttonStyle(.plain)
                    .opacity(f == .all || count > 0 || filter == f ? 1 : 0.45)
                }
            }
        }
    }

    private var pendingBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchTheme.calmGlow)
            Text("\(hub.pendingCount) waiting to show")
                .font(NotchTheme.micro.weight(.semibold))
                .foregroundStyle(NotchTheme.textSecondary)
            Spacer(minLength: 0)
            Text("Queued")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(NotchTheme.calmGlow.opacity(0.9))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(NotchTheme.calmGlow.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(NotchTheme.calmGlow.opacity(0.22), lineWidth: 0.5)
                )
        )
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            Button { hub.markAllRead() } label: {
                NotchChipLabel(title: "Mark all read", systemImage: "checkmark.circle", active: false)
            }
            .buttonStyle(.plain)
            .disabled(hub.unreadCount == 0)
            .opacity(hub.unreadCount == 0 ? 0.4 : 1)

            Button { hub.clearHistory() } label: {
                NotchChipLabel(title: "Clear inbox", systemImage: "trash", active: false)
            }
            .buttonStyle(.plain)
            .disabled(hub.history.isEmpty)
            .opacity(hub.history.isEmpty ? 0.4 : 1)

            Spacer(minLength: 0)

            if mirror.accessDenied {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    NotchChipLabel(title: "Allow access", systemImage: "lock.shield", active: true)
                }
                .buttonStyle(.plain)
                .help("Full Disk Access lets Dynamo route Messages into the Hub")
            } else if router.peekOnlyDelivery {
                Button {
                    DynamoNotificationRouter.shared.openNotificationSettingsForPeekOnly()
                } label: {
                    NotchChipLabel(title: "Silence banners", systemImage: "rectangle.badge.xmark", active: true)
                }
                .buttonStyle(.plain)
                .help("Open Notifications settings to set Alert style to None")
            }
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .all: return hub.history.isEmpty ? "You’re all caught up" : "No matches"
        case .unread: return "No unread Peeks"
        default: return "No \(filter.title.lowercased()) Peeks"
        }
    }

    private var emptyCaption: String {
        switch filter {
        case .all:
            return hub.history.isEmpty
                ? "When Calendar, Battery, Messages, and more Peek, they’ll land here. Tap a row to replay."
                : "Try another filter, or clear filters with All."
        case .unread:
            return "New Peeks show a blue dot. Tap Mark all read when you’re done."
        default:
            return "Switch to All to see everything in your inbox."
        }
    }

    private func hubRow(_ item: PeekNotificationCenter.PeekHistoryItem) -> some View {
        Button {
            hub.replay(id: item.id)
            hub.markRead(id: item.id)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(urgencyFill(item.urgency))
                        .frame(width: 30, height: 30)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(urgencyColor(item.urgency).opacity(0.28), lineWidth: 0.5)
                        )
                    Image(systemName: item.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(urgencyColor(item.urgency))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(NotchTheme.body.weight(item.isUnread ? .semibold : .medium))
                            .foregroundStyle(NotchTheme.textPrimary)
                            .lineLimit(1)
                        if item.isUnread {
                            Circle()
                                .fill(NotchTheme.neonCyan)
                                .frame(width: 5, height: 5)
                                .shadow(color: NotchTheme.neonCyan.opacity(0.5), radius: 2, y: 0)
                        }
                    }
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textTertiary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text(friendlyCategory(item.category))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(NotchTheme.textQuaternary)
                        Spacer(minLength: 0)
                        Text(timeLabel(item.deliveredAt))
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(NotchTheme.textQuaternary)
                        Text("Replay")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(NotchTheme.neonCyan.opacity(0.75))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(item.isUnread ? NotchTheme.chipFill.opacity(0.95) : NotchTheme.chipFill.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                item.isUnread ? NotchTheme.neonCyan.opacity(0.16) : Color.white.opacity(0.05),
                                lineWidth: 0.5
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Replay this Peek in the notch")
        .contextMenu {
            Button("Replay Peek") { hub.replay(id: item.id) }
            Button("Mark read") { hub.markRead(id: item.id) }
        }
    }

    private func friendlyCategory(_ raw: String) -> String {
        let c = raw.lowercased()
        if c.contains("battery") { return "Battery" }
        if c.contains("text") || c.contains("message") { return "Message" }
        if c.contains("call") { return "Call" }
        if c.contains("calendar") { return "Calendar" }
        if c.contains("media") { return "Media" }
        if c.contains("focus") { return "Focus" }
        if c.isEmpty || c == "general" { return "Alert" }
        return raw.capitalized
    }

    private func urgencyColor(_ u: NotchSneakPeekUrgency) -> Color {
        switch u {
        case .critical: return NotchTheme.caution
        case .high: return NotchTheme.caution.opacity(0.9)
        case .normal: return NotchTheme.textSecondary
        case .low: return NotchTheme.textTertiary
        }
    }

    private func urgencyFill(_ u: NotchSneakPeekUrgency) -> Color {
        switch u {
        case .critical: return NotchTheme.caution.opacity(0.2)
        case .high: return NotchTheme.caution.opacity(0.12)
        default: return NotchTheme.chipFillActive
        }
    }

    private func timeLabel(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86_400))d ago"
    }
}

// MARK: - Settings

private struct NotificationsSettingsView: View {
    @ObservedObject private var hub = PeekNotificationCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Haptics on Peek", isOn: $hub.hapticsEnabled)
            Toggle("Sound on critical Peeks", isOn: $hub.criticalSoundEnabled)
            Text("Battery 10% / critically low / fully charged always play a sound.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("History retention", selection: $hub.historyRetention) {
                Text("20").tag(20)
                Text("60").tag(60)
                Text("100").tag(100)
                Text("200").tag(200)
            }
            .pickerStyle(.segmented)
            Text("Older hub inbox items are dropped past this limit.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
