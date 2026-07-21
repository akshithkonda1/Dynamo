import AppKit
import SwiftUI

/// Webcam mirror widget — presentation modeled after Boring Notch’s
/// `CameraPreviewView`: square, always-mirrored, rounded (circle by default),
/// dark “Mirror” placeholder, tap to start/stop.
@MainActor
final class WebcamPlugin: ObservableObject, NotchWidgetPlugin, WidgetSettingsProviding {
    let id = "webcam"
    let displayName = "Webcam"
    let systemImage = "web.camera"

    /// Preferred expanded panel height for the square mirror tile + chrome.
    var expandedContentHeight: CGFloat { 220 }

    let controller = WebcamCaptureController()

    private static let shapeKey = "dynamo.webcam.mirrorShape"

    /// `true` = circle (Boring Notch style), `false` = rounded rectangle.
    @Published var isCircular: Bool {
        didSet { UserDefaults.standard.set(isCircular, forKey: Self.shapeKey) }
    }

    init() {
        if UserDefaults.standard.object(forKey: Self.shapeKey) == nil {
            // Default to circle like Boring Notch’s popular mirror look.
            isCircular = true
        } else {
            isCircular = UserDefaults.standard.bool(forKey: Self.shapeKey)
        }
    }

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

// MARK: - Expanded (Boring Notch–style mirror tile)

private struct ExpandedWebcamView: View {
    @ObservedObject var plugin: WebcamPlugin

    private var controller: WebcamCaptureController { plugin.controller }

    private var cornerRadius: CGFloat {
        plugin.isCircular ? 1000 : 13
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            mirrorTile
                .frame(maxWidth: 168, maxHeight: 168)
                .aspectRatio(1, contentMode: .fit)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if controller.authState == .authorized || controller.authState == .notDetermined {
                shapeToggle
                    .padding(.trailing, 2)
                    .padding(.top, 2)
            }
        }
        .onAppear {
            // Match Boring Notch: open tab → request/start when possible.
            controller.requestAccessIfNeeded()
            if controller.authState == .authorized {
                controller.start()
            }
        }
        .onDisappear {
            controller.stop()
        }
        .onChange(of: controller.authState) { newValue in
            if newValue == .authorized {
                controller.start()
            }
        }
    }

    private var shapeToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                plugin.isCircular.toggle()
            }
        } label: {
            Image(systemName: plugin.isCircular ? "circle" : "rectangle.roundedtop")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.textTertiary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(NotchTheme.chipFill))
        }
        .buttonStyle(.plain)
        .help(plugin.isCircular ? "Use rounded square" : "Use circle")
    }

    private var mirrorTile: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                // Live feed — square + aspect-fill, optional selfie mirror
                // (default ON, same as Boring Notch).
                if controller.authState == .authorized {
                    WebcamPreviewView(
                        session: controller.session,
                        isMirrored: controller.isMirrored,
                        isRunning: controller.isRunning
                    )
                    .opacity(controller.isRunning ? 1 : 0)
                }

                // Placeholder when idle / denied — dark tile + camera icon.
                if !controller.isRunning {
                    placeholder(side: side)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onTapGesture { handleTap() }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func placeholder(side: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255))
            VStack(spacing: 8) {
                Image(systemName: placeholderIcon)
                    .font(.system(size: max(22, side / 3.5), weight: .regular))
                    .foregroundStyle(Color.gray)
                Text(placeholderTitle)
                    .font(.caption2)
                    .foregroundStyle(Color.gray)
            }
            if controller.authState == .notDetermined || (controller.authState == .authorized && !controller.isRunning) {
                // Subtle “tap to start” affordance while idle/authorized.
            }
        }
    }

    private var placeholderIcon: String {
        switch controller.authState {
        case .denied: return "exclamationmark.triangle"
        case .unavailable: return "video.slash"
        default: return "web.camera"
        }
    }

    private var placeholderTitle: String {
        switch controller.authState {
        case .denied: return "Access Denied"
        case .unavailable: return "No Camera"
        case .notDetermined: return "Mirror"
        case .authorized: return controller.isRunning ? "" : "Mirror"
        }
    }

    private func handleTap() {
        switch controller.authState {
        case .authorized:
            if controller.isRunning {
                controller.stopNow()
            } else {
                controller.start()
            }
        case .notDetermined:
            controller.requestAccessIfNeeded()
        case .denied:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        case .unavailable:
            break
        }
    }
}

// MARK: - Settings

private struct WebcamSettingsView: View {
    @ObservedObject var plugin: WebcamPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Mirror video (selfie flip)", isOn: Binding(
                get: { plugin.controller.isMirrored },
                set: { plugin.controller.isMirrored = $0 }
            ))
            Toggle("Circular mirror", isOn: Binding(
                get: { plugin.isCircular },
                set: { plugin.isCircular = $0 }
            ))
            Text("Presentation matches Boring Notch: a square mirror tile, tap to start/stop the camera. The camera only runs while this tab is open.")
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
            return plugin.controller.isRunning ? "Camera running — tap mirror to stop" : "Tap mirror to start"
        case .denied: return "Camera access denied"
        case .unavailable: return "No camera available"
        case .notDetermined: return "Camera permission not requested yet"
        }
    }
}
