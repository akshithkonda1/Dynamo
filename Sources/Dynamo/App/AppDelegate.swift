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
    private var meetingModeMenuItem: NSMenuItem?
    private weak var mediaPlugin: MediaControlsPlugin?
    private let hotKeys = GlobalHotKeys()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            bootstrap()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            hotKeys.uninstall()
            PeekBridge.shared.teardown()
            registry?.stopAll()
            hudController?.teardown()
            sneakPeekController?.teardown()
            notchController?.teardown()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                DynamoURLRouter.handle(url, notch: notchController, media: mediaPlugin)
            }
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
        let media = MediaControlsPlugin(provider: MediaRemoteNowPlayingProvider())
        mediaPlugin = media
        registry.register(media)
        registry.register(CalendarPlugin())
        registry.register(ClipboardPlugin())
        registry.register(ChecklistPlugin())
        registry.register(WeatherPlugin())
        registry.register(BatteryPlugin())
        registry.register(SystemHealthPlugin())
        registry.register(ShelfPlugin())
        registry.register(WebcamPlugin())

        WidgetSettingsStore.shared.apply(to: registry)
        notchController.attach(registry: registry, hud: hudController, sneakPeek: sneakPeekController)
        hudController.attach(notch: notchController)
        sneakPeekController.attach(registry: registry, notch: notchController)
        PeekBridge.shared.attach(registry: registry)
        FocusQuietMonitor.shared.start()

        installStatusItem()
        installHotKeys()

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
        menu.addItem(NSMenuItem(title: "Focus File Shelf", action: #selector(focusShelf), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Focus Calendar", action: #selector(focusCalendar), keyEquivalent: "c"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Play/Pause", action: #selector(menuPlayPause), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Mute / Unmute", action: #selector(menuMute), keyEquivalent: "m"))
        menu.addItem(NSMenuItem.separator())
        let meetingItem = NSMenuItem(title: "Meeting Mode", action: #selector(toggleMeetingMode), keyEquivalent: "")
        meetingItem.state = MeetingMode.shared.isEnabled ? .on : .off
        menu.addItem(meetingItem)
        meetingModeMenuItem = meetingItem
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

    @MainActor
    private func installHotKeys() {
        hotKeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .showNotch:
                self.notchController?.revealAndExpand()
            case .playPause:
                self.mediaPlugin?.togglePlayPause()
            case .mute:
                SystemVolumeController.shared.toggleMute()
            case .focusShelf:
                self.notchController?.focusPlugin(id: "shelf")
            case .focusCalendar:
                self.notchController?.focusPlugin(id: "calendar")
            }
        }
        hotKeys.install()
    }

    /// Force the notch panel on-screen and expanded — useful when the collapsed
    /// strip is easy to miss (it intentionally hugs the physical cutout).
    @objc private func showNotch() {
        MainActor.assumeIsolated {
            notchController?.revealAndExpand()
        }
    }

    @objc private func focusShelf() {
        MainActor.assumeIsolated {
            notchController?.focusPlugin(id: "shelf")
        }
    }

    @objc private func focusCalendar() {
        MainActor.assumeIsolated {
            notchController?.focusPlugin(id: "calendar")
        }
    }

    @objc private func menuPlayPause() {
        MainActor.assumeIsolated {
            mediaPlugin?.togglePlayPause()
        }
    }

    @objc private func menuMute() {
        MainActor.assumeIsolated {
            SystemVolumeController.shared.toggleMute()
        }
    }

    @objc private func toggleMeetingMode() {
        MainActor.assumeIsolated {
            MeetingMode.shared.isEnabled.toggle()
            meetingModeMenuItem?.state = MeetingMode.shared.isEnabled ? .on : .off
        }
    }

    // Keep the checkmark in sync if Hidden mode was toggled from Settings.
    func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            hiddenModeMenuItem?.state = (notchController?.isHiddenModeEnabled == true) ? .on : .off
            meetingModeMenuItem?.state = MeetingMode.shared.isEnabled ? .on : .off
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
