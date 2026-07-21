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
            Image(systemName: "sportscourt.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchTheme.positive)
            if let live = store.liveFollowed {
                Text("\(short(live.awayName)) \(live.awayScore ?? "")–\(live.homeScore ?? "") \(short(live.homeName))")
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

    private func short(_ name: String) -> String {
        let parts = name.split(separator: " ")
        if let last = parts.last, last.count <= 4 { return String(last).uppercased() }
        return String(name.prefix(3)).uppercased()
    }
}

// MARK: - Expanded

private struct ExpandedSportsView: View {
    @ObservedObject var store: SportsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            leagueChips
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if store.currentEvents.isEmpty {
                        empty
                    } else {
                        ForEach(store.currentEvents) { event in
                            eventRow(event)
                        }
                    }
                }
            }
            if let err = store.lastError {
                Text(err)
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack {
            Text("Sports")
                .font(NotchTheme.section)
                .foregroundStyle(NotchTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.7)
            Spacer(minLength: 0)
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            Button {
                store.refresh(league: store.selectedLeague)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
            .buttonStyle(.notchIcon(diameter: 22))
            .help("Refresh scores")
        }
    }

    private var leagueChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SportsLeague.allCases) { league in
                    let selected = store.selectedLeague == league
                    Button {
                        store.select(league)
                    } label: {
                        Text(league.title)
                            .font(NotchTheme.micro.weight(.semibold))
                            .foregroundStyle(selected ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selected ? NotchTheme.chipFillActive : NotchTheme.chipFill)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var empty: some View {
        HStack(spacing: 10) {
            Image(systemName: "sportscourt")
                .foregroundStyle(NotchTheme.textQuaternary)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.isLoading ? "Loading…" : "No games")
                    .font(NotchTheme.caption.weight(.medium))
                    .foregroundStyle(NotchTheme.textSecondary)
                Text("Try another league or check back later.")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    private func eventRow(_ event: SportsEvent) -> some View {
        let live = event.isLive
        return Button {
            if let s = event.linkURL, let url = URL(string: s) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                statusPill(event.status)
                VStack(alignment: .leading, spacing: 2) {
                    if event.league == .f1, let headline = event.headlineScore {
                        Text(headline)
                            .font(NotchTheme.caption.weight(.medium))
                            .foregroundStyle(NotchTheme.textPrimary)
                            .lineLimit(2)
                    } else {
                        Text("\(event.awayName)  @  \(event.homeName)")
                            .font(NotchTheme.caption.weight(.medium))
                            .foregroundStyle(NotchTheme.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            if let a = event.awayScore, let h = event.homeScore {
                                Text("\(a) – \(h)")
                                    .font(NotchTheme.body.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(live ? NotchTheme.positive : NotchTheme.textSecondary)
                            }
                            Text(event.statusText)
                                .font(NotchTheme.micro)
                                .foregroundStyle(NotchTheme.textQuaternary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
                if store.isFollowed(event) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(NotchTheme.caution)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(live ? 0.07 : 0.035))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Follow \(event.homeName)") { store.toggleFollow(teamName: event.homeName) }
            Button("Follow \(event.awayName)") { store.toggleFollow(teamName: event.awayName) }
            if let s = event.linkURL, let url = URL(string: s) {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
            }
        }
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
        return Text(status.label.isEmpty ? "—" : status.label)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(color.opacity(0.15)))
            .frame(width: 52, alignment: .leading)
    }
}
