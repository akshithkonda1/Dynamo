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
        // One instance only — multiple copies fight over the same notch strip
        // and look like the UI is "intermittent" / vanishing.
        if Self.activateExistingInstanceIfNeeded() {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        LaunchAtLogin.applyStoredPreference()

        // Restore last-known permission grants, then re-probe the OS quietly
        // (no prompts). Widgets seed their UI from this memory.
        _ = PermissionsStore.shared
        PermissionsStore.shared.refreshFromSystem()

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
        registry.register(VolumePlugin())
        registry.register(CalendarPlugin())
        registry.register(ClipboardPlugin())
        registry.register(ChecklistPlugin())
        registry.register(WeatherPlugin())
        registry.register(BatteryPlugin())
        registry.register(ShelfPlugin())
        registry.register(WebcamPlugin())

        WidgetSettingsStore.shared.apply(to: registry)
        notchController.attach(registry: registry, hud: hudController, sneakPeek: sneakPeekController)
        hudController.attach(notch: notchController)
        sneakPeekController.attach(registry: registry, notch: notchController)

        installStatusItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .dynamoOpenSettings,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

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
                notchRef.applyPreferredDisplay()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .dynamoPreferredDisplayDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                notchRef.applyPreferredDisplay()
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
        menu.addItem(NSMenuItem(title: "Show Notch", action: #selector(showNotch), keyEquivalent: "n"))
        menu.addItem(NSMenuItem.separator())
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

    /// Force the notch panel on-screen and expanded — useful when the collapsed
    /// strip is easy to miss (it intentionally hugs the physical cutout).
    @objc private func showNotch() {
        MainActor.assumeIsolated {
            notchController?.revealAndExpand()
        }
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
            PermissionsStore.shared.refreshFromSystem()
            guard let registry, let notchController else { return }
            if settingsController == nil {
                settingsController = SettingsWindowController(registry: registry, notch: notchController)
            }
            settingsController?.show()
        }
    }

    @objc private func appDidBecomeActive() {
        MainActor.assumeIsolated {
            // User may have toggled FDA / Camera / Automation in System Settings.
            PermissionsStore.shared.refreshFromSystem()
            NotificationCenter.default.post(name: .dynamoPermissionsDidRefresh, object: nil)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// If another Dynamo is already running (Xcode + package-app, two opens),
    /// bring it forward and tell the new process to exit.
    private static func activateExistingInstanceIfNeeded() -> Bool {
        let mine = NSRunningApplication.current
        let others = NSWorkspace.shared.runningApplications.filter { app in
            guard app != mine else { return false }
            if app.bundleIdentifier == "com.akshithkonda.Dynamo" { return true }
            // Bare SPM / debug binary may lack a bundle id — match by name.
            return app.localizedName == "Dynamo"
                && app.bundleURL?.path.contains("Dynamo") == true
        }
        guard let existing = others.first else { return false }
        existing.activate(options: [.activateIgnoringOtherApps])
        return true
    }
}
