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
    var expandedContentHeight: CGFloat { 255 }

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
    /// Must observe the controller separately — it's its own ObservableObject;
    /// watching only `plugin` left isRunning/freeze/snap UI stuck.
    @ObservedObject private var controller: WebcamCaptureController

    init(plugin: WebcamPlugin) {
        self.plugin = plugin
        self._controller = ObservedObject(wrappedValue: plugin.controller)
    }

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
            // Always offer a camera menu when any device exists (Continuity can
            // appear as the only entry or join later via hotplug).
            if !controller.availableDevices.isEmpty {
                Menu {
                    Button {
                        controller.followSystemPreferredCamera = true
                    } label: {
                        HStack {
                            Text("Auto (system preferred)")
                            if controller.followSystemPreferredCamera {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    Divider()
                    ForEach(controller.availableDevices) { device in
                        Button {
                            controller.followSystemPreferredCamera = false
                            controller.selectDevice(id: device.id)
                        } label: {
                            HStack {
                                Text(device.displayName)
                                if !controller.followSystemPreferredCamera,
                                   device.id == controller.selectedDeviceID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    NotchChipLabel(
                        title: currentDeviceChipTitle,
                        systemImage: currentDeviceIsContinuity ? "iphone" : "web.camera",
                        active: currentDeviceIsContinuity
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose camera · Continuity Camera supported")
            }

            if currentDeviceIsContinuity {
                Text("Continuity Camera")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textTertiary)
            }

            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                Slider(
                    value: Binding(
                        get: { controller.zoomFactor },
                        set: { controller.setZoom($0) }
                    ),
                    in: 1.0...max(controller.maxZoomFactor, 1.01)
                )
                .controlSize(.mini)
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                Text(String(format: "%.1f×", controller.zoomFactor))
                    .font(NotchTheme.micro.monospacedDigit())
                    .foregroundStyle(NotchTheme.textTertiary)
                    .frame(width: 30, alignment: .trailing)
            }

            if controller.isRunning, let res = controller.captureResolution {
                HStack(spacing: 4) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(NotchTheme.positive)
                    Text("\(Int(res.height))p\(controller.captureFrameRate.map { " \(Int($0))fps" } ?? "")")
                        .font(NotchTheme.micro.monospacedDigit())
                        .foregroundStyle(NotchTheme.textTertiary)
                }
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

    private var currentDevice: WebcamDeviceOption? {
        if let id = controller.selectedDeviceID {
            return controller.availableDevices.first(where: { $0.id == id })
        }
        return controller.availableDevices.first
    }

    private var currentDeviceIsContinuity: Bool {
        currentDevice?.isContinuity == true || currentDevice?.isDeskView == true
    }

    private var currentDeviceChipTitle: String {
        if controller.followSystemPreferredCamera {
            if let name = currentDevice?.name {
                let short = name.count > 18 ? String(name.prefix(16)) + "…" : name
                return "Auto · \(short)"
            }
            return "Auto camera"
        }
        if let device = currentDevice {
            let short = device.name.count > 20 ? String(device.name.prefix(18)) + "…" : device.name
            return short
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
    @ObservedObject private var controller: WebcamCaptureController

    init(plugin: WebcamPlugin) {
        self.plugin = plugin
        self._controller = ObservedObject(wrappedValue: plugin.controller)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Mirror video (selfie flip)", isOn: Binding(
                get: { controller.isMirrored },
                set: { controller.isMirrored = $0 }
            ))
            Toggle("Circular mirror", isOn: Binding(
                get: { plugin.isCircular },
                set: { plugin.isCircular = $0 }
            ))
            Toggle("Follow system camera (Continuity)", isOn: Binding(
                get: { controller.followSystemPreferredCamera },
                set: { controller.followSystemPreferredCamera = $0 }
            ))
            Text("When on, Dynamo tracks the system-preferred camera — Continuity Camera (iPhone) switches in automatically when available, like FaceTime.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !controller.availableDevices.isEmpty {
                Picker("Camera", selection: Binding(
                    get: { controller.selectedDeviceID ?? "" },
                    set: {
                        controller.followSystemPreferredCamera = false
                        controller.selectDevice(id: $0)
                    }
                )) {
                    ForEach(controller.availableDevices) { device in
                        Text(device.displayName).tag(device.id)
                    }
                }
            }

            Text("Uses Continuity Camera when your iPhone is nearby and unlocked. The camera only runs while this tab is open.")
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
        switch controller.authState {
        case .authorized: return controller.isRunning ? .green : .yellow
        case .denied, .unavailable: return .red
        case .notDetermined: return .orange
        }
    }

    private var statusText: String {
        switch controller.authState {
        case .authorized:
            if controller.isFrozen { return "Frame frozen" }
            if let device = controller.availableDevices.first(where: { $0.id == controller.selectedDeviceID }) {
                let kind = device.isContinuity || device.isDeskView ? " · Continuity" : ""
                if controller.isRunning {
                    return "Live: \(device.name)\(kind)"
                }
                return "Ready: \(device.name)\(kind)"
            }
            return controller.isRunning ? "Camera running — tap mirror to stop" : "Tap mirror to start"
        case .denied: return "Camera access denied"
        case .unavailable: return "No camera available"
        case .notDetermined: return "Camera permission not requested yet"
        }
    }
}
