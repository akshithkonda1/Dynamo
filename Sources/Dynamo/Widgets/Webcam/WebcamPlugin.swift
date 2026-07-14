import SwiftUI

/// Webcam mirror widget. Unlike other widgets, the camera is intentionally
/// *not* driven by `start()`/`stop()` (registry registration / enable-disable)
/// — it's driven by the expanded view's own appear/disappear, so the camera
/// only ever runs while you're actually looking at this tab. See
/// `WebcamCaptureController`'s doc comment for the privacy reasoning.
@MainActor
final class WebcamPlugin: ObservableObject, NotchWidgetPlugin {
    let id = "webcam"
    let displayName = "Webcam"
    let systemImage = "camera.fill"

    let controller = WebcamCaptureController()

    func expandedView() -> AnyView {
        AnyView(ExpandedWebcamView(plugin: self))
    }
}

// MARK: - Views

private struct ExpandedWebcamView: View {
    @ObservedObject var plugin: WebcamPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: NotchTheme.spaceSM) {
            Text("Webcam")
                .font(NotchTheme.section)
                .foregroundStyle(NotchTheme.textTertiary)
                .textCase(.uppercase)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            plugin.controller.requestAccessIfNeeded()
            plugin.controller.start()
        }
        .onDisappear {
            plugin.controller.stop()
        }
        .onChange(of: plugin.controller.authState) { newValue in
            if newValue == .authorized {
                plugin.controller.start()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch plugin.controller.authState {
        case .notDetermined:
            Text("Requesting camera access…")
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textTertiary)
        case .denied:
            Text("Camera access denied. Enable it in System Settings → Privacy & Security → Camera.")
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .unavailable:
            Text("No camera available.")
                .font(NotchTheme.caption)
                .foregroundStyle(NotchTheme.textTertiary)
        case .authorized:
            WebcamPreviewView(session: plugin.controller.session)
                .clipShape(RoundedRectangle(cornerRadius: NotchTheme.radiusCard, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
