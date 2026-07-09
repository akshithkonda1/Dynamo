import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var registry: WidgetRegistry?
    private var notchController: NotchWindowController?
    private var hudController: SystemHUDController?
    private var statusItem: NSStatusItem?
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            bootstrap()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            registry?.stopAll()
            hudController?.teardown()
            notchController?.teardown()
        }
    }

    @MainActor
    private func bootstrap() {
        NSApp.setActivationPolicy(.accessory)
        LaunchAtLogin.applyStoredPreference()

        let registry = WidgetRegistry()
        let notchController = NotchWindowController()
        let hudController = SystemHUDController()
        self.registry = registry
        self.notchController = notchController
        self.hudController = hudController

        // Default tray order. Settings can reorder without hosts knowing names.
        registry.register(MediaControlsPlugin(provider: MediaRemoteNowPlayingProvider()))
        registry.register(CalendarPlugin())
        registry.register(ClipboardPlugin())
        registry.register(ChecklistPlugin())
        registry.register(StocksPlugin())
        registry.register(BatteryPlugin())
        registry.register(ShelfPlugin())

        WidgetSettingsStore.shared.apply(to: registry)
        notchController.attach(registry: registry, hud: hudController)
        hudController.attach(notch: notchController)

        installStatusItem()

        let registryRef = registry
        NotificationCenter.default.addObserver(
            forName: .dynamoWidgetConfigurationDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                WidgetSettingsStore.shared.persist(from: registryRef)
            }
        }

        let notchRef = notchController
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                notchRef.reposition()
            }
        }
    }

    // MARK: - Menu bar

    @MainActor
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.topthird.inset.filled",
                accessibilityDescription: "Dynamo"
            )
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Dynamo", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() {
        MainActor.assumeIsolated {
            guard let registry else { return }
            if settingsController == nil {
                settingsController = SettingsWindowController(registry: registry)
            }
            settingsController?.show()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
