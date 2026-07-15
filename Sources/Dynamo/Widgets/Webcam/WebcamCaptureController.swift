@preconcurrency import AVFoundation
import Foundation

enum WebcamAuthState: Equatable {
    case notDetermined
    case authorized
    case denied
    /// Access is fine, but no camera device could be opened (no built-in
    /// camera, or it's in use exclusively by another app).
    case unavailable
}

/// Owns the `AVCaptureSession` for the webcam mirror widget.
///
/// **Privacy note:** the camera (and its indicator light) only ever runs while
/// the widget's expanded view is actually on screen — `start()`/`stop()` are
/// driven by that view's `onAppear`/`onDisappear`, never by plugin
/// registration. Launching Dynamo, or having the Webcam tab enabled, never by
/// itself turns the camera on.
@MainActor
final class WebcamCaptureController: ObservableObject {
    @Published private(set) var authState: WebcamAuthState = .notDetermined
    @Published private(set) var isRunning = false

    let session = AVCaptureSession()
    private var configured = false

    func requestAccessIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authState = .authorized
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    self?.authState = granted ? .authorized : .denied
                }
            }
        case .denied, .restricted:
            authState = .denied
        @unknown default:
            authState = .denied
        }
    }

    func start() {
        guard authState == .authorized else { return }
        configureIfNeeded()
        guard authState == .authorized else { return } // configureIfNeeded may downgrade to .unavailable
        nonisolated(unsafe) let session = self.session
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
        isRunning = true
    }

    func stop() {
        nonisolated(unsafe) let session = self.session
        guard session.isRunning else {
            isRunning = false
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
        isRunning = false
    }

    /// One-time device/input wiring. `startRunning`/`stopRunning` themselves
    /// are the expensive, blocking calls (dispatched off the main queue per
    /// Apple's guidance); adding the input is cheap and stays on the main actor.
    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            authState = .unavailable
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .medium
        session.addInput(input)
        session.commitConfiguration()
    }
}
