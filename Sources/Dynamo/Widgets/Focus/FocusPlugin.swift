import AppKit
import SwiftUI

@MainActor
final class FocusPlugin: ObservableObject, NotchWidgetPlugin, NotchAmbientProviding {
    let id = "focus"
    let displayName = "Focus"
    let systemImage = "scope"

    var expandedContentHeight: CGFloat { 255 }

    var isAmbientActive: Bool { FocusController.shared.isMeetingActive }
    var ambientPriority: Int { FocusController.shared.isMeetingActive ? 88 : 0 }

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

    var body: some View {
        HStack(spacing: 6) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            modePicker
            if focus.isMeetingActive {
                meetingBanner
            }
            modeDetail
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            effectiveChip
        }
    }

    private var statusLine: String {
        if focus.isMeetingActive {
            return "Meeting overlay · volume \(focus.duckPercent)%"
        }
        return focus.baseMode.subtitle
    }

    private var effectiveChip: some View {
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
                            .minimumScaleFactor(0.8)
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

    private var meetingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.caution)
            VStack(alignment: .leading, spacing: 1) {
                Text("In a meeting")
                    .font(NotchTheme.caption.weight(.semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                Text(focus.meetingReason.map(\.label) ?? "Auto")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            Spacer(minLength: 0)
            Text("Auto")
                .font(NotchTheme.micro.weight(.semibold))
                .foregroundStyle(NotchTheme.textQuaternary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(NotchTheme.caution.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(NotchTheme.caution.opacity(0.25), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private var modeDetail: some View {
        switch focus.baseMode {
        case .normal:
            detailCard(
                title: "Normal",
                body: "Dynamo runs without extra policy. Meeting still auto-activates on calls and calendar events."
            )
        case .dynamic:
            VStack(alignment: .leading, spacing: 6) {
                detailCard(
                    title: "Dynamic companion",
                    body: "Peeks surface what’s next. Media stays first-class. No AI — just smarter timing."
                )
                if !focus.recentDynamicPeeks.isEmpty {
                    Text("Recent")
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
        case .trueFocus:
            trueFocusAgenda
        }
    }

    private var trueFocusAgenda: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                if let now = agenda.snapshot.now {
                    agendaRow(label: "Now", item: now, accent: NotchTheme.positive)
                }
                if !agenda.snapshot.upNext.isEmpty {
                    Text("Up next")
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textQuaternary)
                    ForEach(agenda.snapshot.upNext.prefix(3)) { item in
                        agendaRow(label: nil, item: item, accent: NotchTheme.mediaGlow)
                    }
                }
                if !agenda.snapshot.needsAttention.isEmpty {
                    Text("Needs attention")
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.caution.opacity(0.9))
                    ForEach(agenda.snapshot.needsAttention.prefix(3)) { item in
                        agendaRow(label: nil, item: item, accent: NotchTheme.caution)
                    }
                }
                if agenda.snapshot.now == nil
                    && agenda.snapshot.upNext.isEmpty
                    && agenda.snapshot.needsAttention.isEmpty {
                    Text("No agenda yet — open Calendar & allow access.")
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textQuaternary)
                }
            }
        }
    }

    private func agendaRow(label: String?, item: FocusAgendaItem, accent: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent.opacity(0.9))
                .frame(width: 2.5, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                if let label {
                    Text(label.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                }
                Text(item.title)
                    .font(NotchTheme.caption.weight(.medium))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                Text(item.detail)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func detailCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(NotchTheme.caption.weight(.semibold))
                .foregroundStyle(NotchTheme.textPrimary)
            Text(body)
                .font(NotchTheme.micro)
                .foregroundStyle(NotchTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
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
}
