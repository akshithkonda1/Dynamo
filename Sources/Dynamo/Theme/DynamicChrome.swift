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
/// Hairline only on the *sides/top of the hang* — bottom edge stays un-stroked
/// so it never reads as a second hard border under the island.
struct AmbientBreathingRim: View {
    var accent: Color = NotchTheme.calmGlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        // Glow bloom only — no strokeBorder (that painted a hard bottom rim).
        NotchShape(cornerRadius: NotchTheme.radiusCollapsed)
            .fill(Color.clear)
            .shadow(
                color: accent.opacity(reduceMotion ? 0.08 : (breathe ? 0.22 : 0.07)),
                radius: reduceMotion ? 1.5 : (breathe ? 4 : 1.5),
                y: 0
            )
            .overlay {
                // Very soft inner top sheen; bottom of path stays clean.
                NotchShape(cornerRadius: NotchTheme.radiusCollapsed)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                accent.opacity(reduceMotion ? 0.12 : (breathe ? 0.20 : 0.06)),
                                accent.opacity(0.02),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            }
            .onAppear {
                guard !reduceMotion else { return }
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
            // Minute-level updates only (clock shows h:mm) — far cheaper than 1 Hz.
            TimelineView(.periodic(from: .now, by: 15)) { context in
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

/// Flush “now playing” accent on album art — sits *on* the art edge (not a
/// floating larger frame) so it never looks like a second border at launch.
struct PlayingArtRing<Content: View>: View {
    var isPlaying: Bool
    var size: CGFloat = 108
    var cornerRadius: CGFloat = 16
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        content()
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay {
                // Single hairline always flush to the clip.
                shape
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            }
            .overlay {
                if isPlaying {
                    // Soft pulse on the same path — no oversized rotated rect.
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    NotchTheme.mediaGlow.opacity(pulse ? 0.55 : 0.22),
                                    Color.white.opacity(pulse ? 0.28 : 0.10),
                                    NotchTheme.mediaGlow.opacity(pulse ? 0.35 : 0.14)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.1
                        )
                        .shadow(
                            color: NotchTheme.mediaGlow.opacity(pulse ? 0.35 : 0.12),
                            radius: pulse ? 5 : 2
                        )
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                            value: pulse
                        )
                        .onAppear {
                            guard !reduceMotion else { return }
                            pulse = true
                        }
                        .allowsHitTesting(false)
                }
            }
    }
}
