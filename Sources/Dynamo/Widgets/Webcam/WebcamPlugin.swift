import AppKit
import SwiftUI

/// Webcam mirror widget — presentation modeled after Boring Notch’s
/// `CameraPreviewView`: square, always-mirrored, rounded (circle by default),
/// dark “Mirror” placeholder, tap to start/stop. Plus device / zoom / snapshot.
@MainActor
final class WebcamPlugin: ObservableObject, NotchWidgetPlugin, WidgetSettingsProviding {
    let id = "webcam"
    let displayName = "Webcam"
    let systemImage = "web.camera"

    /// Preferred expanded panel height for the square mirror tile + chrome.
    var expandedContentHeight: CGFloat { 260 }

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
        HStack(alignment: .center, spacing: NotchTheme.spaceMD) {
            mirrorTile
                .frame(maxWidth: 168, maxHeight: 168)
                .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 8) {
                controlsColumn
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Match Boring Notch: open tab → request/start when possible.
            controller.refreshDevices()
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

    private var controlsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.availableDevices.count > 1 {
                Menu {
                    ForEach(controller.availableDevices) { device in
                        Button {
                            controller.selectDevice(id: device.id)
                        } label: {
                            HStack {
                                Text(device.name)
                                if device.id == controller.selectedDeviceID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    NotchChipLabel(
                        title: currentDeviceName,
                        systemImage: "web.camera",
                        active: false
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose camera")
            }

            HStack(spacing: 6) {
                zoomChip("1×", 1.0)
                zoomChip("1.5×", 1.5)
                zoomChip("2×", 2.0)
            }

            HStack(spacing: 6) {
                Button {
                    controller.snapshotToPasteboard(saveToDesktop: false)
                } label: {
                    NotchChipLabel(title: "Snap", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.plain)
                .help("Copy snapshot to clipboard")
                .disabled(!controller.isRunning && controller.frozenImage == nil)

                Button {
                    controller.toggleFreeze()
                } label: {
                    NotchChipLabel(
                        title: controller.isFrozen ? "Live" : "Freeze",
                        systemImage: controller.isFrozen ? "play.fill" : "pause.fill",
                        active: controller.isFrozen
                    )
                }
                .buttonStyle(.plain)
                .help(controller.isFrozen ? "Resume live feed" : "Freeze frame")
                .disabled(!controller.isRunning && !controller.isFrozen)

                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        plugin.isCircular.toggle()
                    }
                } label: {
                    NotchChipLabel(
                        title: plugin.isCircular ? "Circle" : "Square",
                        systemImage: plugin.isCircular ? "circle" : "rectangle.roundedtop"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func zoomChip(_ title: String, _ factor: CGFloat) -> some View {
        Button {
            controller.setZoom(factor)
        } label: {
            NotchChipLabel(title: title, active: abs(controller.zoomFactor - factor) < 0.05)
        }
        .buttonStyle(.plain)
    }

    private var currentDeviceName: String {
        if let id = controller.selectedDeviceID,
           let match = controller.availableDevices.first(where: { $0.id == id }) {
            return match.name
        }
        return "Camera"
    }

    private var mirrorTile: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                // Frozen still
                if controller.isFrozen, let image = controller.frozenImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                        .scaleEffect(controller.zoomFactor)
                        .scaleEffect(x: controller.isMirrored ? -1 : 1, y: 1)
                } else if controller.authState == .authorized {
                    // Live feed — square + aspect-fill, optional selfie mirror
                    WebcamPreviewView(
                        session: controller.session,
                        isMirrored: controller.isMirrored,
                        isRunning: controller.isRunning
                    )
                    .scaleEffect(controller.zoomFactor)
                    .opacity(controller.isRunning ? 1 : 0)
                }

                // Placeholder when idle / denied — dark tile + camera icon.
                if !controller.isRunning && !controller.isFrozen {
                    placeholder(side: side)
                }

                if controller.isFrozen {
                    VStack {
                        Spacer()
                        Text("Frozen")
                            .font(NotchTheme.micro.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .padding(.bottom, 10)
                    }
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
        if controller.isFrozen {
            controller.toggleFreeze()
            return
        }
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

            if plugin.controller.availableDevices.count > 1 {
                Picker("Camera", selection: Binding(
                    get: { plugin.controller.selectedDeviceID ?? "" },
                    set: { plugin.controller.selectDevice(id: $0) }
                )) {
                    ForEach(plugin.controller.availableDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
            }

            Text("Presentation matches Boring Notch: a square mirror tile, tap to start/stop the camera. Snapshot copies a still to the clipboard. The camera only runs while this tab is open.")
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
            if plugin.controller.isFrozen { return "Frame frozen" }
            return plugin.controller.isRunning ? "Camera running — tap mirror to stop" : "Tap mirror to start"
        case .denied: return "Camera access denied"
        case .unavailable: return "No camera available"
        case .notDetermined: return "Camera permission not requested yet"
        }
    }
}
