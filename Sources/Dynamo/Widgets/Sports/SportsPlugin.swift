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

    var isAmbientActive: Bool { store.liveFollowed != nil || store.nextFollowedScheduled != nil }
    var ambientPriority: Int { store.liveFollowed != nil ? 55 : 22 }

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

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 6) {
            if let live = store.liveFollowed {
                Circle()
                    .fill(NotchTheme.positive)
                    .frame(width: 6, height: 6)
                Text(live.league.shortTitle)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(NotchTheme.textTertiary)
                if let score = live.scoreLine {
                    Text("\(live.displayAway) \(score) \(live.displayHome)")
                        .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                } else {
                    Text("\(live.displayAway) @ \(live.displayHome)")
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                }
            } else if let next = store.nextFollowedScheduled {
                Image(systemName: "calendar")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                Text("\(next.displayAway) @ \(next.displayHome)")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textSecondary)
                    .lineLimit(1)
                if let date = next.startDate {
                    Text(Self.timeFmt.string(from: date))
                        .font(NotchTheme.micro.monospacedDigit())
                        .foregroundStyle(NotchTheme.textTertiary)
                }
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
        VStack(alignment: .leading, spacing: 7) {
            header
            categoryRow
            leagueChips
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if store.currentEvents.isEmpty {
                        empty
                    } else if store.browseMode == .liveAll {
                        section(title: "Live now", events: store.liveEvents, accent: NotchTheme.positive)
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
                Text(subtitle)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if store.globalLiveCount > 0 {
                Text("\(store.globalLiveCount) live")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(NotchTheme.positive)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(NotchTheme.positive.opacity(0.15)))
            }
            if store.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.65)
            }
            Button { store.refreshCurrent() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            .buttonStyle(.notchIcon(diameter: 22))
            .help("Refresh scores")
        }
    }

    private var subtitle: String {
        switch store.browseMode {
        case .liveAll: return "All live · multi-league"
        case .league(let l): return "\(l.title) · free ESPN feed"
        }
    }

    private var categoryRow: some View {
        HStack(spacing: 5) {
            ForEach(SportsCategory.allCases) { cat in
                let selected = store.categoryFilter == cat
                Button {
                    store.categoryFilter = cat
                } label: {
                    Text(cat.title)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(selected ? NotchTheme.textPrimary : NotchTheme.textQuaternary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button {
                store.followOnly.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: store.followOnly ? "star.fill" : "star")
                        .font(.system(size: 8, weight: .bold))
                    Text("Following")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(store.followOnly ? NotchTheme.caution : NotchTheme.textQuaternary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(store.followOnly ? NotchTheme.caution.opacity(0.14) : Color.white.opacity(0.04))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var leagueChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                // All Live aggregate
                chip(
                    title: "LIVE",
                    selected: store.browseMode == .liveAll,
                    accent: NotchTheme.positive
                ) {
                    store.selectLiveAll()
                }

                ForEach(store.chipLeagues) { league in
                    chip(
                        title: league.shortTitle,
                        selected: store.selectedLeague == league,
                        accent: nil
                    ) {
                        store.select(league)
                    }
                }
            }
        }
    }

    private func chip(title: String, selected: Bool, accent: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(NotchTheme.micro.weight(.semibold))
                .foregroundStyle(
                    selected
                        ? (accent ?? NotchTheme.textPrimary)
                        : NotchTheme.textTertiary
                )
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            selected
                                ? (accent?.opacity(0.16) ?? NotchTheme.chipFillActive)
                                : NotchTheme.chipFill
                        )
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func section(title: String, events: [SportsEvent], accent: Color) -> some View {
        if !events.isEmpty {
            Text(title)
                .font(NotchTheme.micro.weight(.semibold))
                .foregroundStyle(NotchTheme.textQuaternary)
                .padding(.top, 2)
            ForEach(events) { event in
                eventRow(event)
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
                Text(store.isLoading ? "Loading scores…" : "No games right now")
                    .font(NotchTheme.caption.weight(.medium))
                    .foregroundStyle(NotchTheme.textSecondary)
                Text("Try LIVE, another league, or US / Soccer filters")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    private var footerMeta: some View {
        Group {
            if let err = store.lastError, store.currentEvents.isEmpty {
                Text(err)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
            } else if let updated = store.lastUpdated {
                Text("Updated \(Self.timeFormatter.string(from: updated)) · \(store.chipLeagues.count)+ leagues")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary.opacity(0.85))
            }
        }
    }

    private func eventRow(_ event: SportsEvent) -> some View {
        let live = event.isLive
        return Button {
            if let s = event.linkURL, let url = URL(string: s) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                statusPill(event.status)

                // League badge when browsing All Live
                if store.browseMode == .liveAll {
                    Text(event.league.shortTitle)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(NotchTheme.textTertiary)
                        .frame(width: 36, alignment: .leading)
                }

                if !isHeadlineSport(event.league) {
                    logoStack(event)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if isHeadlineSport(event.league), let headline = event.headlineScore {
                        Text(headline)
                            .font(NotchTheme.caption.weight(.medium))
                            .foregroundStyle(NotchTheme.textPrimary)
                            .lineLimit(2)
                    } else {
                        HStack(spacing: 5) {
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
                        HStack(spacing: 7) {
                            if let score = event.scoreLine {
                                Text(score)
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
            .padding(.vertical, 6)
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
            if let abb = event.awayAbbrev {
                Button("Follow \(abb)") { store.toggleFollow(teamName: abb) }
            }
            if let s = event.linkURL, let url = URL(string: s) {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private func isHeadlineSport(_ league: SportsLeague) -> Bool {
        switch league {
        case .f1, .pga, .ufc, .tennis: return true
        default: return false
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
            .frame(width: 36, alignment: .leading)
    }
}
