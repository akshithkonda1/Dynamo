import SwiftUI

/// Host view for the notch tray. Renders every registered plugin generically —
/// never branches on widget id/name.
struct NotchContentView: View {
    @ObservedObject var registry: WidgetRegistry
    @ObservedObject var controller: NotchWindowController

    var body: some View {
        ZStack(alignment: .top) {
            Color.black

            if controller.isExpanded {
                expandedBody
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                collapsedBody
                    .transition(.opacity)
            }
        }
        .clipShape(NotchShape(cornerRadius: controller.isExpanded ? 18 : 10))
        .animation(.easeOut(duration: 0.22), value: controller.isExpanded)
        .animation(.easeOut(duration: 0.18), value: registry.activePluginID)
    }

    private var collapsedBody: some View {
        HStack(spacing: 10) {
            ForEach(registry.plugins, id: \.id) { plugin in
                Button {
                    registry.activePluginID = plugin.id
                    controller.expand()
                } label: {
                    plugin.collapsedView()
                }
                .buttonStyle(.plain)
                .help(plugin.displayName)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var expandedBody: some View {
        VStack(spacing: 0) {
            // Tray of plugin icons — selection only, no name-based branching.
            HStack(spacing: 12) {
                ForEach(registry.plugins, id: \.id) { plugin in
                    let isActive = registry.activePluginID == plugin.id
                    Button {
                        registry.activePluginID = plugin.id
                    } label: {
                        Image(systemName: plugin.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.45))
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(isActive ? Color.white.opacity(0.15) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(plugin.displayName)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if let active = registry.activePlugin {
                active.expandedView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
