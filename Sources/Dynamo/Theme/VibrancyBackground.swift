import AppKit
import SwiftUI

/// Bridges `NSVisualEffectView` into SwiftUI so the notch reads as real macOS
/// glass (menu bar / HUD / popover materials) instead of a flat fill.
///
/// Dynamo’s design language then tints and clips this material — identity sits
/// *on* the system glass, not instead of it.
struct VibrancyBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = NotchTheme.materialCollapsed
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active
    /// Island chrome is always dark glass regardless of system appearance.
    var forceDark: Bool = true

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        // Emphasized HUD glass reads fuller/solid under the island clip.
        view.isEmphasized = true
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.masksToBounds = true
        if forceDark {
            view.appearance = NSAppearance(named: .darkAqua)
        } else {
            view.appearance = nil
        }
    }
}

// MARK: - Material fill for in-content cards (SwiftUI)

/// Soft native material plate used inside the island for cards / chips.
/// Keeps Dynamo radius + hairline while using system material underneath.
struct DynamoMaterialPlate<Content: View>: View {
    var cornerRadius: CGFloat = NotchTheme.radiusCard
    var compact: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(compact ? NotchTheme.spaceSM : NotchTheme.spaceMD)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    // System material — the native glass.
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)

                    // Dynamo identity: cool top sheen + subtle fill lift.
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.08),
                                    NotchTheme.cardFill.opacity(0.55),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Jewel hairline (Dynamo language)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.20),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.6
                        )
                }
                .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
            }
    }
}
