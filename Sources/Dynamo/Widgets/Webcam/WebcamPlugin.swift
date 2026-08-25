import AppKit
import SwiftUI

/// Webcam mirror — flexible preview: device, mirror/flip/rotate, zoom, shape, fit.
@MainActor
final class WebcamPlugin: ObservableObject, NotchWidgetPlugin, WidgetSettingsProviding {
    let id = "webcam"
    let displayName = "Webcam"
    let systemImage = "web.camera"

    var expandedContentHeight: CGFloat {
        switch previewSize {
        case .compact: return 248
        case .regular: return 280
        case .large: return 320
        }
    }

    enum MirrorShape: String, CaseIterable, Identifiable {
        case circle, rounded, wide
        var id: String { rawValue }
        var title: String {
            switch self {
            case .circle: return "Circle"
            case .rounded: return "Rounded"
            case .wide: return "Wide"
            }
        }
        var systemImage: String {
            switch self {
            case .circle: return "circle"
            case .rounded: return "rectangle.roundedtop"
            case .wide: return "rectangle.ratio.16.to.9"
            }
        }
    }

    enum PreviewSize: String, CaseIterable, Identifiable {
        case compact, regular, large
        var id: String { rawValue }
        var title: String {
            switch self {
            case .compact: return "S"
            case .regular: return "M"
            case .large: return "L"
            }
        }
        var maxTile: CGFloat {
            switch self {
            case .compact: return 132
            case .regular: return 168
            case .large: return 210
            }
        }
    }

    let controller = WebcamCaptureController()

    private static let shapeKey = "dynamo.webcam.mirrorShape"
    private static let sizeKey = "dynamo.webcam.previewSize"
    private static let fitKey = "dynamo.webcam.fitToFrame"
    private static let autoStartKey = "dynamo.webcam.autoStart"

    @Published var mirrorShape: MirrorShape {
        didSet { UserDefaults.standard.set(mirrorShape.rawValue, forKey: Self.shapeKey) }
    }

    @Published var previewSize: PreviewSize {
        didSet { UserDefaults.standard.set(previewSize.rawValue, forKey: Self.sizeKey) }
    }

    /// Letterbox instead of crop.
    @Published var fitToFrame: Bool {
        didSet { UserDefaults.standard.set(fitToFrame, forKey: Self.fitKey) }
    }

    @Published var autoStartOnOpen: Bool {
        didSet { UserDefaults.standard.set(autoStartOnOpen, forKey: Self.autoStartKey) }
    }

    /// Back-compat for older settings toggles.
    var isCircular: Bool {
        get { mirrorShape == .circle }
        set { mirrorShape = newValue ? .circle : .rounded }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.shapeKey),
           let shape = MirrorShape(rawValue: raw) {
            mirrorShape = shape
        } else if UserDefaults.standard.object(forKey: Self.shapeKey) != nil {
            // Legacy bool key reused — treat true as circle.
            mirrorShape = UserDefaults.standard.bool(forKey: Self.shapeKey) ? .circle : .rounded
        } else {
            mirrorShape = .circle
        }
        if let raw = UserDefaults.standard.string(forKey: Self.sizeKey),
           let size = PreviewSize(rawValue: raw) {
            previewSize = size
        } else {
            previewSize = .regular
        }
        fitToFrame = UserDefaults.standard.bool(forKey: Self.fitKey)
        if UserDefaults.standard.object(forKey: Self.autoStartKey) == nil {
            autoStartOnOpen = true
        } else {
            autoStartOnOpen = UserDefaults.standard.bool(forKey: Self.autoStartKey)
        }
    }

    func start() {
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

// MARK: - Expanded

private struct ExpandedWebcamView: View {
    @ObservedObject var plugin: WebcamPlugin
    @ObservedObject private var controller: WebcamCaptureController

    init(plugin: WebcamPlugin) {
        self.plugin = plugin
        self._controller = ObservedObject(wrappedValue: plugin.controller)
    }

    private var aspect: CGFloat {
        switch plugin.mirrorShape {
        case .circle, .rounded: return 1
        case .wide: return 16.0 / 10.0
        }
    }

    private var cornerRadius: CGFloat {
        switch plugin.mirrorShape {
        case .circle: return 1000
        case .rounded: return 14
        case .wide: return 12
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: NotchTheme.spaceMD) {
            mirrorTile
                .frame(maxWidth: plugin.previewSize.maxTile)
                .aspectRatio(aspect, contentMode: .fit)
                .notchAppear()

            ScrollView(.vertical, showsIndicators: false) {
                controlsColumn
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .notchAppear(delay: 0.05)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            controller.refreshDevices()
            controller.refreshCaptureCapabilities()
            controller.requestAccessIfNeeded()
            if plugin.autoStartOnOpen, controller.authState == .authorized {
                controller.start()
            }
        }
        .onDisappear {
            controller.stop()
        }
        .onChange(of: controller.authState) { newValue in
            if plugin.autoStartOnOpen, newValue == .authorized {
                controller.start()
            }
        }
    }

    private var controlsColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            deviceMenu

            if currentDeviceIsContinuity {
                Text("Continuity Camera")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.neonCyan.opacity(0.75))
            }

            qualityCard
            centerStageRow
            transformRow
            shapeRow
            sizeAndFitRow
            zoomRow
            liveStatusRow
            actionRow
        }
    }

    private var centerStageRow: some View {
        HStack(spacing: 5) {
            Button {
                controller.setCenterStageEnabled(!controller.isCenterStageEnabled)
            } label: {
                NotchChipLabel(
                    title: "Center Stage",
                    systemImage: "person.crop.rectangle",
                    active: controller.isCenterStageEnabled
                )
            }
            .buttonStyle(.plain)
            .disabled(!controller.isCenterStageAvailable)
            .opacity(controller.isCenterStageAvailable ? 1 : 0.35)
            .help(
                controller.isCenterStageAvailable
                    ? (controller.isCenterStageEnabled
                        ? "Center Stage on — keeps you framed"
                        : "Enable Center Stage framing")
                    : "Center Stage unavailable on this camera"
            )
            Spacer(minLength: 0)
        }
    }

    /// Text-only quality pickers — icons were clipping into blank capsules.
    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quality")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(NotchTheme.textQuaternary)
                .textCase(.uppercase)
                .tracking(0.5)

            HStack(spacing: 6) {
                Text("Res")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .frame(width: 28, alignment: .leading)
                qualityMenu(
                    title: controller.resolutionTarget.title,
                    help: "Capture resolution (Auto uses the camera default)"
                ) {
                    ForEach(WebcamResolutionTarget.allCases) { res in
                        let allowed = controller.isResolutionSupported(res)
                        Button {
                            controller.resolutionTarget = res
                        } label: {
                            HStack {
                                Text(res.title)
                                if !allowed {
                                    Text("n/a").foregroundStyle(.secondary)
                                }
                                if controller.resolutionTarget == res {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(!allowed)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Text("FPS")
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textQuaternary)
                    .frame(width: 28, alignment: .leading)
                // Compact text chips — always readable; Auto first.
                HStack(spacing: 4) {
                    ForEach(WebcamFPSTarget.allCases) { fps in
                        let allowed = controller.isFPSSupported(fps)
                        Button {
                            guard allowed else { return }
                            controller.fpsTarget = fps
                        } label: {
                            Text(fps.title)
                                .font(NotchTheme.micro.weight(.semibold).monospacedDigit())
                                .foregroundStyle(
                                    controller.fpsTarget == fps
                                        ? NotchTheme.textPrimary
                                        : NotchTheme.textSecondary
                                )
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(
                                            controller.fpsTarget == fps
                                                ? NotchTheme.chipFillActive
                                                : NotchTheme.chipFill
                                        )
                                        .overlay(
                                            Capsule(style: .continuous)
                                                .strokeBorder(
                                                    controller.fpsTarget == fps
                                                        ? NotchTheme.neonCyan.opacity(0.45)
                                                        : Color.white.opacity(0.08),
                                                    lineWidth: 0.6
                                                )
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .opacity(allowed ? 1 : 0.3)
                        .disabled(!allowed)
                        .help(
                            fps == .auto
                                ? "Auto — don’t force a frame rate"
                                : (allowed ? "\(fps.title) fps" : "Not available on this camera")
                        )
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(NotchTheme.chipFill.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    private func qualityMenu<Content: View>(
        title: String,
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(NotchTheme.micro.weight(.semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(NotchTheme.textQuaternary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(NotchTheme.chipFillActive)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(NotchTheme.neonCyan.opacity(0.35), lineWidth: 0.6)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .help(help)
    }

    private var liveStatusRow: some View {
        Group {
            if controller.isRunning, let res = controller.captureResolution {
                HStack(spacing: 4) {
                    Circle()
                        .fill(NotchTheme.positive)
                        .frame(width: 6, height: 6)
                        .shadow(color: NotchTheme.positive.opacity(0.5), radius: 3, y: 0)
                    let fps = controller.captureFrameRate.map { " · \(Int($0.rounded()))fps" } ?? ""
                    Text("Live · \(Int(res.width))×\(Int(res.height))\(fps)")
                        .font(NotchTheme.micro.monospacedDigit())
                        .foregroundStyle(NotchTheme.textTertiary)
                    if controller.resolutionTarget == .p2160 || (controller.fpsTarget == .fps60) {
                        Text("Pro")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(NotchTheme.neonCyan)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(NotchTheme.neonCyan.opacity(0.15)))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var deviceMenu: some View {
        if !controller.availableDevices.isEmpty {
            Menu {
                Button {
                    controller.followSystemPreferredCamera = true
                } label: {
                    HStack {
                        Text("Auto (system preferred)")
                        if controller.followSystemPreferredCamera { Image(systemName: "checkmark") }
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
            .help("Choose camera · Continuity supported")
        }
    }

    private var transformRow: some View {
        HStack(spacing: 5) {
            Button {
                controller.isMirrored.toggle()
            } label: {
                NotchChipLabel(title: "Mirror", systemImage: "arrow.left.and.right", active: controller.isMirrored)
            }
            .buttonStyle(.plain)
            .help("Selfie horizontal flip")

            Button {
                controller.isFlippedVertical.toggle()
            } label: {
                NotchChipLabel(title: "Flip", systemImage: "arrow.up.and.down", active: controller.isFlippedVertical)
            }
            .buttonStyle(.plain)
            .help("Flip vertically")

            Button {
                withAnimation(NotchTheme.snappy) { controller.rotateClockwise() }
            } label: {
                NotchChipLabel(
                    title: rotationLabel,
                    systemImage: "rotate.right",
                    active: controller.rotationQuarterTurns != 0
                )
            }
            .buttonStyle(.plain)
            .help("Rotate 90°")

            Button {
                withAnimation(NotchTheme.snappy) { controller.resetTransform() }
            } label: {
                NotchChipLabel(title: "Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .help("Reset mirror, flip, rotate, zoom")
        }
    }

    private var rotationLabel: String {
        "\(controller.rotationQuarterTurns * 90)°"
    }

    private var shapeRow: some View {
        HStack(spacing: 5) {
            ForEach(WebcamPlugin.MirrorShape.allCases) { shape in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { plugin.mirrorShape = shape }
                } label: {
                    NotchChipLabel(
                        title: shape.title,
                        systemImage: shape.systemImage,
                        active: plugin.mirrorShape == shape
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sizeAndFitRow: some View {
        HStack(spacing: 5) {
            ForEach(WebcamPlugin.PreviewSize.allCases) { size in
                Button {
                    withAnimation(NotchTheme.snappy) { plugin.previewSize = size }
                } label: {
                    NotchChipLabel(title: size.title, active: plugin.previewSize == size)
                }
                .buttonStyle(.plain)
                .help("Preview size \(size.title)")
            }
            Button {
                plugin.fitToFrame.toggle()
            } label: {
                NotchChipLabel(
                    title: plugin.fitToFrame ? "Fit" : "Fill",
                    systemImage: plugin.fitToFrame ? "rectangle.dashed" : "rectangle.fill",
                    active: plugin.fitToFrame
                )
            }
            .buttonStyle(.plain)
            .help(plugin.fitToFrame ? "Letterbox to show full frame" : "Crop to fill the mirror")
        }
    }

    private var zoomRow: some View {
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
            .tint(NotchTheme.neonCyan.opacity(0.85))
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchTheme.textQuaternary)
            Text(String(format: "%.1f×", controller.zoomFactor))
                .font(NotchTheme.micro.monospacedDigit())
                .foregroundStyle(NotchTheme.textTertiary)
                .frame(width: 32, alignment: .trailing)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 5) {
            Button {
                if controller.isRunning {
                    controller.stopNow()
                } else {
                    controller.start()
                }
            } label: {
                NotchChipLabel(
                    title: controller.isRunning ? "Stop" : "Start",
                    systemImage: controller.isRunning ? "stop.fill" : "play.fill",
                    active: controller.isRunning
                )
            }
            .buttonStyle(.plain)

            Button {
                controller.snapshotToPasteboard(saveToDesktop: false)
            } label: {
                NotchChipLabel(title: "Copy", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.plain)
            .help("Copy snapshot to clipboard")
            .disabled(!controller.isRunning && controller.frozenImage == nil)

            Button {
                controller.snapshotToPasteboard(saveToDesktop: true)
            } label: {
                NotchChipLabel(title: "Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .help("Save PNG to Desktop")
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
            .disabled(!controller.isRunning && !controller.isFrozen)
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
                let short = name.count > 16 ? String(name.prefix(14)) + "…" : name
                return "Auto · \(short)"
            }
            return "Auto camera"
        }
        if let device = currentDevice {
            let short = device.name.count > 18 ? String(device.name.prefix(16)) + "…" : device.name
            return short
        }
        return "Camera"
    }

    private var previewTransform: some View {
        EmptyView()
    }

    private var mirrorTile: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack {
                Group {
                    if controller.isFrozen, let image = controller.frozenImage {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: plugin.fitToFrame ? .fit : .fill)
                            .frame(width: w, height: h)
                    } else if controller.authState == .authorized {
                        WebcamPreviewView(
                            session: controller.session,
                            isMirrored: false,
                            isRunning: controller.isRunning,
                            fitToFrame: plugin.fitToFrame
                        )
                        .opacity(controller.isRunning ? 1 : 0)
                    } else {
                        Color.black.opacity(0.001)
                    }
                }
                .scaleEffect(
                    x: (controller.isMirrored ? -1 : 1) * controller.zoomFactor,
                    y: (controller.isFlippedVertical ? -1 : 1) * controller.zoomFactor
                )
                .rotationEffect(.degrees(Double(controller.rotationQuarterTurns) * 90))
                .frame(width: w, height: h)
                .clipped()

                if !controller.isRunning && !controller.isFrozen {
                    placeholder(width: w, height: h)
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
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.14),
                                NotchTheme.neonCyan.opacity(0.18),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onTapGesture { handleTap() }
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    private func placeholder(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255))
            VStack(spacing: 8) {
                Image(systemName: placeholderIcon)
                    .font(.system(size: max(22, min(width, height) / 3.5), weight: .regular))
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
        case .authorized: return controller.isRunning ? "" : "Tap to start"
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture quality")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Resolution", selection: $controller.resolutionTarget) {
                ForEach(WebcamResolutionTarget.allCases.filter { controller.isResolutionSupported($0) }) { res in
                    Text(res.title).tag(res)
                }
            }
            .pickerStyle(.segmented)
            Picker("Frame rate", selection: $controller.fpsTarget) {
                ForEach(WebcamFPSTarget.allCases.filter { controller.isFPSSupported($0) }) { fps in
                    Text(fps == .auto ? "Auto" : "\(fps.title) fps").tag(fps)
                }
            }
            .pickerStyle(.segmented)
            Text("Auto leaves the camera’s natural format. Pick 720p–4K or 24/30/60 only when you want to force it — unavailable options stay dimmed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let res = controller.captureResolution {
                let mode = [
                    controller.resolutionTarget == .auto ? "Res Auto" : controller.resolutionTarget.title,
                    controller.fpsTarget == .auto ? "FPS Auto" : "\(controller.fpsTarget.title) fps"
                ].joined(separator: " · ")
                Text("Active: \(Int(res.width))×\(Int(res.height))\(controller.captureFrameRate.map { " @ \(Int($0.rounded())) fps" } ?? "") — \(mode)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Preview")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Shape", selection: $plugin.mirrorShape) {
                ForEach(WebcamPlugin.MirrorShape.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)
            Picker("Size", selection: $plugin.previewSize) {
                ForEach(WebcamPlugin.PreviewSize.allCases) { s in
                    Text(s == .compact ? "Compact" : s == .regular ? "Regular" : "Large").tag(s)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Fit full frame (letterbox)", isOn: $plugin.fitToFrame)
            Toggle("Start camera when opening Webcam", isOn: $plugin.autoStartOnOpen)

            Divider()

            Text("Transform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Toggle("Mirror (selfie)", isOn: Binding(
                get: { controller.isMirrored },
                set: { controller.isMirrored = $0 }
            ))
            Toggle("Flip vertical", isOn: Binding(
                get: { controller.isFlippedVertical },
                set: { controller.isFlippedVertical = $0 }
            ))
            Stepper(
                "Rotation: \(controller.rotationQuarterTurns * 90)°",
                value: Binding(
                    get: { controller.rotationQuarterTurns },
                    set: { controller.rotationQuarterTurns = $0 }
                ),
                in: 0...3
            )
            HStack {
                Text("Max zoom")
                Slider(
                    value: Binding(
                        get: { Double(controller.maxZoomFactor) },
                        set: { controller.maxZoomFactor = CGFloat($0) }
                    ),
                    in: 1.5...6.0,
                    step: 0.5
                )
                Text(String(format: "%.1f×", controller.maxZoomFactor))
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
            Button("Reset transform & zoom") {
                controller.resetTransform()
            }
            .controlSize(.small)

            Divider()

            Toggle("Center Stage", isOn: Binding(
                get: { controller.isCenterStageEnabled },
                set: { controller.setCenterStageEnabled($0) }
            ))
            .disabled(!controller.isCenterStageAvailable)
            Text(
                controller.isCenterStageAvailable
                    ? "Keeps you framed while moving. Works with Control Center (cooperative)."
                    : "Not available on the current camera / format."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle("Follow system camera (Continuity)", isOn: Binding(
                get: { controller.followSystemPreferredCamera },
                set: { controller.followSystemPreferredCamera = $0 }
            ))
            Text("When on, Continuity Camera (iPhone) switches in automatically when available.")
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
                return controller.isRunning ? "Live: \(device.name)\(kind)" : "Ready: \(device.name)\(kind)"
            }
            return controller.isRunning ? "Camera running" : "Ready — open Webcam to start"
        case .denied: return "Camera access denied"
        case .unavailable: return "No camera available"
        case .notDetermined: return "Camera permission not requested yet"
        }
    }
}
