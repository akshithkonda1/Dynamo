@preconcurrency import AVFoundation
import Foundation

enum WebcamAuthState: Equatable {
    case notDetermined
    case authorized
    case denied
    /// Access is fine, but no camera device could be opened.
    case unavailable
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
    /// Selfie-style horizontal flip — the point of a "mirror" widget.
    @Published var isMirrored: Bool {
        didSet {
            UserDefaults.standard.set(isMirrored, forKey: Self.mirrorKey)
            NotificationCenter.default.post(name: .dynamoWebcamMirrorDidChange, object: isMirrored)
        }
    }

    let session = AVCaptureSession()
    private var configured = false
    private var stopWorkItem: DispatchWorkItem?
    private let sessionQueue = DispatchQueue(label: "com.akshithkonda.Dynamo.webcam", qos: .userInitiated)

    private static let mirrorKey = "dynamo.webcam.isMirrored"

    init() {
        // Default ON — this is a mirror. User can turn off in Settings / expanded UI.
        if UserDefaults.standard.object(forKey: Self.mirrorKey) == nil {
            isMirrored = true
        } else {
            isMirrored = UserDefaults.standard.bool(forKey: Self.mirrorKey)
        }
        // Seed from remembered OS grant so we don't flash "Requesting…" every launch.
        switch PermissionsStore.shared.status(for: .camera) {
        case .granted: authState = .authorized
        case .denied: authState = .denied
        default: break
        }
        // Sync published auth from system without prompting yet.
        refreshAuthState(requestIfNeeded: false)
    }

    func requestAccessIfNeeded() {
        refreshAuthState(requestIfNeeded: true)
    }

    func start() {
        // Cancel a pending stop from a transient onDisappear.
        stopWorkItem?.cancel()
        stopWorkItem = nil

        // Always trust live OS status (not only remembered grants).
        refreshAuthState(requestIfNeeded: false)

        switch authState {
        case .notDetermined:
            // First open of the Webcam tab — prompt once, then start on grant.
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

    /// Immediate stop (plugin disable / app quit).
    func stopNow() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        performStop()
    }

    /// Soft stop — waits briefly so expand/collapse / view identity churn
    /// doesn't kill a session the user still wants.
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

    /// Syncs `authState` from the OS. Set `requestIfNeeded` only when the user
    /// is actively opening Webcam — never from plugin registration / app launch.
    func refreshAuthState(requestIfNeeded: Bool) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authState = .authorized
            PermissionsStore.shared.recordGranted(.camera)
        case .notDetermined:
            authState = .notDetermined
            if requestIfNeeded {
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    Task { @MainActor in
                        self?.authState = granted ? .authorized : .denied
                        if granted {
                            PermissionsStore.shared.recordGranted(.camera)
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

    private func configureIfNeeded() {
        guard !configured else { return }

        // Prefer the system default video device (built-in FaceTime camera when present).
        let device = AVCaptureDevice.default(for: .video)

        guard let device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            authState = .unavailable
            configured = true
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .medium
        if session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
        configured = true
        authState = .authorized
    }
}

extension Notification.Name {
    static let dynamoWebcamMirrorDidChange = Notification.Name("dynamoWebcamMirrorDidChange")
}
