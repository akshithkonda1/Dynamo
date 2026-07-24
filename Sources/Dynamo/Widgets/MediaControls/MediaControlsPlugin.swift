import AppKit
import SwiftUI

/// Media controls widget. Talks only to `NowPlayingProvider` — never to a
/// concrete data source. Swapping mock ↔ real happens at construction time.
@MainActor
final class MediaControlsPlugin: ObservableObject, NotchWidgetPlugin, NotchAmbientProviding, NotchSneakPeekProviding, PlayerAppOpening {
    let id = "media"
    let displayName = "Media"
    let systemImage = "music.note"

    var expandedContentHeight: CGFloat { 255 }

    @Published private(set) var info: NowPlayingInfo = .empty
    @Published private(set) var playlists: [String] = []
    @Published var showPlaylistPicker = false
    @Published private(set) var isTrackLiked: Bool = false
    @Published private(set) var isLikeLoading: Bool = false
    var onSneakPeek: ((NotchSneakPeek) -> Void)?

    private let provider: NowPlayingProvider
    private var lastTrackKey: String
    /// Suppress only the first synthetic update after launch (not real skips).
    private var suppressNextPeek = true
    /// After next/previous, poll briefly until the track key changes.
    private var skipProbeWorkItems: [DispatchWorkItem] = []

    init(provider: NowPlayingProvider? = nil) {
        let resolved = provider ?? MockNowPlayingProvider()
        self.provider = resolved
        self.info = resolved.current
        self.lastTrackKey = Self.trackKey(resolved.current)
        resolved.onChange = { [weak self] newValue in
            self?.handleInfoChange(newValue)
        }
    }

    func start() {
        suppressNextPeek = true
        provider.start()
        info = provider.current
        lastTrackKey = Self.trackKey(info)
        MediaPeekPulse.shared.sync(from: info)
        refreshPlaylists()
        if #available(macOS 12.0, *) {
            Task { await MusicKitBridge.shared.requestAuthorizationIfNeeded() }
        }
    }

    func stop() {
        cancelSkipProbe()
        provider.stop()
    }

    private func handleInfoChange(_ newValue: NowPlayingInfo) {
        let previous = info
        info = newValue
        MediaPeekPulse.shared.sync(from: newValue)

        let key = Self.trackKey(newValue)
        let previousKey = lastTrackKey
        let isNewTrack = key != previousKey

        // Always remember the latest identity so skip-probes compare correctly.
        lastTrackKey = key

        // First post-launch snapshot only — never suppress a real track change after that.
        if suppressNextPeek {
            suppressNextPeek = false
            // If launch already has a playing track, don't peek until the user skips.
            return
        }

        guard !newValue.title.isEmpty,
              newValue.title != NowPlayingInfo.empty.title
        else { return }

        if isNewTrack {
            // Reset like state; check library async once MusicKit catalog ID arrives.
            isTrackLiked = false
            if let catalogID = newValue.musicKitCatalogID, #available(macOS 12.0, *) {
                Task { @MainActor in
                    self.isTrackLiked = await MusicKitBridge.shared.isInLibrary(catalogID: catalogID)
                }
            }
            // Forward *or* backward skip, auto-advance, playlist jump — always peek.
            presentTrackPeek(newValue)
            return
        }

        // Same track: only refresh peek when cover art arrives after the title did.
        let artArrived = previous.artworkData == nil && newValue.artworkData != nil
        if artArrived {
            presentTrackPeek(newValue)
        }
    }

    private func presentTrackPeek(_ info: NowPlayingInfo) {
        let subtitle: String
        if !info.artist.isEmpty, !info.album.isEmpty {
            subtitle = "\(info.artist) · \(info.album)"
        } else if !info.artist.isEmpty {
            subtitle = info.artist
        } else {
            subtitle = info.album
        }
        onSneakPeek?(NotchSneakPeek(
            systemImage: "music.note",
            title: info.title,
            subtitle: subtitle,
            urgency: .normal,
            artworkData: info.artworkData,
            detail: info.playlistName ?? "",
            style: .media
        ))
    }

    private static func trackKey(_ info: NowPlayingInfo) -> String {
        // Include playlist when known so “same song, different context” still peeks.
        "\(info.title)\u{1}\(info.artist)\u{1}\(info.album)\u{1}\(info.playlistName ?? "")"
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedMediaView(plugin: self))
    }

    func togglePlayPause() { provider.togglePlayPause() }

    func nextTrack() {
        provider.nextTrack()
        // MediaRemote/AppleScript often lag; actively probe for the new track.
        probeForTrackChange(reason: "next")
    }

    func previousTrack() {
        provider.previousTrack()
        probeForTrackChange(reason: "previous")
    }

    /// After skip, re-check now-playing a few times so peek always fires
    /// even if the provider’s first onChange is delayed or empty.
    private func probeForTrackChange(reason: String) {
        cancelSkipProbe()
        let baseline = lastTrackKey
        // Staggered probes: 0.15s … ~1.8s covers Music + Spotify.
        let delays: [TimeInterval] = [0.12, 0.28, 0.5, 0.85, 1.3, 1.9]
        for delay in delays {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Provider may have already pushed onChange; if not, force a path
                // through handleInfoChange with whatever is current now.
                let current = self.provider.current
                let key = Self.trackKey(current)
                if key != baseline, !current.title.isEmpty,
                   current.title != NowPlayingInfo.empty.title {
                    self.handleInfoChange(current)
                    self.cancelSkipProbe()
                } else if key == baseline {
                    // Nudge: re-assign onChange path with same object if fields updated
                    // (e.g. title filled in after empty).
                    self.handleInfoChange(current)
                }
            }
            skipProbeWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func cancelSkipProbe() {
        for item in skipProbeWorkItems { item.cancel() }
        skipProbeWorkItems.removeAll()
    }

    /// Open Music / Spotify and reveal the current track / playlist context.
    func openConnectedApp() {
        provider.openConnectedApp()
    }

    /// Tray re-tap → jump to the connected player app.
    func openPlayerApp() {
        openConnectedApp()
    }

    func refreshPlaylists() {
        playlists = provider.availablePlaylists()
    }

    func playPlaylist(_ name: String) {
        provider.playPlaylist(named: name)
        showPlaylistPicker = false
    }

    func seek(to elapsed: TimeInterval) {
        provider.seek(to: elapsed)
    }

    func toggleShuffle() { provider.toggleShuffle() }
    func toggleRepeat() { provider.toggleRepeat() }

    func toggleLike() {
        guard let catalogID = info.musicKitCatalogID else { return }
        guard #available(macOS 12.0, *) else { return }
        isLikeLoading = true
        Task { @MainActor in
            let liked = await MusicKitBridge.shared.toggleLike(catalogID: catalogID)
            isTrackLiked = liked
            isLikeLoading = false
        }
    }

    // MARK: - NotchAmbientProviding

    var isAmbientActive: Bool { info.isPlaying }
    var ambientPriority: Int { 100 }
    func ambientView() -> AnyView { AnyView(AmbientMediaView(plugin: self)) }
}

// MARK: - Ambient (collapsed)

private struct AmbientMediaView: View {
    @ObservedObject var plugin: MediaControlsPlugin
    @ObservedObject private var meeting = MeetingMode.shared
    @ObservedObject private var pulse = MediaPeekPulse.shared

    private var dimmed: Bool { meeting.shouldDimMediaAmbient() }

    var body: some View {
        HStack(spacing: 7) {
            artThumb
                .onTapGesture { plugin.openConnectedApp() }
                .help("Open \(playerLabel)")
            VStack(alignment: .leading, spacing: 0) {
                if !plugin.info.title.isEmpty, plugin.info.title != NowPlayingInfo.empty.title {
                    Text(plugin.info.title)
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .lineLimit(1)
                }
                if !plugin.info.artist.isEmpty {
                    Text(plugin.info.artist)
                        .font(NotchTheme.micro)
                        .foregroundStyle(NotchTheme.textTertiary)
                        .lineLimit(1)
                }
                if let remainingLabel {
                    Text(remainingLabel)
                        .font(NotchTheme.micro.monospacedDigit())
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 100, alignment: .leading)
            Spacer(minLength: 0)
            if !dimmed {
                MusicBarsView(
                    isPlaying: plugin.info.isPlaying,
                    barCount: 6,
                    maxHeight: 16,
                    color: pulse.palette.accent.mixed(with: pulse.palette.highlight, t: 0.3).color.opacity(0.9)
                )
                    .fixedSize()
                if let dev = AudioOutputController.shared.devices.first(where: { $0.id == AudioOutputController.shared.selectedID }),
                   !dev.name.localizedCaseInsensitiveContains("built-in"),
                   !dev.name.localizedCaseInsensitiveContains("speakers") {
                    Text(dev.name)
                        .font(.system(size: 7.5))
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, NotchTheme.ambientInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(dimmed ? 0.42 : 1)
    }

    private var remainingLabel: String? {
        let info = plugin.info
        guard info.duration > 1, info.elapsed >= 0 else { return nil }
        let left = max(0, Int((info.duration - info.elapsed).rounded()))
        let m = left / 60
        let s = left % 60
        return String(format: "-%d:%02d", m, s)
    }

    private var playerLabel: String {
        switch plugin.info.sourceApp {
        case .spotify: return "Spotify"
        case .music, .other, .none: return "Music"
        }
    }

    @ViewBuilder
    private var artThumb: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        let duration = plugin.info.duration
        let elapsed = plugin.info.elapsed
        let showRing = duration > 1 && elapsed >= 0
        let fraction = showRing ? min(1, max(0, elapsed / duration)) : 0

        ZStack {
            if showRing {
                let ringColor = pulse.palette.primary.color
                Circle()
                    .stroke(ringColor.opacity(0.18), lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(ringColor.opacity(0.80),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 22, height: 22)
                    .rotationEffect(.degrees(-90))
            }
            if let data = plugin.info.artworkData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 18, height: 18)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .contentShape(shape)
            } else {
                shape
                    .fill(NotchTheme.chipFill)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(NotchTheme.textSecondary)
                    )
                    .contentShape(shape)
            }
        }
        .frame(width: 22, height: 22)
    }
}

// MARK: - Expanded

private struct ExpandedMediaView: View {
    @ObservedObject var plugin: MediaControlsPlugin
    @ObservedObject private var volume = SystemVolumeController.shared
    /// Local scrub value while the user is dragging the timeline.
    @State private var scrubElapsed: Double?
    @State private var displayElapsed: Double = 0
    @State private var lastTick: Date = .now
    /// System volume lives in a collapsible subsection under Media (not a tray tab).
    @State private var showSystemVolume: Bool = UserDefaults.standard.bool(forKey: "dynamo.media.showSystemVolume")

    private var hasTrack: Bool {
        plugin.info.isPlaying || plugin.info.title != NowPlayingInfo.empty.title
    }

    private var effectiveElapsed: Double {
        if let scrubElapsed { return scrubElapsed }
        return displayElapsed
    }

    var body: some View {
        HStack(alignment: .center, spacing: NotchTheme.spaceMD) {
            artwork

            VStack(alignment: .leading, spacing: 6) {
                header
                if hasTrack {
                    MarqueeText(
                        text: plugin.info.title,
                        font: .system(size: 16, weight: .semibold),
                        foreground: NotchTheme.textPrimary,
                        speed: 32
                    )
                    .frame(height: 20)
                    .onTapGesture { plugin.openConnectedApp() }
                    MarqueeText(
                        text: subtitle,
                        font: NotchTheme.caption,
                        foreground: NotchTheme.textSecondary,
                        speed: 28
                    )
                    .frame(height: 16)
                    timelineBar
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing playing")
                            .font(NotchTheme.body.weight(.semibold))
                            .foregroundStyle(NotchTheme.textPrimary)
                        Text("Start Music or Spotify — transport still works.")
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textTertiary)
                        Button {
                            plugin.openConnectedApp()
                        } label: {
                            NotchChipLabel(title: "Open \(playerAppName)", systemImage: "arrow.up.right")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }

                systemVolumeSection

                if hasTrack {
                    playlistRow
                }

                // Queue strip — hidden when volume section is open to preserve height budget
                if hasTrack, !plugin.info.upcomingTracks.isEmpty, !showSystemVolume {
                    QueuePeekView(tracks: plugin.info.upcomingTracks)
                }

                Spacer(minLength: 2)
                transportRow
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear {
            plugin.refreshPlaylists()
            SystemVolumeController.shared.start()
            SystemVolumeController.shared.refreshFromSystem()
            displayElapsed = plugin.info.elapsed
            lastTick = .now
        }
        .onChange(of: plugin.info.elapsed) { newValue in
            // Don't yank the knob while the user is scrubbing.
            guard scrubElapsed == nil else { return }
            // Accept remote updates that jump more than a small delta (seek / new track).
            if abs(newValue - displayElapsed) > 1.25 || !plugin.info.isPlaying {
                displayElapsed = newValue
            }
            lastTick = .now
        }
        .onChange(of: plugin.info.title) { _ in
            displayElapsed = plugin.info.elapsed
            scrubElapsed = nil
            lastTick = .now
        }
        // 2 Hz is enough for a smooth scrubber without 4 Hz main-thread ticks.
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { now in
            guard scrubElapsed == nil, plugin.info.isPlaying, plugin.info.duration > 0 else {
                lastTick = now
                return
            }
            let dt = now.timeIntervalSince(lastTick)
            lastTick = now
            let next = min(plugin.info.duration, displayElapsed + dt)
            displayElapsed = next
        }
    }

    private var playerAppName: String {
        switch plugin.info.sourceApp {
        case .spotify: return "Spotify"
        case .music, .other, .none: return "Music"
        }
    }

    private var subtitle: String {
        if hasTrack {
            return plugin.info.artist.isEmpty ? plugin.info.album : plugin.info.artist
        }
        return "Play something and it'll show up here."
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(plugin.info.isPlaying ? "Now Playing" : "Media")
                .font(NotchTheme.section)
                .foregroundStyle(NotchTheme.textTertiary)
                .textCase(.uppercase)
            if plugin.info.isPlaying {
                MusicBarsView(
                    isPlaying: plugin.info.isPlaying,
                    barCount: 6,
                    maxHeight: 16,
                    color: NotchTheme.mediaGlow.opacity(0.95)
                )
                    .fixedSize()
            }
            // Explicit badge
            if plugin.info.isExplicit {
                Text("E")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(NotchTheme.textTertiary)
                    .frame(width: 14, height: 14)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(NotchTheme.textQuaternary, lineWidth: 1)
                    )
            }
            // Genre chip
            if let genre = plugin.info.genre {
                Text(genre)
                    .font(NotchTheme.micro.weight(.medium))
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .lineLimit(1)
                    .fixedSize()
            }
            // Release year
            if let year = plugin.info.releaseYear {
                Text(String(year))
                    .font(NotchTheme.micro.monospacedDigit())
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            // Icon that opens Music / Spotify
            Image(systemName: playerAppName == "Spotify" ? "music.note.list" : "music.note.house")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(NotchTheme.chipFill))
                .contentShape(Circle())
                .onTapGesture { plugin.openConnectedApp() }
                .help("Open \(playerAppName)")
        }
    }

    /// Scrubbable playback position — the “time bar”, not a content scrollbar.
    private var timelineBar: some View {
        let duration = max(plugin.info.duration, 0)
        let canSeek = duration > 0.5 && hasTrack
        return VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: {
                        canSeek ? min(effectiveElapsed, duration) : 0
                    },
                    set: { newValue in
                        scrubElapsed = newValue
                        displayElapsed = newValue
                    }
                ),
                in: 0...max(duration, 0.001),
                onEditingChanged: { editing in
                    if editing {
                        scrubElapsed = effectiveElapsed
                    } else if let value = scrubElapsed {
                        plugin.seek(to: value)
                        displayElapsed = value
                        scrubElapsed = nil
                        lastTick = .now
                    }
                }
            )
            .controlSize(.mini)
            .disabled(!canSeek)
            .opacity(canSeek ? 1 : 0.35)
            .tint(Color.white.opacity(0.85))

            HStack {
                Text(Self.formatTime(effectiveElapsed))
                    .font(NotchTheme.micro.monospacedDigit())
                    .foregroundStyle(NotchTheme.textTertiary)
                Spacer(minLength: 0)
                Text(canSeek ? Self.formatTime(duration) : "--:--")
                    .font(NotchTheme.micro.monospacedDigit())
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
        }
        .padding(.top, 2)
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Collapsible subsection under Media — system output volume (AppleScript UI %).
    private var systemVolumeSection: some View {
        NotchCard(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showSystemVolume.toggle()
                        UserDefaults.standard.set(showSystemVolume, forKey: "dynamo.media.showSystemVolume")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(showSystemVolume ? 90 : 0))
                            .foregroundStyle(NotchTheme.textQuaternary)
                        Image(systemName: volumeIcon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NotchTheme.textSecondary)
                        Text("System Volume")
                            .font(NotchTheme.micro.weight(.semibold))
                            .foregroundStyle(NotchTheme.textTertiary)
                        Spacer(minLength: 0)
                        Text(volume.isMuted ? "Mute" : "\(volume.percent)%")
                            .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                            .foregroundStyle(NotchTheme.textPrimary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showSystemVolume ? "Hide system volume" : "Show system volume controls")

                if showSystemVolume {
                    VStack(alignment: .leading, spacing: 6) {
                        OutputDeviceMenu()

                        HStack(spacing: 8) {
                            Button {
                                volume.toggleMute()
                            } label: {
                                Image(systemName: volumeIcon)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(NotchTheme.textPrimary)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(NotchTheme.chipFillActive))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(volume.isMuted ? "Unmute" : "Mute")

                            Slider(
                                value: Binding(
                                    get: { Double(volume.isMuted ? 0 : volume.level) },
                                    set: { volume.setLevel(Float($0)) }
                                ),
                                in: 0...1
                            )
                            .controlSize(.mini)
                            .tint(Color.white.opacity(0.9))
                            .help("Change Mac system volume")

                            Button {
                                volume.nudge(by: -0.0625)
                            } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 10, weight: .bold))
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(NotchTheme.chipFill))
                            }
                            .buttonStyle(.plain)

                            Button {
                                volume.nudge(by: 0.0625)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .bold))
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(NotchTheme.chipFill))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.top, 2)
    }

    private var volumeIcon: String {
        if volume.isMuted || volume.level <= 0.001 { return "speaker.slash.fill" }
        if volume.level < 0.33 { return "speaker.wave.1.fill" }
        if volume.level < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    @ViewBuilder
    private var playlistRow: some View {
        if hasTrack || !plugin.playlists.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                MarqueeText(
                    text: plugin.info.playlistName ?? "No playlist",
                    font: NotchTheme.micro,
                    foreground: NotchTheme.textTertiary,
                    speed: 24
                )
                .frame(height: 14)
                Spacer(minLength: 0)
                if !plugin.playlists.isEmpty {
                    Menu {
                        ForEach(plugin.playlists, id: \.self) { name in
                            Button(name) { plugin.playPlaylist(name) }
                        }
                    } label: {
                        Text("Switch")
                            .font(NotchTheme.micro.weight(.semibold))
                            .foregroundStyle(NotchTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(NotchTheme.chipFill))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Play a different Music playlist")
                }
            }
            .onTapGesture {
                plugin.openConnectedApp()
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let corner: CGFloat = 16
        PlayingArtRing(isPlaying: plugin.info.isPlaying, size: 104, cornerRadius: corner) {
            Group {
                if let data = plugin.info.artworkData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [NotchTheme.chipFillActive, NotchTheme.chipFill],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: "music.note")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(NotchTheme.textTertiary)
                    }
                }
            }
            .frame(width: 104, height: 104)
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(5)
                    .background(Circle().fill(Color.black.opacity(0.45)))
                    .padding(6)
            }
        }
        .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
        .help("Open in \(playerAppName)")
        .onTapGesture { plugin.openConnectedApp() }
    }

    private var transportRow: some View {
        HStack(spacing: 10) {
            Button {
                plugin.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(plugin.info.isShuffling ? NotchTheme.textPrimary : NotchTheme.textQuaternary)
            }
            .buttonStyle(.plain)
            .help("Toggle Shuffle")

            transportButton(
                "backward.fill",
                accessibility: "Previous",
                size: 15,
                diameter: 38
            ) { plugin.previousTrack() }
            transportButton(
                plugin.info.isPlaying ? "pause.fill" : "play.fill",
                accessibility: plugin.info.isPlaying ? "Pause" : "Play",
                size: 17,
                diameter: 46,
                prominent: true
            ) { plugin.togglePlayPause() }
            transportButton(
                "forward.fill",
                accessibility: "Next",
                size: 15,
                diameter: 38
            ) { plugin.nextTrack() }

            Button {
                plugin.toggleRepeat()
            } label: {
                Image(systemName: plugin.info.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(plugin.info.repeatMode == .none ? NotchTheme.textQuaternary : NotchTheme.textPrimary)
            }
            .buttonStyle(.plain)
            .help("Toggle Repeat")

            Spacer(minLength: 0)

            // Like / Add to Library button — only visible when MusicKit has a catalog ID
            Button {
                plugin.toggleLike()
            } label: {
                Group {
                    if plugin.isLikeLoading {
                        ProgressView().controlSize(.mini).scaleEffect(0.7)
                    } else {
                        Image(systemName: plugin.isTrackLiked ? "heart.fill" : "heart")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(
                                plugin.isTrackLiked
                                    ? Color(red: 1, green: 0.22, blue: 0.37)
                                    : NotchTheme.textQuaternary
                            )
                    }
                }
                .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(plugin.info.musicKitCatalogID == nil || plugin.isLikeLoading)
            .opacity(plugin.info.musicKitCatalogID == nil ? 0 : 1)
            .animation(NotchTheme.quick, value: plugin.isTrackLiked)
            .help(plugin.isTrackLiked ? "In Library" : "Add to Library")
        }
    }

    private func transportButton(
        _ systemName: String,
        accessibility: String,
        size: CGFloat,
        diameter: CGFloat,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        // Real `Button` + shared style so first-clicks fire on the nonactivating
        // notch panel (plain Image + onTapGesture often eats the first press).
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
        }
        .buttonStyle(.notchIcon(diameter: diameter, prominent: prominent))
        .help(accessibility)
        .accessibilityLabel(accessibility)
    }
}

// MARK: - Output device menu

private struct OutputDeviceMenu: View {
    @ObservedObject private var outputs = AudioOutputController.shared

    var body: some View {
        Menu {
            ForEach(outputs.devices) { device in
                Button {
                    outputs.select(id: device.id)
                } label: {
                    HStack {
                        Text(device.name)
                        if device.id == outputs.selectedID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(currentName)
                    .font(NotchTheme.micro)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(NotchTheme.textQuaternary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help("Choose audio output")
        .onAppear { outputs.refresh() }
    }

    private var currentName: String {
        if let id = outputs.selectedID,
           let match = outputs.devices.first(where: { $0.id == id }) {
            return match.name
        }
        return SystemVolumeController.shared.deviceName ?? "Output"
    }
}
