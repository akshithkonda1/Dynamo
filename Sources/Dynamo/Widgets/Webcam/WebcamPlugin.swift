import AppKit
import SwiftUI

/// Webcam mirror widget. Camera runs only while this tab is active in the
/// expanded notch (not on app launch). Mirror-on is the default and is
/// **remembered** across relaunches via UserDefaults.
@MainActor
final class WebcamPlugin: ObservableObject, NotchWidgetPlugin, WidgetSettingsProviding {
    let id = "webcam"
    let displayName = "Webcam"
    let systemImage = "camera.fill"

    let controller = WebcamCaptureController()

    func start() {
        // Sync auth quietly only — never prompt or start the camera until the
        // Webcam tab actually appears (privacy: no light on app launch).
        controller.refreshAuthState(requestIfNeeded: false)
    }

    func stop() {
        controller.stopNow()
    }

    func expandedView() -> AnyView {
        AnyView(ExpandedWebcamView(plugin: self))
    }

    func settingsView() -> AnyView {
        AnyView(WebcamSettingsView(plugin: self))
    }
}

// MARK: - Expanded view

private struct ExpandedWebcamView: View {
    @ObservedObject var plugin: WebcamPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
            HStack {
                Text("Webcam")
                    .font(NotchTheme.section)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .textCase(.uppercase)
                Spacer()
                if plugin.controller.authState == .authorized {
                    Toggle(isOn: Binding(
                        get: { plugin.controller.isMirrored },
                        set: { plugin.controller.isMirrored = $0 }
                    )) {
                        Text("Mirror")
                            .font(NotchTheme.micro)
                            .foregroundStyle(NotchTheme.textTertiary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Flip horizontally like a bathroom mirror. Preference is saved.")
                }
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            plugin.controller.start()
        }
        .onDisappear {
            // Debounced inside the controller so animation churn doesn't cut the feed.
            plugin.controller.stop()
        }
        .onChange(of: plugin.controller.authState) { newValue in
            if newValue == .authorized {
                plugin.controller.start()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch plugin.controller.authState {
        case .notDetermined:
            Text("Requesting camera access…")
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Text("Camera access denied.")
                    .font(NotchTheme.caption)
                    .foregroundStyle(NotchTheme.textSecondary)
                Text("Enable it in System Settings → Privacy & Security → Camera, then reopen this tab.")
                    .font(NotchTheme.micro)
                    .foregroundStyle(NotchTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Camera Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .unavailable:
            Text("No camera available on this Mac.")
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .authorized:
            ZStack {
                WebcamPreviewView(
                    session: plugin.controller.session,
                    isMirrored: plugin.controller.isMirrored,
                    isRunning: plugin.controller.isRunning
                )
                .clipShape(RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous))

                if !plugin.controller.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Settings

private struct WebcamSettingsView: View {
    @ObservedObject var plugin: WebcamPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Mirror video (selfie flip)", isOn: Binding(
                get: { plugin.controller.isMirrored },
                set: { plugin.controller.isMirrored = $0 }
            ))
            Text("When on, the feed is flipped horizontally like a real mirror. This setting is remembered across relaunches. The camera only runs while the Webcam tab is open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch plugin.controller.authState {
        case .authorized: return plugin.controller.isRunning ? .green : .yellow
        case .denied, .unavailable: return .red
        case .notDetermined: return .orange
        }
    }

    private var statusText: String {
        switch plugin.controller.authState {
        case .authorized:
            return plugin.controller.isRunning ? "Camera running" : "Camera idle (open Webcam tab to start)"
        case .denied: return "Camera access denied"
        case .unavailable: return "No camera available"
        case .notDetermined: return "Camera permission not requested yet"
        }
    }
}
