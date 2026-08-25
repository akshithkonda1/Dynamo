@preconcurrency import AVFoundation
import AppKit
import Foundation

enum WebcamAuthState: Equatable {
    case notDetermined
    case authorized
    case denied
    /// Access is fine, but no camera device could be opened.
    case unavailable
}

struct WebcamDeviceOption: Identifiable, Equatable {
    let id: String
    let name: String
    /// True when this is an iPhone Continuity Camera (or Desk View companion).
    let isContinuity: Bool
    let isDeskView: Bool

    /// Menu / chip label with a clear Continuity affordance.
    var displayName: String {
        if isDeskView { return "\(name) · Desk View" }
        if isContinuity { return "\(name) · Continuity" }
        return name
    }
}

/// Target capture height (device may negotiate down if unsupported).
enum WebcamResolutionTarget: String, CaseIterable, Identifiable {
    case auto
    case p720
    case p1080
    case p1440
    case p2160 // 4K UHD

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .p2160: return "4K"
        }
    }

    /// Preferred minimum height in pixels; `nil` = let session choose.
    var targetHeight: Int? {
        switch self {
        case .auto: return nil
        case .p720: return 720
        case .p1080: return 1080
        case .p1440: return 1440
        case .p2160: return 2160
        }
    }
}

enum WebcamFPSTarget: Int, CaseIterable, Identifiable {
    case auto = 0
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .fps24: return "24"
        case .fps30: return "30"
        case .fps60: return "60"
        }
    }
}

/// Owns the `AVCaptureSession` for the webcam mirror widget.
///
/// **Continuity Camera:** discovers iPhone cameras via `.continuityCamera`
/// (macOS 14+ with `NSCameraUseContinuityCameraDeviceType`), follows
/// `AVCaptureDevice.systemPreferredCamera` so iPhone auto-switch works like
/// FaceTime/Zoom, and reconfigures on connect/disconnect hotplug.
///
/// **Privacy:** the camera only runs while the Webcam tab is active.
@MainActor
final class WebcamCaptureController: ObservableObject {
    @Published private(set) var authState: WebcamAuthState = .notDetermined
    @Published private(set) var isRunning = false
    @Published private(set) var availableDevices: [WebcamDeviceOption] = []
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var isFrozen = false
    @Published private(set) var frozenImage: NSImage?
    /// When true (default), track Apple’s system-preferred camera so Continuity
    /// Camera switches in/out automatically. Manual picks still set
    /// `userPreferredCamera` and remain compatible with system preference.
    @Published var followSystemPreferredCamera: Bool {
        didSet {
            UserDefaults.standard.set(followSystemPreferredCamera, forKey: Self.followSystemKey)
            if followSystemPreferredCamera {
                applySystemPreferredCamera(restartIfNeeded: isRunning)
            }
        }
    }

    @Published var zoomFactor: CGFloat = 1.0 {
        didSet {
            let clamped = min(maxZoomFactor, max(1.0, zoomFactor))
            if clamped != zoomFactor {
                zoomFactor = clamped
                return
            }
            UserDefaults.standard.set(Double(zoomFactor), forKey: Self.zoomKey)
        }
    }

    /// Upper zoom bound — mutable from settings / live UI.
    @Published var maxZoomFactor: CGFloat = 3.0 {
        didSet {
            let clamped = min(6.0, max(1.5, maxZoomFactor))
            if clamped != maxZoomFactor {
                maxZoomFactor = clamped
                return
            }
            UserDefaults.standard.set(Double(maxZoomFactor), forKey: Self.maxZoomKey)
            if zoomFactor > maxZoomFactor { zoomFactor = maxZoomFactor }
        }
    }

    @Published var isMirrored: Bool {
        didSet {
            UserDefaults.standard.set(isMirrored, forKey: Self.mirrorKey)
            NotificationCenter.default.post(name: .dynamoWebcamMirrorDidChange, object: isMirrored)
        }
    }

    /// Flip upside-down (in addition to selfie mirror).
    @Published var isFlippedVertical: Bool {
        didSet { UserDefaults.standard.set(isFlippedVertical, forKey: Self.flipVKey) }
    }

    /// 0…3 → 0° / 90° / 180° / 270°.
    @Published var rotationQuarterTurns: Int {
        didSet {
            let r = ((rotationQuarterTurns % 4) + 4) % 4
            if r != rotationQuarterTurns {
                rotationQuarterTurns = r
                return
            }
            UserDefaults.standard.set(rotationQuarterTurns, forKey: Self.rotationKey)
        }
    }

    /// When true, quality didSets only persist — used while clamping unsupported picks.
    private var suppressFormatReapply = false

    @Published var resolutionTarget: WebcamResolutionTarget = .auto {
        didSet {
            guard resolutionTarget != oldValue else { return }
            UserDefaults.standard.set(resolutionTarget.rawValue, forKey: Self.resolutionKey)
            guard !suppressFormatReapply else { return }
            reapplyActiveFormat(restartIfNeeded: isActiveTab || isRunning)
        }
    }

    @Published var fpsTarget: WebcamFPSTarget = .auto {
        didSet {
            guard fpsTarget != oldValue else { return }
            UserDefaults.standard.set(fpsTarget.rawValue, forKey: Self.fpsKey)
            guard !suppressFormatReapply else { return }
            reapplyActiveFormat(restartIfNeeded: isActiveTab || isRunning)
        }
    }

    /// Resolutions this camera can actually deliver (subset of targets).
    @Published private(set) var supportedResolutions: [WebcamResolutionTarget] = [.auto]
    /// Frame rates available for the current resolution target.
    @Published private(set) var supportedFPS: [WebcamFPSTarget] = [.auto]

    /// Center Stage (Continuity / Apple silicon cameras that support framing).
    @Published private(set) var isCenterStageEnabled: Bool = AVCaptureDevice.isCenterStageEnabled
    @Published private(set) var isCenterStageAvailable: Bool = false

    let session = AVCaptureSession()
    private var videoInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private var photoDelegate: PhotoCaptureDelegate?
    private var configured = false
    private var stopWorkItem: DispatchWorkItem?
    private let sessionQueue = DispatchQueue(label: "com.akshithkonda.Dynamo.webcam", qos: .userInitiated)

    private var deviceConnectObserver: NSObjectProtocol?
    private var deviceDisconnectObserver: NSObjectProtocol?
    /// Polls `systemPreferredCamera` while the Webcam tab is open — Continuity
    /// can become preferred without a classic connect notification.
    private var systemPreferredPoll: Timer?
    private var lastSystemPreferredID: String?
    /// True while Webcam tab is on-screen (soft-stop may still leave session warm).
    private var isActiveTab = false
    /// Apply smart 4K/1080 default once we know the device’s formats.
    private var pendingDefaultResolution = false
    /// Avoid re-entrant didSet while syncing Center Stage from the system.
    private var suppressCenterStageWrite = false

    private static let mirrorKey = "dynamo.webcam.isMirrored"
    private static let flipVKey = "dynamo.webcam.flipVertical"
    private static let rotationKey = "dynamo.webcam.rotationQuarterTurns"
    private static let zoomKey = "dynamo.webcam.zoomFactor"
    private static let maxZoomKey = "dynamo.webcam.maxZoomFactor"
    private static let deviceKey = "dynamo.webcam.deviceID"
    private static let followSystemKey = "dynamo.webcam.followSystemPreferred"
    private static let resolutionKey = "dynamo.webcam.resolutionTarget"
    private static let fpsKey = "dynamo.webcam.fpsTarget"
    private static let centerStageKey = "dynamo.webcam.centerStageEnabled"

    init() {
        if UserDefaults.standard.object(forKey: Self.mirrorKey) == nil {
            isMirrored = true
        } else {
            isMirrored = UserDefaults.standard.bool(forKey: Self.mirrorKey)
        }
        isFlippedVertical = UserDefaults.standard.bool(forKey: Self.flipVKey)
        rotationQuarterTurns = UserDefaults.standard.integer(forKey: Self.rotationKey)
        if UserDefaults.standard.object(forKey: Self.maxZoomKey) != nil {
            maxZoomFactor = CGFloat(UserDefaults.standard.double(forKey: Self.maxZoomKey))
        }
        if UserDefaults.standard.object(forKey: Self.zoomKey) != nil {
            zoomFactor = CGFloat(UserDefaults.standard.double(forKey: Self.zoomKey))
        }
        if UserDefaults.standard.object(forKey: Self.followSystemKey) == nil {
            followSystemPreferredCamera = true
        } else {
            followSystemPreferredCamera = UserDefaults.standard.bool(forKey: Self.followSystemKey)
        }
        if let raw = UserDefaults.standard.string(forKey: Self.resolutionKey),
           let parsed = WebcamResolutionTarget(rawValue: raw) {
            resolutionTarget = parsed
            pendingDefaultResolution = false
        } else {
            // Prefer 4K when the camera supports it (applied after capability scan).
            resolutionTarget = .auto
            pendingDefaultResolution = true
        }
        let storedFPS = UserDefaults.standard.integer(forKey: Self.fpsKey)
        fpsTarget = WebcamFPSTarget(rawValue: storedFPS) ?? .auto
        selectedDeviceID = UserDefaults.standard.string(forKey: Self.deviceKey)

        if UserDefaults.standard.object(forKey: Self.centerStageKey) != nil {
            let want = UserDefaults.standard.bool(forKey: Self.centerStageKey)
            applyCenterStageEnabled(want, reapplyFormat: false)
        }

        switch PermissionsStore.shared.status(for: .camera) {
        case .granted: authState = .authorized
        case .denied: authState = .denied
        default: break
        }
        refreshAuthState(requestIfNeeded: false)
        refreshDevices()
        installDeviceObservers()
        lastSystemPreferredID = AVCaptureDevice.systemPreferredCamera?.uniqueID
        syncCenterStageFromSystem()
    }

    deinit {
        if let deviceConnectObserver {
            NotificationCenter.default.removeObserver(deviceConnectObserver)
        }
        if let deviceDisconnectObserver {
            NotificationCenter.default.removeObserver(deviceDisconnectObserver)
        }
        // Timer invalidated on main; stop() also clears it.
        systemPreferredPoll?.invalidate()
    }

    // MARK: - Lifecycle

    func requestAccessIfNeeded() {
        refreshAuthState(requestIfNeeded: true)
    }

    func start() {
        isActiveTab = true
        stopWorkItem?.cancel()
        stopWorkItem = nil

        refreshAuthState(requestIfNeeded: false)

        switch authState {
        case .notDetermined:
            refreshAuthState(requestIfNeeded: true)
            return
        case .denied, .unavailable:
            return
        case .authorized:
            break
        }

        if followSystemPreferredCamera {
            applySystemPreferredCamera(restartIfNeeded: false)
        }
        configureIfNeeded()
        guard authState == .authorized else { return }
        startSessionRunning()
        startSystemPreferredPolling()
    }

    func stopNow() {
        isActiveTab = false
        stopSystemPreferredPolling()
        stopWorkItem?.cancel()
        stopWorkItem = nil
        isFrozen = false
        frozenImage = nil
        performStop()
    }

    func stop() {
        isActiveTab = false
        stopSystemPreferredPolling()
        stopWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performStop()
        }
        stopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func startSessionRunning() {
        nonisolated(unsafe) let session = self.session
        sessionQueue.async { [weak self] in
            guard !session.isRunning else {
                Task { @MainActor in self?.isRunning = true }
                return
            }
            session.startRunning()
            Task { @MainActor in
                self?.isRunning = session.isRunning
            }
        }
    }

    private func performStop() {
        nonisolated(unsafe) let session = self.session
        sessionQueue.async { [weak self] in
            if session.isRunning {
                session.stopRunning()
            }
            Task { @MainActor in
                self?.isRunning = false
            }
        }
    }

    // MARK: - Auth

    func refreshAuthState(requestIfNeeded: Bool) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authState = .authorized
            PermissionsStore.shared.recordGranted(.camera)
            refreshDevices()
        case .notDetermined:
            authState = .notDetermined
            if requestIfNeeded {
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    Task { @MainActor in
                        self?.authState = granted ? .authorized : .denied
                        if granted {
                            PermissionsStore.shared.recordGranted(.camera)
                            self?.refreshDevices()
                            self?.start()
                        } else {
                            PermissionsStore.shared.recordDenied(.camera)
                        }
                    }
                }
            }
        case .denied, .restricted:
            authState = .denied
            PermissionsStore.shared.recordDenied(.camera)
        @unknown default:
            authState = .denied
        }
    }

    // MARK: - Devices & Continuity

    func refreshDevices() {
        // Keep quality menus in sync whenever the device list changes.
        defer { refreshCaptureCapabilities() }
        let devices = Self.discoverDevices()
        availableDevices = devices.map { Self.option(for: $0) }

        if followSystemPreferredCamera, let preferred = AVCaptureDevice.systemPreferredCamera {
            selectedDeviceID = preferred.uniqueID
            return
        }

        if let selected = selectedDeviceID,
           availableDevices.contains(where: { $0.id == selected }) {
            return
        }
        if let preferred = AVCaptureDevice.systemPreferredCamera {
            selectedDeviceID = preferred.uniqueID
        } else if let def = AVCaptureDevice.default(for: .video) {
            selectedDeviceID = def.uniqueID
        } else {
            selectedDeviceID = availableDevices.first?.id
        }
    }

    /// User picked a camera from the menu — prefer it via system APIs + sticky id.
    func selectDevice(id: String) {
        guard id != selectedDeviceID || !followSystemPreferredCamera else { return }
        selectedDeviceID = id
        UserDefaults.standard.set(id, forKey: Self.deviceKey)

        if let device = Self.device(for: id) {
            // Lets systemPreferredCamera honour the user’s pick (incl. Continuity).
            AVCaptureDevice.userPreferredCamera = device
        }

        let wasRunning = isRunning || session.isRunning || isActiveTab
        reconfigureInput(restart: wasRunning)
    }

    func setZoom(_ factor: CGFloat) {
        let maxZ = maxZoomFactor
        zoomFactor = min(maxZ, max(1.0, factor))
    }

    /// Toggle Center Stage (cooperative with Control Center). No-op when unavailable.
    func setCenterStageEnabled(_ enabled: Bool) {
        guard isCenterStageAvailable || enabled == false else { return }
        applyCenterStageEnabled(enabled, reapplyFormat: true)
        UserDefaults.standard.set(enabled, forKey: Self.centerStageKey)
    }

    var captureResolution: CGSize? {
        guard let device = videoInput?.device else { return nil }
        let format = device.activeFormat
        let desc = format.formatDescription
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        guard dims.width > 0, dims.height > 0 else { return nil }
        return CGSize(width: Int(dims.width), height: Int(dims.height))
    }

    var captureFrameRate: Double? {
        guard let device = videoInput?.device else { return nil }
        let fps = device.activeVideoMinFrameDuration
        guard fps.timescale != 0 else { return nil }
        let rate = Double(fps.timescale) / Double(fps.value)
        return rate > 0 ? rate : nil
    }

    func rotateClockwise() {
        rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
    }

    func resetTransform() {
        isMirrored = true
        isFlippedVertical = false
        rotationQuarterTurns = 0
        zoomFactor = 1.0
    }

    func toggleFreeze() {
        if isFrozen {
            isFrozen = false
            frozenImage = nil
            return
        }
        captureSnapshot { [weak self] image in
            guard let self, let image else { return }
            self.frozenImage = image
            self.isFrozen = true
        }
    }

    func snapshotToPasteboard(saveToDesktop: Bool = false) {
        captureSnapshot { image in
            guard let image else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
            if saveToDesktop {
                Self.savePNGToDesktop(image)
            }
        }
    }

    // MARK: - System preferred (Continuity auto-switch)

    private func startSystemPreferredPolling() {
        stopSystemPreferredPolling()
        lastSystemPreferredID = AVCaptureDevice.systemPreferredCamera?.uniqueID
        // Hotplug notifications cover most Continuity handoffs; poll is a safety net.
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollSystemPreferredCamera()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        systemPreferredPoll = t
    }

    private func stopSystemPreferredPolling() {
        systemPreferredPoll?.invalidate()
        systemPreferredPoll = nil
    }

    private func pollSystemPreferredCamera() {
        refreshDevices()
        syncCenterStageFromSystem()
        let currentID = AVCaptureDevice.systemPreferredCamera?.uniqueID
        guard currentID != lastSystemPreferredID else { return }
        lastSystemPreferredID = currentID
        handleSystemPreferredCameraChange()
    }

    private func syncCenterStageFromSystem() {
        let systemOn = AVCaptureDevice.isCenterStageEnabled
        if systemOn != isCenterStageEnabled {
            suppressCenterStageWrite = true
            isCenterStageEnabled = systemOn
            suppressCenterStageWrite = false
        }
        refreshCenterStageAvailability()
    }

    private func refreshCenterStageAvailability() {
        let device = videoInput?.device ?? Self.device(for: selectedDeviceID)
        let available = device?.formats.contains(where: { $0.isCenterStageSupported }) ?? false
        if available != isCenterStageAvailable {
            isCenterStageAvailable = available
        }
    }

    private func applyCenterStageEnabled(_ enabled: Bool, reapplyFormat: Bool) {
        guard !suppressCenterStageWrite else {
            isCenterStageEnabled = enabled
            return
        }
        AVCaptureDevice.centerStageControlMode = .cooperative
        if AVCaptureDevice.isCenterStageEnabled != enabled {
            AVCaptureDevice.isCenterStageEnabled = enabled
        }
        isCenterStageEnabled = AVCaptureDevice.isCenterStageEnabled
        if reapplyFormat {
            reapplyActiveFormat(restartIfNeeded: isActiveTab || isRunning)
        }
    }

    private func handleSystemPreferredCameraChange() {
        refreshDevices()
        guard followSystemPreferredCamera else { return }
        applySystemPreferredCamera(restartIfNeeded: isActiveTab || isRunning)
    }

    private func applySystemPreferredCamera(restartIfNeeded: Bool) {
        guard let preferred = AVCaptureDevice.systemPreferredCamera else {
            refreshDevices()
            return
        }
        if preferred.uniqueID == videoInput?.device.uniqueID,
           preferred.uniqueID == selectedDeviceID {
            return
        }
        selectedDeviceID = preferred.uniqueID
        UserDefaults.standard.set(preferred.uniqueID, forKey: Self.deviceKey)
        if restartIfNeeded || isActiveTab {
            reconfigureInput(restart: isActiveTab || isRunning)
        } else {
            configured = false
        }
    }

    private func installDeviceObservers() {
        deviceConnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice,
                  device.hasMediaType(.video)
            else { return }
            Task { @MainActor in
                self?.handleDeviceHotPlug(connected: true, device: device)
            }
        }
        deviceDisconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice else { return }
            Task { @MainActor in
                self?.handleDeviceHotPlug(connected: false, device: device)
            }
        }
    }

    private func handleDeviceHotPlug(connected: Bool, device: AVCaptureDevice) {
        refreshDevices()
        if connected {
            // Continuity Camera often becomes system-preferred immediately.
            if followSystemPreferredCamera {
                applySystemPreferredCamera(restartIfNeeded: isActiveTab || isRunning)
            } else if device.isContinuityCamera, selectedDeviceID == nil {
                selectDevice(id: device.uniqueID)
            }
            return
        }
        // Disconnected — if we were on that device, fall back.
        if videoInput?.device.uniqueID == device.uniqueID || selectedDeviceID == device.uniqueID {
            if followSystemPreferredCamera {
                applySystemPreferredCamera(restartIfNeeded: isActiveTab || isRunning)
            } else {
                selectedDeviceID = availableDevices.first?.id
                if isActiveTab || isRunning {
                    reconfigureInput(restart: isActiveTab)
                }
            }
        }
    }

    // MARK: - Capture

    private func captureSnapshot(completion: @escaping (NSImage?) -> Void) {
        if isFrozen, let frozenImage {
            completion(frozenImage)
            return
        }
        guard authState == .authorized, isRunning else {
            completion(nil)
            return
        }
        guard session.outputs.contains(where: { $0 === photoOutput }) else {
            completion(nil)
            return
        }

        let settings = AVCapturePhotoSettings()
        let delegate = PhotoCaptureDelegate { [weak self] image in
            Task { @MainActor in
                self?.photoDelegate = nil
                completion(image)
            }
        }
        photoDelegate = delegate
        nonisolated(unsafe) let output = photoOutput
        nonisolated(unsafe) let retained = delegate
        sessionQueue.async {
            output.capturePhoto(with: settings, delegate: retained)
        }
    }

    private static func savePNGToDesktop(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
        else { return }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard let desktop else { return }
        let name = "Dynamo-Mirror-\(Int(Date().timeIntervalSince1970)).png"
        try? data.write(to: desktop.appendingPathComponent(name))
    }

    private func reconfigureInput(restart: Bool) {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        nonisolated(unsafe) let session = self.session
        sessionQueue.async { [weak self] in
            if session.isRunning {
                session.stopRunning()
            }
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = false
                self.configured = false
                self.session.beginConfiguration()
                if let videoInput = self.videoInput {
                    self.session.removeInput(videoInput)
                    self.videoInput = nil
                }
                self.session.commitConfiguration()
                self.configureIfNeeded()
                if restart, self.authState == .authorized, self.isActiveTab {
                    self.startSessionRunning()
                }
            }
        }
    }

    private func configureIfNeeded() {
        if configured, videoInput != nil { return }

        refreshDevices()
        let device = Self.device(for: selectedDeviceID)
            ?? AVCaptureDevice.systemPreferredCamera
            ?? AVCaptureDevice.default(for: .video)

        guard let device,
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            authState = .unavailable
            configured = true
            return
        }

        session.beginConfiguration()
        // Balanced default; explicit quality targets lock `activeFormat` after commit.
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }
        if let existing = videoInput {
            session.removeInput(existing)
        }
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            selectedDeviceID = device.uniqueID
        }
        if !session.outputs.contains(where: { $0 === photoOutput }), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        session.commitConfiguration()
        configured = videoInput != nil
        authState = videoInput != nil ? .authorized : .unavailable
        if let videoInput {
            refreshSupportedCaptureOptions(for: videoInput.device)
            applyPreferredFormat(to: videoInput.device)
        }
    }

    /// Re-lock activeFormat after the user changes resolution / FPS.
    private func reapplyActiveFormat(restartIfNeeded: Bool) {
        let device = videoInput?.device ?? Self.device(for: selectedDeviceID)
        refreshSupportedCaptureOptions(for: device)
        guard let device else { return }

        nonisolated(unsafe) let session = self.session
        sessionQueue.async { [weak self] in
            let wasRunning = session.isRunning
            if wasRunning { session.stopRunning() }
            Task { @MainActor in
                guard let self else { return }
                self.applyPreferredFormat(to: device)
                if (restartIfNeeded || wasRunning), self.isActiveTab, self.authState == .authorized {
                    self.startSessionRunning()
                }
            }
        }
    }

    /// Always keeps Auto + every tier; unsupported tiers stay listed but `isResolutionSupported` gates UI.
    func isResolutionSupported(_ target: WebcamResolutionTarget) -> Bool {
        // Auto is always allowed.
        if target == .auto { return true }
        return supportedResolutions.contains(target)
    }

    func isFPSSupported(_ target: WebcamFPSTarget) -> Bool {
        if target == .auto { return true }
        return supportedFPS.contains(target)
    }

    /// Scan the current / preferred camera so quality chips populate before Start.
    func refreshCaptureCapabilities() {
        let device = videoInput?.device ?? Self.device(for: selectedDeviceID)
        refreshSupportedCaptureOptions(for: device)
    }

    private func refreshSupportedCaptureOptions(for device: AVCaptureDevice?) {
        guard let device else {
            // Before a device is known, still show the full menu — Auto always works.
            supportedResolutions = WebcamResolutionTarget.allCases
            supportedFPS = WebcamFPSTarget.allCases
            isCenterStageAvailable = false
            return
        }
        var heights = Set<Int>()
        var fpsCaps = Set<Int>()
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let h = Int(dims.height)
            guard h > 0 else { continue }
            heights.insert(h)
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= 23.5 { fpsCaps.insert(24) }
                if range.maxFrameRate >= 29.5 { fpsCaps.insert(30) }
                if range.maxFrameRate >= 59.0 { fpsCaps.insert(60) }
            }
        }
        var resolutions: [WebcamResolutionTarget] = [.auto]
        if heights.contains(where: { $0 >= 700 }) { resolutions.append(.p720) }
        if heights.contains(where: { $0 >= 1000 }) { resolutions.append(.p1080) }
        if heights.contains(where: { $0 >= 1360 }) { resolutions.append(.p1440) }
        if heights.contains(where: { $0 >= 2000 }) { resolutions.append(.p2160) }
        var seenRes = Set<WebcamResolutionTarget>()
        supportedResolutions = resolutions.filter { seenRes.insert($0).inserted }

        var fps: [WebcamFPSTarget] = [.auto]
        if fpsCaps.contains(24) { fps.append(.fps24) }
        if fpsCaps.contains(30) { fps.append(.fps30) }
        if fpsCaps.contains(60) { fps.append(.fps60) }
        supportedFPS = fps

        isCenterStageAvailable = device.formats.contains(where: \.isCenterStageSupported)

        // First launch (no saved resolution): prefer 4K → 1080p → Auto.
        if pendingDefaultResolution {
            pendingDefaultResolution = false
            suppressFormatReapply = true
            if supportedResolutions.contains(.p2160) {
                resolutionTarget = .p2160
            } else if supportedResolutions.contains(.p1080) {
                resolutionTarget = .p1080
            } else {
                resolutionTarget = .auto
            }
            suppressFormatReapply = false
        }

        // Fall back to Auto if a saved pick isn’t possible on this camera.
        let fixRes = resolutionTarget != .auto && !supportedResolutions.contains(resolutionTarget)
        let fixFPS = fpsTarget != .auto && !supportedFPS.contains(fpsTarget)
        if fixRes || fixFPS {
            suppressFormatReapply = true
            if fixRes { resolutionTarget = .auto }
            if fixFPS { fpsTarget = .auto }
            suppressFormatReapply = false
        }
    }

    /// Auto = session/device defaults. Explicit targets lock the closest format.
    /// When Center Stage is on, prefer formats that advertise `isCenterStageSupported`.
    private func applyPreferredFormat(to device: AVCaptureDevice) {
        let preferCenterStage = isCenterStageEnabled || AVCaptureDevice.isCenterStageEnabled
        let targetH = resolutionTarget.targetHeight
        let wantFPS = Double(fpsTarget.rawValue)

        struct Candidate {
            let format: AVCaptureDevice.Format
            let height: Int
            let width: Int
            let maxFPS: Double
            let centerStage: Bool
        }

        var candidates: [Candidate] = []
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let h = Int(dims.height)
            let w = Int(dims.width)
            guard h > 0, w > 0 else { continue }
            let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            candidates.append(Candidate(
                format: format,
                height: h,
                width: w,
                maxFPS: maxFPS,
                centerStage: format.isCenterStageSupported
            ))
        }
        guard !candidates.isEmpty else { return }

        // Auto + Auto with no Center Stage preference → leave session preset.
        if resolutionTarget == .auto, fpsTarget == .auto, !preferCenterStage {
            objectWillChange.send()
            return
        }

        var pool = candidates
        if preferCenterStage {
            let cs = pool.filter(\.centerStage)
            if !cs.isEmpty { pool = cs }
        }
        if let targetH {
            let near = pool.filter { abs($0.height - targetH) <= 40 || $0.height >= targetH - 8 }
            if !near.isEmpty { pool = near }
        }
        if wantFPS >= 24 {
            let ok = pool.filter { $0.maxFPS + 0.5 >= wantFPS }
            if !ok.isEmpty { pool = ok }
        }

        let chosen: Candidate = {
            if let targetH {
                return pool.min { a, b in
                    let da = abs(a.height - targetH)
                    let db = abs(b.height - targetH)
                    if da != db { return da < db }
                    if preferCenterStage, a.centerStage != b.centerStage {
                        return a.centerStage && !b.centerStage
                    }
                    let arA = abs(Double(a.width) / Double(a.height) - 16.0 / 9.0)
                    let arB = abs(Double(b.width) / Double(b.height) - 16.0 / 9.0)
                    if abs(arA - arB) > 0.02 { return arA < arB }
                    return a.maxFPS > b.maxFPS
                }!
            }
            // Resolution Auto: prefer Center Stage–capable, then highest FPS/height.
            return pool.max { a, b in
                if preferCenterStage, a.centerStage != b.centerStage {
                    return !a.centerStage && b.centerStage
                }
                if a.maxFPS != b.maxFPS { return a.maxFPS < b.maxFPS }
                return a.height < b.height
            }!
        }()

        let fpsToLock: Double? = {
            guard wantFPS >= 24 else { return nil } // FPS Auto → don't force duration
            return min(wantFPS, chosen.maxFPS)
        }()

        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen.format
            if let fpsToLock,
               let range = chosen.format.videoSupportedFrameRateRanges.first(where: {
                   $0.minFrameRate - 0.5 <= fpsToLock && fpsToLock <= $0.maxFrameRate + 0.5
               }) {
                let clamped = min(max(fpsToLock, range.minFrameRate), range.maxFrameRate)
                let t = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(clamped.rounded()))))
                device.activeVideoMinFrameDuration = t
                device.activeVideoMaxFrameDuration = t
            }
            device.unlockForConfiguration()
            refreshCenterStageAvailability()
            objectWillChange.send()
        } catch {
            // Busy / Continuity — keep current format.
        }
    }

    // MARK: - Discovery

    private static func discoverDevices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]

        // Continuity Camera (iPhone) — requires NSCameraUseContinuityCameraDeviceType in Info.plist.
        if #available(macOS 14.0, *) {
            types.append(.continuityCamera)
            types.append(.external)
        } else {
            // Pre-14: Continuity often surfaces via externalUnknown / built-in.
            types.append(.externalUnknown)
        }

        // iPhone Desk View companion when Continuity is active.
        types.append(.deskViewCamera)

        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )

        // Deduplicate by uniqueID (some Continuity devices can match multiple types
        // if discovery is broad).
        var seen = Set<String>()
        var result: [AVCaptureDevice] = []
        for device in session.devices {
            guard seen.insert(device.uniqueID).inserted else { continue }
            result.append(device)
        }

        // Ensure system-preferred is listed even if discovery order is odd.
        if let preferred = AVCaptureDevice.systemPreferredCamera,
           seen.insert(preferred.uniqueID).inserted {
            result.insert(preferred, at: 0)
        }

        // Continuity cameras first, then others — easier to pick iPhone.
        return result.sorted { a, b in
            let ac = a.isContinuityCamera || a.deviceType == .deskViewCamera
            let bc = b.isContinuityCamera || b.deviceType == .deskViewCamera
            if ac != bc { return ac && !bc }
            return a.localizedName.localizedCaseInsensitiveCompare(b.localizedName) == .orderedAscending
        }
    }

    private static func device(for id: String?) -> AVCaptureDevice? {
        let devices = discoverDevices()
        if let id, let match = devices.first(where: { $0.uniqueID == id }) {
            return match
        }
        return AVCaptureDevice.systemPreferredCamera
            ?? AVCaptureDevice.default(for: .video)
            ?? devices.first
    }

    private static func option(for device: AVCaptureDevice) -> WebcamDeviceOption {
        let isDesk = device.deviceType == .deskViewCamera
        let isContinuity: Bool = {
            if isDesk { return true }
            if device.isContinuityCamera { return true }
            if #available(macOS 14.0, *) {
                if device.deviceType == .continuityCamera { return true }
            }
            // Name heuristics as last resort (older macOS mislabeling).
            let name = device.localizedName.lowercased()
            return name.contains("iphone") || name.contains("continuity")
        }()
        return WebcamDeviceOption(
            id: device.uniqueID,
            name: device.localizedName,
            isContinuity: isContinuity,
            isDeskView: isDesk
        )
    }
}

// MARK: - Photo capture

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (NSImage?) -> Void

    init(completion: @escaping (NSImage?) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil, let data = photo.fileDataRepresentation(),
              let image = NSImage(data: data)
        else {
            completion(nil)
            return
        }
        completion(image)
    }
}

extension Notification.Name {
    static let dynamoWebcamMirrorDidChange = Notification.Name("dynamoWebcamMirrorDidChange")
}
