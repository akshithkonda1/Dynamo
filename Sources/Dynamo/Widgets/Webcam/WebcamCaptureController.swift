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
            let clamped = min(2.0, max(1.0, zoomFactor))
            if clamped != zoomFactor {
                zoomFactor = clamped
            }
        }
    }

    @Published var isMirrored: Bool {
        didSet {
            UserDefaults.standard.set(isMirrored, forKey: Self.mirrorKey)
            NotificationCenter.default.post(name: .dynamoWebcamMirrorDidChange, object: isMirrored)
        }
    }

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

    private static let mirrorKey = "dynamo.webcam.isMirrored"
    private static let deviceKey = "dynamo.webcam.deviceID"
    private static let followSystemKey = "dynamo.webcam.followSystemPreferred"

    init() {
        if UserDefaults.standard.object(forKey: Self.mirrorKey) == nil {
            isMirrored = true
        } else {
            isMirrored = UserDefaults.standard.bool(forKey: Self.mirrorKey)
        }
        if UserDefaults.standard.object(forKey: Self.followSystemKey) == nil {
            followSystemPreferredCamera = true
        } else {
            followSystemPreferredCamera = UserDefaults.standard.bool(forKey: Self.followSystemKey)
        }
        selectedDeviceID = UserDefaults.standard.string(forKey: Self.deviceKey)

        switch PermissionsStore.shared.status(for: .camera) {
        case .granted: authState = .authorized
        case .denied: authState = .denied
        default: break
        }
        refreshAuthState(requestIfNeeded: false)
        refreshDevices()
        installDeviceObservers()
        lastSystemPreferredID = AVCaptureDevice.systemPreferredCamera?.uniqueID
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
        zoomFactor = min(2.0, max(1.0, factor))
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
        // 0.75s is enough for Continuity handoff without thrashing reconfigure.
        let t = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
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
        let currentID = AVCaptureDevice.systemPreferredCamera?.uniqueID
        guard currentID != lastSystemPreferredID else { return }
        lastSystemPreferredID = currentID
        handleSystemPreferredCameraChange()
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
        // Continuity Camera works best at .high; fall back gracefully.
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
