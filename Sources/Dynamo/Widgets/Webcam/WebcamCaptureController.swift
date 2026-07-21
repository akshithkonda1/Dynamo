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
}

/// Owns the `AVCaptureSession` for the webcam mirror widget.
///
/// **Privacy:** the camera (and indicator light) only runs while the Webcam
/// tab is the active expanded view. Registration alone never turns it on.
///
/// **Stability:** `stop()` is debounced so SwiftUI transient disappear/reappear
/// during notch animation doesn't thrash the session. Mirror preference is
/// persisted so the mirror "function" survives relaunch.
@MainActor
final class WebcamCaptureController: ObservableObject {
    @Published private(set) var authState: WebcamAuthState = .notDetermined
    @Published private(set) var isRunning = false
    @Published private(set) var availableDevices: [WebcamDeviceOption] = []
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var isFrozen = false
    @Published private(set) var frozenImage: NSImage?
    /// Digital zoom applied in the preview (macOS has no AVCapture videoZoomFactor).
    @Published var zoomFactor: CGFloat = 1.0 {
        didSet {
            let clamped = min(2.0, max(1.0, zoomFactor))
            if clamped != zoomFactor {
                zoomFactor = clamped
            }
        }
    }

    /// Selfie-style horizontal flip — the point of a "mirror" widget.
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

    private static let mirrorKey = "dynamo.webcam.isMirrored"
    private static let deviceKey = "dynamo.webcam.deviceID"

    init() {
        // Default ON — this is a mirror. User can turn off in Settings / expanded UI.
        if UserDefaults.standard.object(forKey: Self.mirrorKey) == nil {
            isMirrored = true
        } else {
            isMirrored = UserDefaults.standard.bool(forKey: Self.mirrorKey)
        }
        selectedDeviceID = UserDefaults.standard.string(forKey: Self.deviceKey)
        switch PermissionsStore.shared.status(for: .camera) {
        case .granted: authState = .authorized
        case .denied: authState = .denied
        default: break
        }
        refreshAuthState(requestIfNeeded: false)
        refreshDevices()
    }

    func requestAccessIfNeeded() {
        refreshAuthState(requestIfNeeded: true)
    }

    func start() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        // Don't clear freeze on soft restart — only explicit stopNow does.

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

        configureIfNeeded()
        guard authState == .authorized else { return }

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

    func stopNow() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        isFrozen = false
        frozenImage = nil
        performStop()
    }

    func stop() {
        stopWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performStop()
        }
        stopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
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

    func refreshDevices() {
        let devices = Self.discoverDevices()
        availableDevices = devices.map {
            WebcamDeviceOption(id: $0.uniqueID, name: $0.localizedName)
        }
        if let selected = selectedDeviceID,
           availableDevices.contains(where: { $0.id == selected }) {
            return
        }
        if let def = AVCaptureDevice.default(for: .video) {
            selectedDeviceID = def.uniqueID
        } else {
            selectedDeviceID = availableDevices.first?.id
        }
    }

    func selectDevice(id: String) {
        guard id != selectedDeviceID else { return }
        selectedDeviceID = id
        UserDefaults.standard.set(id, forKey: Self.deviceKey)
        let wasRunning = isRunning || session.isRunning
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
        if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
            // Prefer JPEG when listed — more reliable fileDataRepresentation.
        }
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
            // Capture must run on the session queue while the session is running.
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
        // Stop before swapping inputs — mid-session reconfigure races the queue.
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
                if restart, self.authState == .authorized {
                    self.start()
                }
            }
        }
    }

    private func configureIfNeeded() {
        if configured, videoInput != nil { return }

        refreshDevices()
        let device = Self.device(for: selectedDeviceID)

        guard let device,
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            authState = .unavailable
            configured = true
            return
        }

        session.beginConfiguration()
        // Higher quality stills + mirror preview.
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        } else {
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

    private static func discoverDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    private static func device(for id: String?) -> AVCaptureDevice? {
        let devices = discoverDevices()
        if let id, let match = devices.first(where: { $0.uniqueID == id }) {
            return match
        }
        return AVCaptureDevice.default(for: .video) ?? devices.first
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
