import AVFoundation
import AppKit
import SwiftUI

/// Hosts an `AVCaptureVideoPreviewLayer` bound to the capture session, filling
/// its SwiftUI container.
struct WebcamPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {
        // The session reference is fixed for the plugin's lifetime — nothing to update.
    }

    final class PreviewHostView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = previewLayer
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
