import AppKit
import SwiftUI

/// First-launch window that asks for every grant Dynamo needs or wants.
/// Apple Music (MusicKit + Control Music) shares a card; Dynamo controls
/// stays its own prompt. Skip / close is remembered so launch does not re-ask.
@MainActor
final class PermissionOnboardingController: NSObject {
    static let shared = PermissionOnboardingController()

    private var window: NSWindow?

    func presentIfNeeded() {
        let store = PermissionsStore.shared
        store.refreshFromSystem()
        guard store.needsOnboarding() else {
            store.applyGrantedServices()
            return
        }
        show()
    }

    func show() {
        if window == nil {
            let root = PermissionOnboardingView(onFinished: { [weak self] in
                self?.finish()
            })
            let hosting = NSHostingController(rootView: root)
            if #available(macOS 13.0, *) {
                hosting.sizingOptions = []
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Dynamo permissions"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1)
            window.contentViewController = hosting
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.center()
            window.delegate = self
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        PermissionsStore.shared.beginLiveUpdates()
    }

    private func finish() {
        PermissionsStore.shared.endLiveUpdates()
        PermissionsStore.shared.completeOnboarding()
        window?.orderOut(nil)
    }
}

extension PermissionOnboardingController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        PermissionsStore.shared.endLiveUpdates()
        PermissionsStore.shared.completeOnboarding()
    }
}

struct PermissionOnboardingView: View {
    @ObservedObject private var store = PermissionsStore.shared
    var onFinished: () -> Void

    @State private var busy: DynamoPermission?
    @State private var bulkBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    familySection(
                        title: "Needed to work",
                        caption: "Core grants. Apple Music is MusicKit plus Control Music; Dynamo controls is a separate Accessibility prompt.",
                        families: PermissionFamily.core
                    )
                    familySection(
                        title: "Also wants",
                        caption: "Optional extras. Allow what you use; skip the rest. Dynamo remembers either way.",
                        families: PermissionFamily.optional
                    )
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            footer
        }
        .frame(width: 560, height: 680)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Dynamo")
                .font(.title2.weight(.semibold))
            Text("Dynamo asks for everything it needs and wants up front. Each Allow is a real macOS prompt. Not now is remembered and used — launch will not ask again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(
                value: Double(grantedCount),
                total: Double(max(DynamoPermission.allCases.count, 1))
            )
            .tint(Color.cyan.opacity(0.85))
            Text("\(grantedCount)/\(DynamoPermission.allCases.count) granted")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .padding(.bottom, 4)
    }

    private func familySection(
        title: String,
        caption: String,
        families: [PermissionFamily]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(families) { family in
                familyCard(family)
            }
        }
    }

    private func familyCard(_ family: PermissionFamily) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(family.title)
                .font(.headline)
            Text(family.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(family.members) { permission in
                permissionRow(permission)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func permissionRow(_ permission: DynamoPermission) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusColor(store.status(for: permission)))
                .frame(width: 22)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.displayName)
                    .font(.body.weight(.medium))
                Text(permission.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailingControl(permission)
        }
    }

    @ViewBuilder
    private func trailingControl(_ permission: DynamoPermission) -> some View {
        let status = store.status(for: permission)
        if status == .granted {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if permission == .fullDiskAccess || permission == .notificationMirror {
            Button("System Settings") {
                store.markAsked(permission)
                store.openSystemSettings(for: permission)
            }
            .controlSize(.small)
        } else {
            Button(busy == permission ? "Waiting…" : "Allow") {
                Task {
                    busy = permission
                    await store.requestAccess(permission)
                    busy = nil
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(busy != nil || bulkBusy)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Not now") {
                onFinished()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(bulkBusy)
            Spacer()
            if store.hasUndeterminedAccess {
                Button(bulkBusy ? "Asking…" : "Allow remaining") {
                    Task {
                        bulkBusy = true
                        await store.requestAllUndetermined()
                        bulkBusy = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy != nil || bulkBusy)
            }
            Button("Done") {
                onFinished()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(bulkBusy)
        }
        .padding(20)
        .background(.ultraThinMaterial)
    }

    private var grantedCount: Int {
        DynamoPermission.allCases.filter { store.isGranted($0) }.count
    }

    private func statusColor(_ status: PermissionMemoryStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        case .unknown: return .gray
        }
    }
}
