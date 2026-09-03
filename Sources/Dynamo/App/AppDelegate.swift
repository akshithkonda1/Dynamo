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
    private var airDropShelfMenuItem: NSMenuItem?
    private weak var mediaPlugin: MediaControlsPlugin?
    private let hotKeys = GlobalHotKeys()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            bootstrap()
        }
    }

    /// Opts into the modern (macOS 12+) secure state-restoration contract.
    /// Without this, AppKit logs a console warning on every launch and quit.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            hotKeys.uninstall()
            SystemNotificationMirror.shared.stop()
            DynamoNotificationRouter.shared.stop()
            PeekNotificationCenter.shared.teardown()
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
                DynamoURLRouter.handle(url, notch: notchController, media: mediaPlugin, registry: registry)
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
        // Weather/WeatherKit is replaced by free World Clock in production.
        let media = MediaControlsPlugin(provider: MediaRemoteNowPlayingProvider())
        mediaPlugin = media
        registry.register(media)
        // Peek Hub — Dynamo’s notification inbox (not a system banner mirror).
        registry.register(NotificationsPlugin())
        registry.register(CalendarPlugin())
        registry.register(ClipboardPlugin())
        registry.register(ChecklistPlugin())
        let clocks = WorldClockPlugin()
        registry.register(clocks)
        registry.register(BatteryPlugin())
        registry.register(FocusPlugin())
        registry.register(SportsPlugin())
        registry.register(SystemHealthPlugin())
        registry.register(ShelfPlugin())
        registry.register(WebcamPlugin())

        // World Clock “Here” needs When-In-Use Location. Prompt once on boot so
        // distance sort + city label work without digging into Preferences.
        // Safe if already granted/denied — Core Location no-ops appropriately.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            clocks.requestCurrentLocation()
        }
        // Contacts: so call/text Peeks can show the contact photo + matching tint.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            ContactPhotoResolver.requestAccessOnLaunchIfNeeded()
        }

        WidgetSettingsStore.shared.apply(to: registry)
        // Drop any legacy "weather" id from saved tray prefs.
        WidgetSettingsStore.shared.stripDisabledWidgets(from: registry, ids: ["weather"])
        notchController.attach(registry: registry, hud: hudController, sneakPeek: sneakPeekController)
        hudController.attach(notch: notchController)
        sneakPeekController.attach(registry: registry, notch: notchController)
        // Peek hub (presentation + inbox) + Dynamo as the notification router.
        PeekNotificationCenter.shared.attach(registry: registry, presenter: sneakPeekController)
        DynamoNotificationRouter.shared.start(
            registry: registry,
            hub: PeekNotificationCenter.shared
        )
        PeekBridge.shared.attach(registry: registry)
        DynamoNotificationAPI.installExternalListeners()
        PermissionsStore.shared.refreshFromSystem()
        // Focus peeks are wired inside DynamoNotificationRouter.start
        FocusController.shared.start()
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
        menu.addItem(NSMenuItem(title: "Focus Clipboard", action: #selector(focusClipboard), keyEquivalent: "b"))
        menu.addItem(NSMenuItem(title: "Focus Hub", action: #selector(focusHub), keyEquivalent: "h"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Play/Pause", action: #selector(menuPlayPause), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Mute / Unmute", action: #selector(menuMute), keyEquivalent: "m"))
        menu.addItem(NSMenuItem(title: "AirDrop Last Shelf Item", action: #selector(airDropLastShelfItem), keyEquivalent: ""))
        airDropShelfMenuItem = menu.items.last
        menu.addItem(NSMenuItem.separator())
        let meetingItem = NSMenuItem(title: "Meeting Mode", action: #selector(toggleMeetingMode), keyEquivalent: "")
        meetingItem.state = MeetingMode.shared.isEnabled ? .on : .off
        menu.addItem(meetingItem)
        meetingModeMenuItem = meetingItem
        let hiddenItem = NSMenuItem(title: "Hidden Mode", action: #selector(toggleHiddenMode), keyEquivalent: "")
        hiddenItem.state = (notchController?.isHiddenModeEnabled == true) ? .on : .off
        menu.addItem(hiddenItem)
        hiddenModeMenuItem = hiddenItem
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Preferences", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "About Dynamo", action: #selector(showAboutPanel), keyEquivalent: ""))
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
            case .focusClipboard:
                self.notchController?.focusPlugin(id: "clipboard")
            case .focusHub:
                self.notchController?.focusPlugin(id: "peek-hub")
            case .focusToggle:
                FocusController.shared.cycleMode()
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

    @objc private func focusClipboard() {
        MainActor.assumeIsolated {
            notchController?.focusPlugin(id: "clipboard")
        }
    }

    @objc private func focusHub() {
        MainActor.assumeIsolated {
            notchController?.focusPlugin(id: "peek-hub")
        }
    }

    @objc private func airDropLastShelfItem() {
        MainActor.assumeIsolated {
            registry?.firstPlugin(as: ShelfPlugin.self)?.store.airDropNewest()
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

    // Keep the checkmark in sync if Hidden Mode was toggled from Settings.
    func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            hiddenModeMenuItem?.state = (notchController?.isHiddenModeEnabled == true) ? .on : .off
            meetingModeMenuItem?.state = MeetingMode.shared.isEnabled ? .on : .off
            let hasShelf = !(registry?.firstPlugin(as: ShelfPlugin.self)?.store.items.isEmpty ?? true)
            airDropShelfMenuItem?.isEnabled = hasShelf
        }
    }

    @objc private func toggleHiddenMode() {
        MainActor.assumeIsolated {
            guard let notchController else { return }
            notchController.setHiddenMode(!notchController.isHiddenModeEnabled)
            hiddenModeMenuItem?.state = notchController.isHiddenModeEnabled ? .on : .off
        }
    }

    @objc private func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: [:])
        NSApp.activate(ignoringOtherApps: true)
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

    /// Single daily-driver rule:
    /// - `dist/Dynamo.app` wins: terminate stray/debug/Xcode copies, then continue.
    /// - If the same bundle path is already running, activate it and exit this process.
    /// - Non-dist launches defer to an already-running dist (or any existing instance).
    private static func activateExistingInstanceIfNeeded() -> Bool {
        let mine = NSRunningApplication.current
        let myBundle = mine.bundleURL?.resolvingSymlinksInPath().path ?? ""
        let myExec = mine.executableURL?.resolvingSymlinksInPath().path ?? ""
        let isDistLaunch = myBundle.contains("/dist/Dynamo.app")

        let others = NSWorkspace.shared.runningApplications.filter { app in
            guard app != mine else { return false }
            if app.bundleIdentifier == "com.akshithkonda.Dynamo" { return true }
            // Bare SPM / debug binary may lack a bundle id — match by name.
            let name = app.localizedName ?? ""
            let path = app.bundleURL?.path ?? app.executableURL?.path ?? ""
            return name == "Dynamo" && path.localizedCaseInsensitiveContains("Dynamo")
        }
        guard !others.isEmpty else { return false }

        if isDistLaunch {
            var sameBundleRunning = false
            for app in others {
                let path = app.bundleURL?.resolvingSymlinksInPath().path
                    ?? app.executableURL?.resolvingSymlinksInPath().path
                    ?? ""
                if !myBundle.isEmpty, path == myBundle {
                    sameBundleRunning = true
                    app.activate(options: [.activateIgnoringOtherApps])
                } else if !myExec.isEmpty, path == myExec {
                    sameBundleRunning = true
                    app.activate(options: [.activateIgnoringOtherApps])
                } else {
                    // Older / debug / Xcode build — remove so only dist remains.
                    app.terminate()
                }
            }
            return sameBundleRunning
        }

        // Prefer promoting dist if it is already the daily driver.
        if let dist = others.first(where: {
            ($0.bundleURL?.path ?? "").contains("/dist/Dynamo.app")
        }) {
            dist.activate(options: [.activateIgnoringOtherApps])
            return true
        }
        others.first?.activate(options: [.activateIgnoringOtherApps])
        return true
    }
}
