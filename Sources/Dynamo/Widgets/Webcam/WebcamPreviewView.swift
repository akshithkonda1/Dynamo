import AVFoundation
import AppKit
import SwiftUI

/// Hosts an `AVCaptureVideoPreviewLayer` bound to the capture session.
/// Applies the remembered mirror preference (selfie flip).
struct WebcamPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    var isMirrored: Bool
    var isRunning: Bool

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
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
        // Force a layout pass when running flips so the first frame isn't blank.
        if isRunning {
            nsView.needsLayout = true
        }
    }

    final class PreviewHostView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            previewLayer.frame = bounds
            previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }

        func applyMirroring(_ mirrored: Bool) {
            guard let connection = previewLayer.connection else { return }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            } else {
                // Fallback: affine flip when the connection can't mirror natively.
                previewLayer.setAffineTransform(
                    mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
                )
            }
        }
    }
}
