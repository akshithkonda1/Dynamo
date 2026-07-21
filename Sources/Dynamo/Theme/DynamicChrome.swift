import AppKit
import SwiftUI

// MARK: - Open Clock.app

enum DynamoClockApp {
    /// Opens the native macOS Clock app (Ventura+). Falls back to World Clock
    /// URL scheme or Date & Time settings on older systems.
    @MainActor
    static func open() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.clock") {
            NSWorkspace.shared.open(url)
            return
        }
        let path = "/System/Applications/Clock.app"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        // Last resort: Date & Time settings (pre–Clock.app macOS).
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.datetime") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Ambient breathing rim

/// Soft luminous rim for the collapsed notch while ambient content is live —
/// reads as a Dynamic Island “alive” state without stealing attention.
struct AmbientBreathingRim: View {
    var accent: Color = NotchTheme.calmGlow
    @State private var breathe = false

    var body: some View {
        // Same silhouette as the panel clip — not a rounded rect that fights NotchShape.
        NotchShape(cornerRadius: NotchTheme.radiusCollapsed)
            .strokeBorder(accent.opacity(breathe ? 0.40 : 0.12), lineWidth: 0.9)
            .shadow(color: accent.opacity(breathe ? 0.28 : 0.08), radius: breathe ? 5 : 2, y: 0)
            .onAppear {
                withAnimation(NotchTheme.pulse) { breathe = true }
            }
    }
}

// MARK: - Live clock (shared)

enum DynamoClock {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()

    private static let periodFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "a"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    static func timeString(from date: Date = Date()) -> String {
        timeFormatter.string(from: date)
    }

    static func periodString(from date: Date = Date()) -> String {
        periodFormatter.string(from: date).lowercased()
    }

    static func dayString(from date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }
}

/// Collapsed ambient when nothing else is active — elegant live clock.
/// Content is biased downward so it clears the physical camera housing.
/// Tap opens the native Clock app.
struct AmbientClockView: View {
    var body: some View {
        Button {
            DynamoClockApp.open()
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    Text(DynamoClock.dayString(from: context.date))
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textQuaternary)
                        .textCase(.uppercase)
                    Text(DynamoClock.timeString(from: context.date))
                        .font(NotchTheme.ambientTime.monospacedDigit())
                        .foregroundStyle(NotchTheme.textPrimary)
                    Text(DynamoClock.periodString(from: context.date))
                        .font(NotchTheme.micro.weight(.semibold))
                        .foregroundStyle(NotchTheme.textTertiary)
                    Spacer(minLength: 0)
                    // Quiet “Dynamo is awake” mark
                    Circle()
                        .fill(NotchTheme.positive.opacity(0.85))
                        .frame(width: 5, height: 5)
                        .shadow(color: NotchTheme.positive.opacity(0.6), radius: 3)
                }
                .padding(.horizontal, NotchTheme.ambientInset)
                // Push below the camera cutout / top edge of the physical notch.
                .padding(.top, 10)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help("Open Clock")
    }
}

// MARK: - Quick action chip

struct DynamoQuickAction: View {
    let systemImage: String
    let help: String
    var active: Bool = false
    var tint: Color = NotchTheme.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? tint : NotchTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(active ? tint.opacity(0.18) : NotchTheme.chipFill)
                        .overlay(
                            Circle().strokeBorder(NotchTheme.hairline.opacity(0.6), lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Playing art ring

/// Subtle rotating gradient border around album art while media plays.
struct PlayingArtRing<Content: View>: View {
    var isPlaying: Bool
    @ViewBuilder var content: () -> Content
    @State private var spin = false

    var body: some View {
        ZStack {
            content()
            if isPlaying {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                NotchTheme.mediaGlow,
                                Color.white.opacity(0.35),
                                NotchTheme.calmGlow,
                                NotchTheme.mediaGlow
                            ],
                            center: .center
                        ),
                        lineWidth: 2
                    )
                    .frame(width: 114, height: 114)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                            spin = true
                        }
                    }
                    .allowsHitTesting(false)
            }
        }
    }
}
