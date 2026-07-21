import AppKit
import SwiftUI

@MainActor
final class SportsPlugin: ObservableObject, NotchWidgetPlugin, NotchAmbientProviding, NotchSneakPeekProviding {
    let id = "sports"
    let displayName = "Sports"
    let systemImage = "sportscourt.fill"

    var expandedContentHeight: CGFloat { 255 }
    var onSneakPeek: ((NotchSneakPeek) -> Void)?

    private let store = SportsStore.shared

    var isAmbientActive: Bool { store.liveFollowed != nil }
    var ambientPriority: Int { store.liveFollowed != nil ? 55 : 0 }

    func start() {
        store.onScorePeek = { [weak self] peek in
            self?.onSneakPeek?(peek)
        }
        store.start()
    }

    func stop() {
        store.stop()
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedSportsView(store: store))
    }

    func ambientView() -> AnyView {
        AnyView(AmbientSportsView(store: store))
    }
}

// MARK: - Ambient

private struct AmbientSportsView: View {
    @ObservedObject var store: SportsStore

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.liveFollowed != nil ? NotchTheme.positive : NotchTheme.textQuaternary)
                .frame(width: 6, height: 6)
            if let live = store.liveFollowed {
                Text("\(live.displayAway) \(live.awayScore ?? "")–\(live.homeScore ?? "") \(live.displayHome)")
                    .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
            } else {
                Text("Sports")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchTheme.ambientInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Expanded

private struct ExpandedSportsView: View {
    @ObservedObject var store: SportsStore

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            leagueChips
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if store.currentEvents.isEmpty {
                        empty
                    } else {
                        section(title: "Live", events: store.liveEvents, accent: NotchTheme.positive)
                        section(title: "Upcoming", events: store.upcomingEvents, accent: NotchTheme.mediaGlow)
                        section(title: "Final", events: store.finalEvents, accent: NotchTheme.textTertiary)
                    }
                }
            }
            footerMeta
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Sports")
                    .font(NotchTheme.section)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.7)
                Text(store.selectedLeague.title)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            Spacer(minLength: 0)
            if store.liveCount > 0 {
                Text("\(store.liveCount) live")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(NotchTheme.positive)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(NotchTheme.positive.opacity(0.15)))
            }
            if store.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.65)
            }
            Button { store.refresh(league: store.selectedLeague) } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            .buttonStyle(.notchIcon(diameter: 22))
            .help("Refresh")
        }
    }

    private var leagueChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(SportsLeague.allCases) { league in
                    let selected = store.selectedLeague == league
                    Button { store.select(league) } label: {
                        Text(league.title)
                            .font(NotchTheme.micro.weight(.semibold))
                            .foregroundStyle(selected ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selected ? NotchTheme.chipFillActive : NotchTheme.chipFill)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    store.followOnly.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: store.followOnly ? "star.fill" : "star")
                            .font(.system(size: 8, weight: .bold))
                        Text("Following")
                            .font(NotchTheme.micro.weight(.semibold))
                    }
                    .foregroundStyle(store.followOnly ? NotchTheme.caution : NotchTheme.textTertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(store.followOnly ? NotchTheme.caution.opacity(0.15) : NotchTheme.chipFill)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func section(title: String, events: [SportsEvent], accent: Color) -> some View {
        if !events.isEmpty {
            Text(title)
                .font(NotchTheme.micro.weight(.semibold))
                .foregroundStyle(NotchTheme.textQuaternary)
                .padding(.top, 2)
            ForEach(events) { event in
                eventRow(event, accent: accent)
            }
        }
    }

    private var empty: some View {
        HStack(spacing: 10) {
            Image(systemName: "sportscourt")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NotchTheme.textQuaternary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.05)))
            VStack(alignment: .leading, spacing: 2) {
                Text(store.isLoading ? "Loading scores…" : "No games in this window")
                    .font(NotchTheme.caption.weight(.medium))
                    .foregroundStyle(NotchTheme.textSecondary)
                Text("Showing yesterday → tomorrow · free ESPN feed")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
    }

    private var footerMeta: some View {
        Group {
            if let err = store.lastError {
                Text(err)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
            } else if let updated = store.lastUpdated {
                Text("Updated \(Self.timeFormatter.string(from: updated))")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary.opacity(0.8))
            }
        }
    }

    private func eventRow(_ event: SportsEvent, accent: Color) -> some View {
        let live = event.isLive
        return Button {
            if let s = event.linkURL, let url = URL(string: s) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                statusPill(event.status)

                if event.league != .f1 {
                    logoStack(event)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if event.league == .f1, let headline = event.headlineScore {
                        Text(headline)
                            .font(NotchTheme.caption.weight(.medium))
                            .foregroundStyle(NotchTheme.textPrimary)
                            .lineLimit(2)
                    } else {
                        HStack(spacing: 6) {
                            Text("\(event.displayAway) @ \(event.displayHome)")
                                .font(NotchTheme.caption.weight(.medium))
                                .foregroundStyle(NotchTheme.textPrimary)
                                .lineLimit(1)
                            if store.isFollowed(event) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(NotchTheme.caution)
                            }
                        }
                        HStack(spacing: 8) {
                            if let a = event.awayScore, let h = event.homeScore {
                                Text("\(a) – \(h)")
                                    .font(NotchTheme.body.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(live ? NotchTheme.positive : NotchTheme.textSecondary)
                            } else if let start = event.startDate, event.status == .scheduled {
                                Text(Self.timeFormatter.string(from: start))
                                    .font(NotchTheme.micro.monospacedDigit())
                                    .foregroundStyle(NotchTheme.textTertiary)
                            }
                            Text(event.statusText)
                                .font(NotchTheme.micro)
                                .foregroundStyle(NotchTheme.textQuaternary)
                                .lineLimit(1)
                            if let b = event.broadcast {
                                Text(b)
                                    .font(NotchTheme.micro)
                                    .foregroundStyle(NotchTheme.textQuaternary.opacity(0.85))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(live ? 0.08 : 0.035))
                    .overlay(alignment: .leading) {
                        if live {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(NotchTheme.positive)
                                .frame(width: 2.5)
                                .padding(.vertical, 8)
                                .padding(.leading, 2)
                        }
                    }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Follow \(event.homeName)") { store.toggleFollow(teamName: event.homeName) }
            Button("Follow \(event.awayName)") { store.toggleFollow(teamName: event.awayName) }
            if let abb = event.homeAbbrev {
                Button("Follow \(abb)") { store.toggleFollow(teamName: abb) }
            }
            if let s = event.linkURL, let url = URL(string: s) {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private func logoStack(_ event: SportsEvent) -> some View {
        HStack(spacing: -4) {
            teamLogo(url: event.awayLogoURL, fallback: event.displayAway)
            teamLogo(url: event.homeLogoURL, fallback: event.displayHome)
        }
        .frame(width: 34)
    }

    private func teamLogo(url: String?, fallback: String) -> some View {
        Group {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        monogram(fallback)
                    }
                }
            } else {
                monogram(fallback)
            }
        }
        .frame(width: 18, height: 18)
        .background(Circle().fill(Color.white.opacity(0.06)))
        .clipShape(Circle())
    }

    private func monogram(_ name: String) -> some View {
        Text(String(name.prefix(2)).uppercased())
            .font(.system(size: 7, weight: .bold, design: .rounded))
            .foregroundStyle(NotchTheme.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusPill(_ status: SportsEventStatus) -> some View {
        let color: Color = {
            switch status {
            case .live: return NotchTheme.positive
            case .final: return NotchTheme.textTertiary
            case .scheduled: return NotchTheme.mediaGlow
            case .delayed: return NotchTheme.caution
            case .other: return NotchTheme.textQuaternary
            }
        }()
        return Text(status.label)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 40, alignment: .leading)
    }
}
