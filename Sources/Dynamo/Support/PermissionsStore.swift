import AppKit
import ApplicationServices
import AVFoundation
import Contacts
import CoreLocation
import EventKit
import Foundation
import Intents
import MusicKit
import Speech

/// Every macOS permission Dynamo may need. OS TCC still owns the real grant;
/// this store remembers last-known status and re-probes without re-prompting.
enum DynamoPermission: String, CaseIterable, Codable, Identifiable {
    case calendar
    case reminders
    case camera
    case microphone
    case speech
    case location
    case contacts
    case musicKit
    case appleFocus
    case fullDiskAccess
    case notificationMirror
    case automationMusic
    case automationSpotify
    case automationNotes
    /// Accessibility + input for Dynamo’s own HUD, media keys, and notch.
    case dynamoControls

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .speech: return "Speech Recognition"
        case .location: return "Location"
        case .contacts: return "Contacts"
        case .musicKit: return "Apple Music"
        case .appleFocus: return "Apple Focus"
        case .fullDiskAccess: return "Full Disk Access"
        case .notificationMirror: return "Notification Center (mirror)"
        case .automationMusic: return "Control Music"
        case .automationSpotify: return "Control Spotify"
        case .automationNotes: return "Control Notes"
        case .dynamoControls: return "Dynamo controls"
        }
    }

    /// Short “used for” line in Settings.
    var detail: String {
        switch self {
        case .calendar:
            return "EventKit: events, Meeting context, True Focus agenda"
        case .reminders:
            return "EventKit: list, create, complete, delete, due peeks"
        case .camera:
            return "Webcam mirror (only while the Webcam tab is open)"
        case .microphone:
            return "Meeting Listen (speech notes) and live music equalizer analysis"
        case .speech:
            return "Meeting Mode notetaker (on-device preferred)"
        case .location:
            return "WeatherKit and World Clock “Here” — city-level location only"
        case .contacts:
            return "Contact photos on call and text Peeks"
        case .musicKit:
            return "MusicKit: library, catalog, artwork — Apple Music in Dynamo"
        case .appleFocus:
            return "Quiet the notch when Do Not Disturb or a Focus is on"
        case .fullDiskAccess:
            return "Optional Calendar local DB fallback + broader file access"
        case .notificationMirror:
            return "Mirror other apps’ Notification Center alerts into Peek"
        case .automationMusic:
            return "Control Music: macOS Automation so Dynamo can play, skip, and read Music.app"
        case .automationSpotify:
            return "Play/pause, skip, cover art (Spotify has no MusicKit API)"
        case .automationNotes:
            return "AppleScript: Notes has no public framework"
        case .dynamoControls:
            return "Accessibility so Dynamo can own volume/brightness keys and the notch HUD"
        }
    }

    /// Whether the feature is core vs optional.
    var isRequiredForCore: Bool {
        family.isCore
    }

    /// Onboarding + Settings grouping. MusicKit and Control Music share a card;
    /// Dynamo controls stay a separate prompt.
    var family: PermissionFamily {
        switch self {
        case .musicKit, .automationMusic: return .appleMusic
        case .dynamoControls: return .dynamoControls
        case .calendar: return .calendar
        case .reminders: return .reminders
        case .camera: return .camera
        case .microphone: return .microphone
        case .speech: return .speech
        case .location: return .location
        case .contacts: return .contacts
        case .appleFocus: return .appleFocus
        case .automationSpotify: return .automationSpotify
        case .automationNotes: return .automationNotes
        case .fullDiskAccess: return .fullDiskAccess
        case .notificationMirror: return .notificationMirror
        }
    }

    var systemImage: String {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .camera: return "web.camera"
        case .microphone: return "mic.fill"
        case .speech: return "waveform.badge.mic"
        case .location: return "location.fill"
        case .contacts: return "person.crop.circle"
        case .musicKit: return "music.note.house"
        case .appleFocus: return "moon.fill"
        case .fullDiskAccess: return "internaldrive"
        case .notificationMirror: return "bell.badge"
        case .automationMusic: return "music.note"
        case .automationSpotify: return "music.note.list"
        case .automationNotes: return "note.text"
        case .dynamoControls: return "computermouse"
        }
    }

    /// Full Disk Access has no in-app dialog — System Settings is the only path.
    var requiresSystemSettingsPane: Bool {
        switch self {
        case .fullDiskAccess, .notificationMirror: return true
        default: return false
        }
    }

    /// macOS will still show a dialog after a denial for these.
    var canRePromptWhenDenied: Bool {
        switch self {
        case .dynamoControls, .automationMusic, .automationSpotify, .automationNotes:
            return true
        default:
            return false
        }
    }

    func showsAllow(for status: PermissionMemoryStatus) -> Bool {
        if requiresSystemSettingsPane { return false }
        switch status {
        case .granted: return false
        case .notDetermined, .unknown: return true
        case .denied: return canRePromptWhenDenied
        }
    }

    func showsOpenSettings(for status: PermissionMemoryStatus) -> Bool {
        if requiresSystemSettingsPane { return true }
        switch status {
        case .granted, .denied, .unknown: return true
        case .notDetermined: return false
        }
    }

    func openSettingsTitle(for status: PermissionMemoryStatus) -> String {
        status == .granted ? "Change" : "Open Settings"
    }
}

/// One onboarding card / Settings cluster. Apple Music holds MusicKit + Control Music.
enum PermissionFamily: String, CaseIterable, Identifiable {
    case appleMusic
    case dynamoControls
    case calendar
    case reminders
    case camera
    case microphone
    case speech
    case location
    case contacts
    case appleFocus
    case automationSpotify
    case automationNotes
    case fullDiskAccess
    case notificationMirror

    var id: String { rawValue }

    var isCore: Bool {
        switch self {
        case .appleMusic, .dynamoControls, .calendar, .reminders:
            return true
        default:
            return false
        }
    }

    var members: [DynamoPermission] {
        DynamoPermission.allCases.filter { $0.family == self }
    }

    var title: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .dynamoControls: return "Dynamo controls"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .speech: return "Speech Recognition"
        case .location: return "Location"
        case .contacts: return "Contacts"
        case .appleFocus: return "Apple Focus"
        case .automationSpotify: return "Control Spotify"
        case .automationNotes: return "Control Notes"
        case .fullDiskAccess: return "Full Disk Access"
        case .notificationMirror: return "Notification Center (mirror)"
        }
    }

    var summary: String {
        switch self {
        case .appleMusic:
            return "Two separate macOS grants: MusicKit for Apple Music, then Control Music so Dynamo can drive Music.app. Dynamo’s own keys are the next step."
        case .dynamoControls:
            return "Lets Dynamo replace the system volume/brightness HUD and keep the island interactive. This is not the Music.app Automation prompt."
        case .calendar:
            return "Upcoming events, meeting countdown, and True Focus agenda."
        case .reminders:
            return "Checklist reads and updates Apple Reminders."
        case .camera:
            return "Webcam mirror only while that tab is open."
        case .microphone:
            return "Meeting Listen and the live music equalizer."
        case .speech:
            return "Meeting notes from speech, on-device when possible."
        case .location:
            return "Optional city label for Clocks “Here” and Weather."
        case .contacts:
            return "Photos on call and text Peeks."
        case .appleFocus:
            return "Keeps the notch quiet during Do Not Disturb."
        case .automationSpotify:
            return "Needed to control Spotify — it has no MusicKit API."
        case .automationNotes:
            return "Checklist Notes talks to the Notes app through Automation."
        case .fullDiskAccess:
            return "Optional. Calendar database fallback and notification mirror."
        case .notificationMirror:
            return "Mirror other apps’ alerts into Peek. Uses Full Disk Access."
        }
    }

    static var core: [PermissionFamily] { allCases.filter(\.isCore) }
    static var optional: [PermissionFamily] { allCases.filter { !$0.isCore } }
}

enum PermissionMemoryStatus: String, Codable, Equatable {
    case unknown
    case notDetermined
    case granted
    case denied
}

/// Persists last-known permission outcomes and refreshes them from the OS.
@MainActor
final class PermissionsStore: ObservableObject {
    static let shared = PermissionsStore()

    @Published private(set) var statuses: [DynamoPermission: PermissionMemoryStatus] = [:]
    @Published private(set) var asked: Set<DynamoPermission> = []
    @Published var onboardingCompleted: Bool {
        didSet { UserDefaults.standard.set(onboardingCompleted, forKey: Self.onboardingKey) }
    }

    private static let defaultsKey = "dynamo.permissions.memory.v2"
    private static let onboardingKey = "dynamo.permissions.onboardingCompleted.v1"
    private var didLoad = false
    private var liveTimer: Timer?
    private var liveClients = 0
    private var lastAppliedGranted: Set<DynamoPermission> = []
    private let locationPrompter = CLLocationManager()
    private let locationProbe = LocationAuthProbe()

    private init() {
        onboardingCompleted = UserDefaults.standard.bool(forKey: Self.onboardingKey)
        load()
        locationPrompter.desiredAccuracy = kCLLocationAccuracyReduced
        locationPrompter.delegate = locationProbe
        locationProbe.onChange = { [weak self] in
            Task { @MainActor in self?.refreshFromSystem() }
        }
        refreshFromSystem()
        lastAppliedGranted = grantedSet
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFromSystem() }
        }
    }

    // MARK: - Public API

    func status(for permission: DynamoPermission) -> PermissionMemoryStatus {
        statuses[permission] ?? .unknown
    }

    func isGranted(_ permission: DynamoPermission) -> Bool {
        status(for: permission) == .granted
    }

    func hasAsked(_ permission: DynamoPermission) -> Bool {
        asked.contains(permission)
    }

    func markAsked(_ permission: DynamoPermission) {
        asked.insert(permission)
        persist()
    }

    /// True until the first-launch walk has finished, or a core grant was
    /// reset by the OS and Dynamo has never asked for it this install.
    func needsOnboarding() -> Bool {
        if !onboardingCompleted { return true }
        return DynamoPermission.allCases.contains {
            $0.isRequiredForCore && status(for: $0) == .notDetermined && !hasAsked($0)
        }
    }

    var hasUndeterminedAccess: Bool {
        DynamoPermission.allCases.contains {
            let s = status(for: $0)
            return s == .notDetermined || s == .unknown
        }
    }

    /// Remember every remaining skip so launch never re-prompts, then apply grants.
    func completeOnboarding() {
        asked.formUnion(DynamoPermission.allCases)
        persist()
        onboardingCompleted = true
        refreshFromSystem()
        applyGrantedServices()
    }

    /// Poll OS TCC while Settings or the onboarding window is on screen so a
    /// toggle in System Settings flips the row as soon as macOS records it.
    func beginLiveUpdates() {
        liveClients += 1
        refreshFromSystem()
        guard liveTimer == nil else { return }
        let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFromSystem() }
        }
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    func endLiveUpdates() {
        liveClients = max(0, liveClients - 1)
        guard liveClients == 0 else { return }
        liveTimer?.invalidate()
        liveTimer = nil
    }

    func stopLiveUpdates() {
        liveClients = 0
        liveTimer?.invalidate()
        liveTimer = nil
    }

    /// In-app prompt when macOS will show one; otherwise jump to the privacy pane.
    /// Rows refresh as soon as the OS grant changes.
    func promptOrOpen(_ permission: DynamoPermission) async {
        markAsked(permission)
        beginLiveUpdates()
        defer { endLiveUpdates() }
        if permission.requiresSystemSettingsPane || status(for: permission) == .denied,
           !permission.canRePromptWhenDenied || permission.requiresSystemSettingsPane {
            openSystemSettings(for: permission)
            await waitForStatusChange(permission)
            return
        }
        await requestAccess(permission)
        if status(for: permission) == .denied {
            openSystemSettings(for: permission)
            await waitForStatusChange(permission)
        }
    }

    func openAndWatch(_ permission: DynamoPermission) async {
        markAsked(permission)
        beginLiveUpdates()
        defer { endLiveUpdates() }
        openSystemSettings(for: permission)
        await waitForStatusChange(permission)
    }

    private func waitForStatusChange(_ permission: DynamoPermission) async {
        let start = status(for: permission)
        for _ in 0..<80 {
            refreshFromSystem()
            if status(for: permission) != start { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private var grantedSet: Set<DynamoPermission> {
        Set(DynamoPermission.allCases.filter { statuses[$0] == .granted })
    }

    /// Sequential real macOS prompts for every grant still open. Full Disk
    /// Access stays a Settings jump, so bulk allow skips it.
    func requestAllUndetermined() async {
        for permission in DynamoPermission.allCases {
            let current = status(for: permission)
            if current == .granted { continue }
            if permission == .fullDiskAccess || permission == .notificationMirror {
                markAsked(permission)
                continue
            }
            if current == .notDetermined || current == .unknown {
                await requestAccess(permission)
            }
        }
    }

    /// Start MusicKit / HUD / AppleScript only for grants we already have.
    func applyGrantedServices() {
        if isGranted(.musicKit) {
            Task { await MusicKitBridge.shared.syncFromSystem() }
        }
        NotificationCenter.default.post(name: .dynamoPermissionsDidApply, object: nil)
    }

    func recordGranted(_ permission: DynamoPermission) {
        update(permission, to: .granted)
        persist()
    }

    func recordDenied(_ permission: DynamoPermission) {
        update(permission, to: .denied)
        persist()
    }

    /// Ask macOS for this grant in-app. Only Full Disk Access has to jump to Settings.
    func requestAccess(_ permission: DynamoPermission) async {
        markAsked(permission)
        switch permission {
        case .calendar:
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                _ = try? await store.requestFullAccessToEvents()
            } else {
                _ = try? await store.requestAccess(to: .event)
            }
        case .reminders:
            let store = EKEventStore()
            if #available(macOS 14.0, *) {
                _ = try? await store.requestFullAccessToReminders()
            } else {
                _ = try? await store.requestAccess(to: .reminder)
            }
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speech:
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in cont.resume() }
            }
        case .location:
            locationPrompter.requestWhenInUseAuthorization()
            await waitUntil({ Self.probeLocation() != .notDetermined }, attempts: 40)
        case .contacts:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .musicKit:
            _ = await MusicAuthorization.request()
        case .appleFocus:
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                INFocusStatusCenter.default.requestAuthorization { _ in cont.resume() }
            }
        case .automationMusic:
            await Self.requestAutomation(bundleID: "com.apple.Music", application: "Music")
        case .automationSpotify:
            await Self.requestAutomation(bundleID: "com.spotify.client", application: "Spotify")
        case .automationNotes:
            await Self.requestAutomation(bundleID: "com.apple.Notes", application: "Notes")
        case .dynamoControls:
            _ = MediaKeyInterceptor.requestAccessibilityIfNeeded()
            await waitUntil({ AXIsProcessTrusted() }, attempts: 40)
        case .fullDiskAccess, .notificationMirror:
            openSystemSettings(for: permission)
            await waitForStatusChange(permission)
        }
        refreshFromSystem()
        applyGrantedServices()
    }

    private func waitUntil(_ test: @escaping () -> Bool, attempts: Int) async {
        for _ in 0..<attempts {
            if test() { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Shows the macOS “Control Music / Spotify / Notes” Automation dialog.
    private static func requestAutomation(bundleID: String, application: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var address = AEAddressDesc()
                let created = bundleID.withCString { cstr -> OSErr in
                    AECreateDesc(typeApplicationBundleID, cstr, strlen(cstr), &address)
                }
                if created == noErr {
                    _ = AEDeterminePermissionToAutomateTarget(
                        &address,
                        typeWildCard,
                        typeWildCard,
                        true
                    )
                    AEDisposeDesc(&address)
                }
                let source = "tell application \"\(application)\" to get name"
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                cont.resume()
            }
        }
    }

    /// Re-read OS state. Safe to call often (launch, become active, Settings open).
    func refreshFromSystem() {
        let before = grantedSet
        update(.calendar, to: Self.probeCalendar())
        update(.reminders, to: Self.probeReminders())
        update(.camera, to: Self.probeCamera())
        update(.microphone, to: Self.probeMicrophone())
        update(.speech, to: Self.probeSpeech())
        update(.location, to: Self.probeLocation())
        update(.contacts, to: Self.probeContacts())
        update(.musicKit, to: Self.probeMusicKit())
        update(.appleFocus, to: Self.probeAppleFocus())
        update(.fullDiskAccess, to: Self.probeFullDiskAccess())
        update(.notificationMirror, to: Self.probeNotificationMirror())
        update(.automationMusic, to: Self.probeAutomation(bundleID: "com.apple.Music"))
        update(.automationSpotify, to: Self.probeAutomation(bundleID: "com.spotify.client"))
        update(.automationNotes, to: Self.probeAutomation(bundleID: "com.apple.Notes"))
        update(.dynamoControls, to: Self.probeDynamoControls(asked: asked.contains(.dynamoControls)))
        persist()
        NotificationCenter.default.post(name: .dynamoPermissionsDidRefresh, object: nil)
        let after = grantedSet
        if after != before || after != lastAppliedGranted {
            lastAppliedGranted = after
            applyGrantedServices()
        }
    }

    func openSystemSettings(for permission: DynamoPermission) {
        let urls: [String]
        switch permission {
        case .calendar:
            urls = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars"
            ]
        case .reminders:
            urls = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Reminders"
            ]
        case .camera:
            urls = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera"
            ]
        case .microphone:
            urls = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
            ]
        case .speech:
            urls = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_SpeechRecognition"
            ]
        case .location:
            urls = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices"
            ]
        case .contacts:
            urls = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Contacts"
            ]
        case .musicKit:
            urls = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Media",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Media"
            ]
        case .appleFocus:
            urls = [
                "x-apple.systempreferences:com.apple.Focus-Settings.extension",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Focus"
            ]
        case .fullDiskAccess, .notificationMirror:
            // Notification mirror needs the same Group Containers / FDA-class access.
            urls = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
            ]
        case .automationMusic, .automationSpotify, .automationNotes:
            urls = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            ]
        case .dynamoControls:
            urls = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ]
        }
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - Probes (never prompt)

    private static func probeCalendar() -> PermissionMemoryStatus {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess: return .granted
            case .authorized: return .granted
            // Write-only cannot list events — treat as incomplete for Permissions UI.
            case .writeOnly: return .notDetermined
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            @unknown default: return .unknown
            }
        } else {
            switch status {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            default: return .unknown
            }
        }
    }

    private static func probeReminders() -> PermissionMemoryStatus {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess, .authorized, .writeOnly: return .granted
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            @unknown default: return .unknown
            }
        } else {
            switch status {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            default: return .unknown
            }
        }
    }

    private static func probeCamera() -> PermissionMemoryStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    private static func probeMicrophone() -> PermissionMemoryStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    private static func probeSpeech() -> PermissionMemoryStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    private static func probeContacts() -> PermissionMemoryStatus {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    private static func probeMusicKit() -> PermissionMemoryStatus {
        switch MusicAuthorization.currentStatus {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    private static func probeAppleFocus() -> PermissionMemoryStatus {
        switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    private static func probeLocation() -> PermissionMemoryStatus {
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        default:
            let raw = CLLocationManager().authorizationStatus.rawValue
            return raw >= 3 ? .granted : .unknown
        }
    }

    private static func probeFullDiskAccess() -> PermissionMemoryStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let calendarDB = home
            .appendingPathComponent("Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb")
        let calOK = isEffectivelyReadable(calendarDB)
        let calExists = FileManager.default.fileExists(atPath: calendarDB.path)
        if calOK { return .granted }
        // Usernoted readable often implies FDA-class access too.
        if probeNotificationMirror() == .granted { return .granted }
        if calExists { return .denied }
        return .unknown
    }

    private static func probeNotificationMirror() -> PermissionMemoryStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            home.appendingPathComponent(
                "Library/Group Containers/group.com.apple.usernoted/db2/db"
            ),
            home.appendingPathComponent(
                "Library/Group Containers/group.com.apple.usernoted/Library/Application Support/db2/db"
            )
        ]
        var anyExists = false
        for url in paths {
            if FileManager.default.fileExists(atPath: url.path) {
                anyExists = true
                if isEffectivelyReadable(url) { return .granted }
            }
        }
        return anyExists ? .denied : .unknown
    }

    private static func isEffectivelyReadable(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return FileManager.default.isReadableFile(atPath: url.path)
        }
        try? handle.close()
        return true
    }

    private static func probeDynamoControls(asked: Bool) -> PermissionMemoryStatus {
        if AXIsProcessTrusted() { return .granted }
        return asked ? .denied : .notDetermined
    }

    private static func probeAutomation(bundleID: String) -> PermissionMemoryStatus {
        var address = AEAddressDesc()
        let createStatus = bundleID.withCString { cstr -> OSErr in
            AECreateDesc(typeApplicationBundleID, cstr, strlen(cstr), &address)
        }
        guard createStatus == noErr else { return .unknown }
        defer { AEDisposeDesc(&address) }

        let err = AEDeterminePermissionToAutomateTarget(
            &address,
            typeWildCard,
            typeWildCard,
            false
        )
        switch Int(err) {
        case 0: return .granted
        case -1743: return .denied
        case -1744: return .notDetermined
        default: return .unknown
        }
    }

    // MARK: - Persistence

    private func update(_ permission: DynamoPermission, to status: PermissionMemoryStatus) {
        if status == .unknown, statuses[permission] == .granted {
            return
        }
        guard statuses[permission] != status else { return }
        statuses[permission] = status
        objectWillChange.send()
    }

    private struct Snapshot: Codable {
        var values: [String: String]
        var asked: [String]?
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        // Prefer v2; fall back to v1 keys that still match.
        let keys = ["dynamo.permissions.memory.v2", "dynamo.permissions.memory.v1"]
        for key in keys {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
            else { continue }
            for (rawKey, raw) in snap.values {
                guard let perm = DynamoPermission(rawValue: rawKey),
                      let status = PermissionMemoryStatus(rawValue: raw)
                else { continue }
                statuses[perm] = status
            }
            if let askedKeys = snap.asked {
                asked = Set(askedKeys.compactMap(DynamoPermission.init(rawValue:)))
            }
            break
        }
    }

    private func persist() {
        var values: [String: String] = [:]
        for (perm, status) in statuses {
            values[perm.rawValue] = status.rawValue
        }
        let snap = Snapshot(values: values, asked: asked.map(\.rawValue).sorted())
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

extension Notification.Name {
    static let dynamoPermissionsDidRefresh = Notification.Name("dynamoPermissionsDidRefresh")
    static let dynamoPermissionsDidApply = Notification.Name("dynamoPermissionsDidApply")
}

/// Forwards Core Location auth changes onto the main-actor store.
private final class LocationAuthProbe: NSObject, CLLocationManagerDelegate {
    var onChange: (() -> Void)?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }
}
