import SwiftUI

/// **Peek Hub** — inbox for everything that surfaces through the notch Peek.
///
/// Not a second Notification Center. This is Dynamo’s own hub: widget alerts,
/// Focus, battery, calendar, media, API posts, and system apps **routed in**
/// (Messages, FaceTime, Mail, …). Live Peeks still fire; history + unread live here.
@MainActor
final class NotificationsPlugin: ObservableObject, NotchWidgetPlugin, NotchAmbientProviding {
    let id = "peek-hub"
    let displayName = "Hub"
    let systemImage = "bell.badge.fill"

    @ObservedObject private var hub = PeekNotificationCenter.shared
    @ObservedObject private var mirror = SystemNotificationMirror.shared

    var expandedContentHeight: CGFloat { 268 }

    func start() {}
    func stop() {}

    func expandedView() -> AnyView {
        AnyView(ExpandedPeekHubView(hub: hub, mirror: mirror))
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
    @ObservedObject var mirror: SystemNotificationMirror

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
            HStack(spacing: 8) {
                Text("Notification Hub")
                    .font(NotchTheme.section)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.7)
                Spacer(minLength: 0)
                if hub.unreadCount > 0 {
                    Text("\(hub.unreadCount) new")
                        .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                        .foregroundStyle(NotchTheme.caution)
                }
            }

            // Status strip — hub, not “mirror”
            HStack(spacing: 8) {
                statusChip(
                    title: hub.isPrimaryDelivery ? "Peek hub on" : "Hub off",
                    systemImage: "bell.badge",
                    active: hub.isPrimaryDelivery
                )
                statusChip(
                    title: mirror.isEnabled
                        ? (mirror.accessDenied ? "System route blocked" : "System apps routed")
                        : "System route off",
                    systemImage: mirror.accessDenied ? "exclamationmark.shield" : "arrow.triangle.merge",
                    active: mirror.isEnabled && !mirror.accessDenied
                )
                Spacer(minLength: 0)
            }

            if hub.history.isEmpty && hub.pendingCount == 0 {
                NotchEmptyState(
                    systemImage: "bell.badge",
                    title: "Peek is your notification hub",
                    caption: "Calendar, reminders, battery, media, messages, and more land here as notch Peeks — then stay in this inbox.",
                    prominent: true
                )
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        if hub.pendingCount > 0 {
                            Text("\(hub.pendingCount) waiting to Peek")
                                .font(NotchTheme.micro.weight(.semibold))
                                .foregroundStyle(NotchTheme.textQuaternary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(hub.history.prefix(24)) { item in
                            hubRow(item)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    hub.markAllRead()
                } label: {
                    NotchChipLabel(title: "Mark read", systemImage: "checkmark.circle", active: false)
                }
                .buttonStyle(.plain)
                .disabled(hub.unreadCount == 0)

                Button {
                    hub.clearHistory()
                } label: {
                    NotchChipLabel(title: "Clear", systemImage: "trash", active: false)
                }
                .buttonStyle(.plain)
                .disabled(hub.history.isEmpty)

                if mirror.accessDenied {
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        NotchChipLabel(title: "Full Disk Access", systemImage: "lock.shield", active: true)
                    }
                    .buttonStyle(.plain)
                    .help("Needed to route Messages / FaceTime / other apps into the hub")
                }

                Spacer(minLength: 0)
            }

            Text(footerHint)
                .font(NotchTheme.micro)
                .foregroundStyle(NotchTheme.textQuaternary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footerHint: String {
        if mirror.accessDenied {
            return "Grant Full Disk Access to route Messages & calls into the hub. Silence system banners in Focus if you want Peek-only."
        }
        if mirror.isEnabled {
            return "System apps are routed into this hub as Peeks. Use Focus to hide macOS banners if you want a single surface."
        }
        return "Enable “Route system apps into hub” in Preferences to include Messages, FaceTime, and more."
    }

    private func statusChip(title: String, systemImage: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(title)
                .font(NotchTheme.micro.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(active ? NotchTheme.textPrimary : NotchTheme.textTertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(active ? NotchTheme.chipFillActive : NotchTheme.chipFill)
        )
    }

    private func hubRow(_ item: PeekNotificationCenter.PeekHistoryItem) -> some View {
        Button {
            hub.replay(id: item.id)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(urgencyFill(item.urgency))
                        .frame(width: 30, height: 30)
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
                                .fill(NotchTheme.caution)
                                .frame(width: 5, height: 5)
                        }
                    }
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textTertiary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text(item.category)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(NotchTheme.textQuaternary)
                        if !item.detail.isEmpty {
                            Text("· \(item.detail)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(NotchTheme.textQuaternary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(timeLabel(item.deliveredAt))
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(NotchTheme.textQuaternary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(item.isUnread ? NotchTheme.chipFill.opacity(0.9) : NotchTheme.chipFill.opacity(0.45))
            )
        }
        .buttonStyle(.plain)
        .help("Replay as Peek")
        .contextMenu {
            Button("Replay Peek") { hub.replay(id: item.id) }
            Button("Mark read") { hub.markRead(id: item.id) }
        }
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
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }
}
