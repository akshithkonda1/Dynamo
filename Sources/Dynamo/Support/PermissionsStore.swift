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
        case .automationMusic: return "Control Music app"
        case .automationSpotify: return "Control Spotify"
        case .automationNotes: return "Control Notes"
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
            return "MusicKit: now playing, queue, library, play/pause/skip"
        case .appleFocus:
            return "Quiet the notch when Do Not Disturb or a Focus is on"
        case .fullDiskAccess:
            return "Optional Calendar local DB fallback + broader file access"
        case .notificationMirror:
            return "Mirror other apps’ Notification Center alerts into Peek"
        case .automationMusic:
            return "AppleScript fallback if MusicKit cannot control Music.app"
        case .automationSpotify:
            return "Play/pause, skip, cover art (Spotify has no MusicKit API)"
        case .automationNotes:
            return "AppleScript: Notes has no public framework"
        }
    }

    /// Whether the feature is core vs optional.
    var isRequiredForCore: Bool {
        switch self {
        case .calendar, .reminders, .musicKit:
            return true
        default:
            return false
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
        }
    }
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

    private static let defaultsKey = "dynamo.permissions.memory.v2"
    private var didLoad = false

    private init() {
        load()
        refreshFromSystem()
    }

    // MARK: - Public API

    func status(for permission: DynamoPermission) -> PermissionMemoryStatus {
        statuses[permission] ?? .unknown
    }

    func isGranted(_ permission: DynamoPermission) -> Bool {
        status(for: permission) == .granted
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
            try? await Task.sleep(nanoseconds: 400_000_000)
        case .contacts:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .musicKit:
            _ = await MusicAuthorization.request()
        case .appleFocus:
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                INFocusStatusCenter.default.requestAuthorization { _ in cont.resume() }
            }
        case .automationMusic:
            await Self.pingAppleScript(application: "Music")
        case .automationSpotify:
            await Self.pingAppleScript(application: "Spotify")
        case .automationNotes:
            await Self.pingAppleScript(application: "Notes")
        case .fullDiskAccess, .notificationMirror:
            openSystemSettings(for: permission)
        }
        refreshFromSystem()
    }

    private let locationPrompter = CLLocationManager()

    private static func pingAppleScript(application: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let source = "tell application \"\(application)\" to get name"
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                cont.resume()
            }
        }
    }

    /// Re-read OS state. Safe to call often (launch, become active, Settings open).
    func refreshFromSystem() {
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
        persist()
        NotificationCenter.default.post(name: .dynamoPermissionsDidRefresh, object: nil)
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
            break
        }
    }

    private func persist() {
        var values: [String: String] = [:]
        for (perm, status) in statuses {
            values[perm.rawValue] = status.rawValue
        }
        if let data = try? JSONEncoder().encode(Snapshot(values: values)) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

extension Notification.Name {
    static let dynamoPermissionsDidRefresh = Notification.Name("dynamoPermissionsDidRefresh")
}
