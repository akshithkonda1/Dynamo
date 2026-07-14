import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var registry: WidgetRegistry?
    private var notchController: NotchWindowController?
    private var hudController: SystemHUDController?
    private var sneakPeekController: NotchSneakPeekController?
    private var statusItem: NSStatusItem?
    private var settingsController: SettingsWindowController?
    private var hiddenModeMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            bootstrap()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            registry?.stopAll()
            hudController?.teardown()
            sneakPeekController?.teardown()
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
        let sneakPeekController = NotchSneakPeekController()
        self.registry = registry
        self.notchController = notchController
        self.hudController = hudController
        self.sneakPeekController = sneakPeekController

        // Default tray order. Settings can reorder without hosts knowing names.
        registry.register(MediaControlsPlugin(provider: MediaRemoteNowPlayingProvider()))
        registry.register(CalendarPlugin())
        registry.register(ClipboardPlugin())
        registry.register(ChecklistPlugin())
        registry.register(WeatherPlugin())
        registry.register(BatteryPlugin())
        registry.register(ShelfPlugin())
        registry.register(WebcamPlugin())
        registry.register(MessagesPlugin())

        WidgetSettingsStore.shared.apply(to: registry)
        notchController.attach(registry: registry, hud: hudController, sneakPeek: sneakPeekController)
        hudController.attach(notch: notchController)
        sneakPeekController.attach(registry: registry, notch: notchController)

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
        menu.delegate = self
        let hiddenItem = NSMenuItem(title: "Hidden mode", action: #selector(toggleHiddenMode), keyEquivalent: "")
        hiddenItem.state = (notchController?.isHiddenModeEnabled == true) ? .on : .off
        menu.addItem(hiddenItem)
        hiddenModeMenuItem = hiddenItem
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Dynamo", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    // Keep the checkmark in sync if Hidden mode was toggled from Settings.
    func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            hiddenModeMenuItem?.state = (notchController?.isHiddenModeEnabled == true) ? .on : .off
        }
    }

    @objc private func toggleHiddenMode() {
        MainActor.assumeIsolated {
            guard let notchController else { return }
            notchController.setHiddenMode(!notchController.isHiddenModeEnabled)
            hiddenModeMenuItem?.state = notchController.isHiddenModeEnabled ? .on : .off
        }
    }

    @objc private func openSettings() {
        MainActor.assumeIsolated {
            guard let registry, let notchController else { return }
            if settingsController == nil {
                settingsController = SettingsWindowController(registry: registry, notch: notchController)
            }
            settingsController?.show()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
