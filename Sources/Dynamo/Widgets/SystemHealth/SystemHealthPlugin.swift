import AppKit
import Combine
import SwiftUI

/// Health tab — software updates + system vitals (disk, uptime, memory, thermal).
/// Metrics are read-only; actions deep-link into System Settings / Restart.
@MainActor
final class SystemHealthPlugin: ObservableObject, NotchWidgetPlugin, NotchAmbientProviding, NotchSneakPeekProviding {
    let id = "system-health"
    let displayName = "Health"
    let systemImage = "heart.text.square"

    var expandedContentHeight: CGFloat { 255 }

    @Published private(set) var report: MacHealthReport = .empty
    @Published private(set) var updates: SoftwareUpdateSnapshot = .empty
    @Published private(set) var isRefreshing = false

    var onSneakPeek: ((NotchSneakPeek) -> Void)?

    private let updateProvider = SoftwareUpdateProvider.shared
    private var updateCancellable: AnyCancellable?
    private var healthTimer: Timer?
    private var lastUpdateCount = 0
    private var didStart = false
    private var didPeekUpdatesThisSession = false

    func start() {
        guard !didStart else { return }
        didStart = true

        if let cached = MacHealthModel.loadCached() {
            report = cached
        }
        updates = updateProvider.snapshot
        lastUpdateCount = updates.count

        updateProvider.start()
        updateCancellable = updateProvider.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in
                self?.handleUpdatesChanged(snap)
            }

        // Immediate local vitals; updates arrive async from softwareupdate.
        refreshHealth(forceWeekly: false)
        let t = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshHealth(forceWeekly: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        healthTimer = t

        DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in
            self?.maybePresentWeeklyPeek()
            self?.maybePresentUpdatePeek(force: false)
        }
    }

    func stop() {
        didStart = false
        updateProvider.stop()
        healthTimer?.invalidate()
        healthTimer = nil
        updateCancellable?.cancel()
        updateCancellable = nil
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedSystemHealthView(plugin: self))
    }

    // MARK: - Actions

    func checkNow() {
        isRefreshing = true
        updateProvider.refresh(force: true)
        refreshHealth(forceWeekly: true)
        // softwareupdate is slow — clear spinner when check ends or after a beat.
        Task { @MainActor in
            // Poll until provider finishes (or timeout).
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if !updateProvider.isChecking { break }
            }
            refreshHealth(forceWeekly: false)
            isRefreshing = false
        }
    }

    var updatesRequireRestart: Bool {
        updates.items.contains(where: \.requiresRestart)
    }

    func openFinding(_ finding: MacHealthFinding) {
        switch finding.id {
        case "updates":
            MacHealthActions.open(.softwareUpdate)
        case "uptime":
            if updatesRequireRestart || updates.hasUpdates {
                MacHealthActions.openInstallAndRestart()
            } else {
                MacHealthActions.presentRestartDialog()
            }
        default:
            MacHealthActions.open(finding.destination)
        }
    }

    func openUpdatesOrRestart() {
        MacHealthActions.open(.softwareUpdate)
    }

    func openStorage() {
        MacHealthActions.open(.storage)
    }

    func requestRestart() {
        if updatesRequireRestart || updates.hasUpdates {
            MacHealthActions.openInstallAndRestart()
        } else {
            MacHealthActions.presentRestartDialog()
        }
    }

    // MARK: - Pipeline

    private func handleUpdatesChanged(_ snap: SoftwareUpdateSnapshot) {
        let previous = lastUpdateCount
        updates = snap
        refreshHealth(forceWeekly: MacHealthModel.needsWeeklyReport)

        if snap.succeeded, snap.count > previous, snap.hasUpdates {
            maybePresentUpdatePeek(force: true)
        }
        lastUpdateCount = snap.count
        if !updateProvider.isChecking {
            isRefreshing = false
        }
    }

    private func refreshHealth(forceWeekly: Bool) {
        updates = updateProvider.snapshot
        let due = forceWeekly || MacHealthModel.needsWeeklyReport || report.weekKey.isEmpty
        let next = MacHealthModel.generate(updates: updates)
        report = next
        if due {
            MacHealthModel.save(next)
        }
    }

    private func maybePresentUpdatePeek(force: Bool) {
        guard updates.hasUpdates, updates.succeeded else { return }
        if !force, didPeekUpdatesThisSession { return }
        didPeekUpdatesThisSession = true
        let title = updates.count == 1
            ? "Software update available"
            : "\(updates.count) software updates"
        let subtitle = updates.items.first?.title ?? "Open System Settings to install"
        onSneakPeek?(NotchSneakPeek(
            systemImage: "arrow.down.circle.fill",
            title: title,
            subtitle: subtitle,
            urgency: updates.recommendedCount > 0 ? .high : .normal
        ))
    }

    private func maybePresentWeeklyPeek() {
        guard MacHealthModel.shouldPeekWeeklyReport else { return }
        if report.weekKey != MacHealthModel.weekKey() {
            refreshHealth(forceWeekly: true)
        }
        guard report.weekKey == MacHealthModel.weekKey() else { return }
        MacHealthModel.markWeeklyPeekShown(report.weekKey)
        onSneakPeek?(NotchSneakPeek(
            systemImage: "heart.text.square.fill",
            title: "Weekly health check",
            subtitle: report.summary,
            urgency: report.warningCount > 0 ? .high : .normal
        ))
    }

    // MARK: - Ambient

    var isAmbientActive: Bool {
        if updates.hasUpdates { return true }
        if report.warningCount > 0 { return true }
        return false
    }

    var ambientPriority: Int {
        if updates.hasUpdates, updates.recommendedCount > 0 { return 78 }
        if updates.hasUpdates { return 68 }
        if report.findings.contains(where: { $0.severity == .warning }) { return 72 }
        if report.warningCount > 0 { return 55 }
        return 10
    }

    func ambientView() -> AnyView {
        AnyView(AmbientSystemHealthView(
            updates: updates,
            report: report,
            installAction: { [weak self] in self?.openUpdatesOrRestart() }
        ))
    }
}

// MARK: - Ambient

private struct AmbientSystemHealthView: View {
    let updates: SoftwareUpdateSnapshot
    let report: MacHealthReport
    let installAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(label)
                .font(NotchTheme.micro.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
            if report.score > 0 {
                Text(report.grade)
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(gradeColor)
            }
            if updates.hasUpdates, let installAction {
                Button {
                    installAction()
                } label: {
                    Text("Install \(updates.count)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(NotchTheme.caution)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(NotchTheme.caution.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchTheme.ambientInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var iconName: String {
        if updates.hasUpdates { return "arrow.down.circle.fill" }
        if report.warningCount > 0 { return "exclamationmark.triangle.fill" }
        return "heart.text.square.fill"
    }

    private var label: String {
        if updates.hasUpdates {
            return updates.count == 1 ? "1 update" : "\(updates.count) updates"
        }
        if report.warningCount > 0 { return "Health" }
        return "Health"
    }

    private var tint: Color {
        if updates.hasUpdates { return NotchTheme.caution }
        if report.findings.contains(where: { $0.severity == .warning }) {
            return NotchTheme.negative
        }
        if report.warningCount > 0 { return NotchTheme.caution }
        return NotchTheme.textSecondary
    }

    private var gradeColor: Color {
        let g = report.grade
        if g.hasPrefix("A") { return NotchTheme.positive }
        if g.hasPrefix("B") || g.hasPrefix("C") { return NotchTheme.caution }
        return NotchTheme.negative
    }
}

// MARK: - Expanded

private struct ExpandedSystemHealthView: View {
    @ObservedObject var plugin: SystemHealthPlugin
    @ObservedObject private var updateProvider = SoftwareUpdateProvider.shared
    @State private var refreshSpin = false

    private var report: MacHealthReport { plugin.report }
    private var updates: SoftwareUpdateSnapshot { plugin.updates }
    private var busy: Bool { plugin.isRefreshing || updateProvider.isChecking }

    private var metrics: [MacHealthFinding] {
        Array(report.findings.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
            // Header + refresh
            HStack(spacing: 8) {
                Text("Health")
                    .font(NotchTheme.section)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.7)
                Spacer(minLength: 0)
                Text(report.grade)
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(scoreColor)
                refreshButton
            }

            // Score
            NotchCard(compact: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(max(0, report.score))")
                            .font(NotchTheme.heroDigit.monospacedDigit())
                            .foregroundStyle(scoreColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.summary)
                                .font(NotchTheme.body)
                                .foregroundStyle(NotchTheme.textSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(checkedLabel)
                                .font(NotchTheme.micro)
                                .foregroundStyle(NotchTheme.textQuaternary)
                        }
                        Spacer(minLength: 0)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(NotchTheme.chipFill)
                            Capsule()
                                .fill(scoreColor.opacity(0.9))
                                .frame(
                                    width: max(
                                        6,
                                        geo.size.width * CGFloat(min(100, max(0, report.score))) / 100
                                    )
                                )
                        }
                    }
                    .frame(height: 5)
                }
            }

            // Updates
            Button {
                plugin.openUpdatesOrRestart()
            } label: {
                NotchCard(compact: true) {
                    HStack(spacing: 8) {
                        Image(systemName: updatesIcon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(updatesTint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(updatesTitle)
                                .font(NotchTheme.body.weight(.medium))
                                .foregroundStyle(NotchTheme.textPrimary)
                                .lineLimit(1)
                            if let sub = updatesSubtitle {
                                Text(sub)
                                    .font(NotchTheme.micro)
                                    .foregroundStyle(NotchTheme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(NotchTheme.textQuaternary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Open Software Update")

            // Vitals grid (2×2)
            if !metrics.isEmpty {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(metrics) { finding in
                        metricCell(finding)
                    }
                }
            }

            // Actions
            HStack(spacing: 8) {
                Button {
                    triggerRefresh()
                } label: {
                    NotchChipLabel(
                        title: busy ? "Refreshing…" : "Refresh",
                        systemImage: "arrow.clockwise",
                        active: busy
                    )
                }
                .buttonStyle(.plain)
                .disabled(busy)

                if updates.hasUpdates {
                    Button {
                        plugin.openUpdatesOrRestart()
                    } label: {
                        NotchChipLabel(
                            title: plugin.updatesRequireRestart ? "Install & Restart" : "Install",
                            systemImage: plugin.updatesRequireRestart
                                ? "arrow.triangle.2.circlepath"
                                : "arrow.down.circle",
                            active: true
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        plugin.requestRestart()
                    } label: {
                        NotchChipLabel(
                            title: "Restart…",
                            systemImage: "arrow.clockwise.circle",
                            active: false
                        )
                    }
                    .buttonStyle(.plain)
                    .help("System Restart confirmation")
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // Ensure vitals are fresh when opening the tab.
            if report.generatedAt.timeIntervalSinceNow < -120 || report.score == 0 {
                plugin.checkNow()
            }
        }
        .onChange(of: busy) { checking in
            if checking {
                refreshSpin = true
            } else {
                // Let one rotation finish feel natural
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    refreshSpin = false
                }
            }
        }
    }

    private var refreshButton: some View {
        Button {
            triggerRefresh()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(busy ? NotchTheme.textQuaternary : NotchTheme.textSecondary)
                .rotationEffect(.degrees(refreshSpin ? 360 : 0))
                .animation(
                    refreshSpin
                        ? .linear(duration: 0.75).repeatForever(autoreverses: false)
                        : .default,
                    value: refreshSpin
                )
                .frame(width: 26, height: 26)
                .background(Circle().fill(NotchTheme.chipFill))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help("Refresh Health")
        .accessibilityLabel("Refresh Health")
    }

    private func triggerRefresh() {
        refreshSpin = true
        plugin.checkNow()
    }

    private func metricCell(_ f: MacHealthFinding) -> some View {
        Button {
            plugin.openFinding(f)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: f.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(severityColor(f.severity))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.title)
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                    Text(f.detail)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(NotchTheme.chipFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(helpForFinding(f))
    }

    private var updatesIcon: String {
        if busy { return "arrow.clockwise" }
        if updates.hasUpdates { return "arrow.down.circle.fill" }
        if updates.succeeded { return "checkmark.seal.fill" }
        return "questionmark.circle"
    }

    private var updatesTint: Color {
        if updates.hasUpdates { return NotchTheme.caution }
        if updates.succeeded { return NotchTheme.positive }
        return NotchTheme.textTertiary
    }

    private var updatesTitle: String {
        if busy, !updates.succeeded { return "Checking for updates…" }
        if updates.hasUpdates {
            let n = updates.count
            let base = n == 1 ? "1 update available" : "\(n) updates available"
            return plugin.updatesRequireRestart ? "\(base) · restart" : base
        }
        if updates.succeeded { return "Software up to date" }
        return "Tap Refresh to check updates"
    }

    private var updatesSubtitle: String? {
        if updates.hasUpdates {
            return updates.items.first?.title
        }
        if let err = updates.errorMessage { return err }
        return nil
    }

    private var checkedLabel: String {
        if report.generatedAt == .distantPast {
            return "Not checked yet — tap Refresh"
        }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return "Updated \(fmt.localizedString(for: report.generatedAt, relativeTo: Date()))"
    }

    private var scoreColor: Color {
        if report.generatedAt == .distantPast { return NotchTheme.textTertiary }
        if report.score >= 85 { return NotchTheme.positive }
        if report.score >= 65 { return NotchTheme.caution }
        return NotchTheme.negative
    }

    private func severityColor(_ s: MacHealthFinding.Severity) -> Color {
        switch s {
        case .good: return NotchTheme.positive
        case .info: return NotchTheme.textSecondary
        case .caution: return NotchTheme.caution
        case .warning: return NotchTheme.negative
        }
    }

    private func helpForFinding(_ f: MacHealthFinding) -> String {
        switch f.destination {
        case .softwareUpdate: return "Open Software Update"
        case .storage: return "Open Storage settings"
        case .battery: return "Open Battery settings"
        case .aboutThisMac: return "About This Mac"
        case .activityMonitor: return "Open Activity Monitor"
        case .restart:
            if plugin.updatesRequireRestart || plugin.updates.hasUpdates {
                return "Open Software Update"
            }
            return "Restart this Mac"
        case .generalSettings: return "Open System Settings"
        case .none: return f.detail
        }
    }
}
