import AVFoundation
import AppKit
import SwiftUI

/// Hosts an `AVCaptureVideoPreviewLayer` bound to the capture session.
/// Boring Notch style: aspect-fill, optional selfie mirror.
struct WebcamPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    var isMirrored: Bool
    var isRunning: Bool

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        // Same as Boring Notch: the preview layer *is* the view layer.
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.applyMirroring(isMirrored)
        return view
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
        nsView.applyMirroring(isMirrored)
        if isRunning {
            nsView.needsLayout = true
        }
    }

    final class PreviewHostView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            // Boring Notch sets `view.layer = previewLayer` so the feed fills
            // the square without a nested sublayer mismatch.
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.backgroundColor = NSColor.black.cgColor
            layer = previewLayer
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }

        func applyMirroring(_ mirrored: Bool) {
            guard let connection = previewLayer.connection else {
                // Connection may appear after session starts — retry on layout.
                return
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
                previewLayer.setAffineTransform(.identity)
            } else {
                previewLayer.setAffineTransform(
                    mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
                )
            }
        }
    }
}
