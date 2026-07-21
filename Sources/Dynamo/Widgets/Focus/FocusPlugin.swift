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
                if let reason = focus.meetingReason {
                    Text(reason.label)
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
    @ObservedObject private var volume = SystemVolumeController.shared

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 8)
            modePicker
                .padding(.bottom, 8)
            meetingStrip
                .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    modeBody
                }
            }

            footerActions
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            FocusController.shared.reevaluateMeeting()
            SystemVolumeController.shared.start()
            DynamicCompanion.shared.maybeSessionNudge { _ in }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
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
                    Capsule(style: .continuous)
                        .fill(focus.isMeetingActive
                              ? NotchTheme.caution.opacity(0.18)
                              : NotchTheme.chipFillActive)
                )
        }
    }

    private var statusLine: String {
        if focus.isMeetingActive {
            let vol = volume.percent
            return "Meeting · volume \(vol)% (target \(focus.duckPercent)%)"
        }
        switch focus.baseMode {
        case .normal: return "Default Dynamo"
        case .dynamic: return dynamicHint
        case .trueFocus: return trueFocusHint
        }
    }

    private var dynamicHint: String {
        if let next = agenda.snapshot.upNext.first {
            return "Next: \(next.title)"
        }
        if let att = agenda.snapshot.needsAttention.first {
            return "Overdue: \(att.title)"
        }
        return "Companion peeks · no AI"
    }

    private var trueFocusHint: String {
        let n = agenda.snapshot.upNext.count
        let a = agenda.snapshot.needsAttention.count
        if agenda.snapshot.now != nil { return "In progress now" }
        if a > 0 { return "\(a) need attention" }
        if n > 0 { return "\(n) upcoming today" }
        return "Agenda from Calendar & Reminders"
    }

    // MARK: Mode picker

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(FocusBaseMode.allCases) { mode in
                let selected = focus.baseMode == mode
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        focus.baseMode = mode
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                        Text(mode.title)
                            .font(NotchTheme.micro.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(selected ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
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

    // MARK: Meeting strip

    private var meetingStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: focus.isMeetingActive ? "video.fill" : "video")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(focus.isMeetingActive ? NotchTheme.caution : NotchTheme.textQuaternary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(focus.isMeetingActive ? "In a meeting" : "Auto-meeting")
                    .font(NotchTheme.caption.weight(.semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                Text(meetingSubtitle)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Duck % control
            HStack(spacing: 4) {
                Button {
                    focus.duckPercent = max(10, focus.duckPercent - 5)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(NotchTheme.textTertiary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)

                Text("\(focus.duckPercent)%")
                    .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                    .foregroundStyle(NotchTheme.textSecondary)
                    .frame(width: 32)

                Button {
                    focus.duckPercent = min(40, focus.duckPercent + 5)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(NotchTheme.textTertiary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .help("Volume duck target when Meeting auto-activates")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(focus.isMeetingActive
                      ? NotchTheme.caution.opacity(0.1)
                      : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            focus.isMeetingActive
                                ? NotchTheme.caution.opacity(0.28)
                                : Color.white.opacity(0.07),
                            lineWidth: 0.5
                        )
                )
        )
    }

    private var meetingSubtitle: String {
        if focus.isMeetingActive {
            return focus.meetingReason.map(\.label) ?? "Active"
        }
        return focus.autoMeetingEnabled
            ? "Listens for Zoom, FaceTime, Teams & calendar Now"
            : "Disabled in settings"
    }

    // MARK: Body

    @ViewBuilder
    private var modeBody: some View {
        switch focus.baseMode {
        case .normal:
            tipCard(
                icon: "circle",
                title: "Normal",
                body: "Default Dynamo. Meeting still auto-ducks volume and quiets peeks when you’re on a call or in a calendar event."
            )
        case .dynamic:
            dynamicBody
        case .trueFocus:
            trueFocusBody
        }
    }

    private var dynamicBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            tipCard(
                icon: "bolt.horizontal.circle",
                title: "Dynamic companion",
                body: "Uses peeks as tools — next event, overdue reminders. Media stays first-class. No AI."
            )
            if let next = agenda.snapshot.upNext.first {
                miniRow(title: "Up next", value: next.title, detail: timeLabel(next.when))
            }
            if let overdue = agenda.snapshot.needsAttention.first {
                miniRow(title: "Overdue", value: overdue.title, detail: overdue.detail)
            }
            if !focus.recentDynamicPeeks.isEmpty {
                Text("Recent peeks")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                ForEach(focus.recentDynamicPeeks.prefix(3), id: \.self) { title in
                    Text(title)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var trueFocusBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let now = agenda.snapshot.now {
                agendaBlock(label: "Now", item: now, accent: NotchTheme.positive)
            }
            if !agenda.snapshot.upNext.isEmpty {
                Text("Up next")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                ForEach(agenda.snapshot.upNext.prefix(3)) { item in
                    agendaBlock(label: nil, item: item, accent: NotchTheme.mediaGlow)
                }
            }
            if !agenda.snapshot.needsAttention.isEmpty {
                Text("Needs attention")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.caution.opacity(0.95))
                ForEach(agenda.snapshot.needsAttention.prefix(3)) { item in
                    agendaBlock(label: nil, item: item, accent: NotchTheme.caution)
                }
            }
            if agenda.snapshot.now == nil
                && agenda.snapshot.upNext.isEmpty
                && agenda.snapshot.needsAttention.isEmpty {
                tipCard(
                    icon: "target",
                    title: "No agenda yet",
                    body: "Allow Calendar & Reminders so True Focus can organize your day."
                )
                HStack(spacing: 8) {
                    privacyButton("Calendar") {
                        openPrivacy("Privacy_Calendars")
                    }
                    privacyButton("Reminders") {
                        openPrivacy("Privacy_Reminders")
                    }
                }
            }
        }
    }

    private func agendaBlock(label: String?, item: FocusAgendaItem, accent: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent.opacity(0.9))
                .frame(width: 2.5, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if let label {
                        Text(label.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                    }
                    Text(item.title)
                        .font(NotchTheme.caption.weight(.medium))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(item.detail)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .lineLimit(1)
                    if let when = item.when {
                        Text(timeLabel(when))
                            .font(NotchTheme.micro.monospacedDigit())
                            .foregroundStyle(NotchTheme.textTertiary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func miniRow(title: String, value: String, detail: String) -> some View {
        HStack {
            Text(title)
                .font(NotchTheme.micro.weight(.semibold))
                .foregroundStyle(NotchTheme.textQuaternary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(NotchTheme.caption.weight(.medium))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(detail)
                .font(NotchTheme.micro)
                .foregroundStyle(NotchTheme.textTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func tipCard(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.07)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(NotchTheme.caption.weight(.semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                Text(body)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
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

    // MARK: Footer

    private var footerActions: some View {
        HStack(spacing: 8) {
            actionChip("Refresh", systemImage: "arrow.clockwise") {
                FocusController.shared.reevaluateMeeting()
                FocusAgendaEngine.shared.rebuild()
            }
            actionChip("Calendar", systemImage: "calendar") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                    NSWorkspace.shared.open(url)
                }
            }
            actionChip("Reminders", systemImage: "checklist") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
                    NSWorkspace.shared.open(url)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func actionChip(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(NotchTheme.micro.weight(.semibold))
            }
            .foregroundStyle(NotchTheme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private func privacyButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Allow \(title)")
                .font(NotchTheme.micro.weight(.semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(NotchTheme.chipFillActive))
        }
        .buttonStyle(.plain)
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func timeLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        let now = Date()
        let mins = Int(date.timeIntervalSince(now) / 60)
        if mins > 0 && mins < 180 {
            return "in \(mins)m"
        }
        if mins < 0 && mins > -120 {
            return "now"
        }
        return Self.timeFormatter.string(from: date)
    }
}
