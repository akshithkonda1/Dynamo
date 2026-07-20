import AppKit
import ApplicationServices
import AVFoundation
import CoreLocation
import EventKit
import Foundation

/// High-level permission Dynamo cares about. OS TCC still owns the real grant;
/// this store **remembers** last-known status so UI doesn't reset every launch,
/// and re-probes the system when the app becomes active.
enum DynamoPermission: String, CaseIterable, Codable {
    case camera
    case location
    case fullDiskAccess
    case reminders
    case automationMusic
    case automationSpotify

    var displayName: String {
        switch self {
        case .camera: return "Camera"
        case .location: return "Location"
        case .fullDiskAccess: return "Full Disk Access"
        case .reminders: return "Reminders"
        case .automationMusic: return "Control Music"
        case .automationSpotify: return "Control Spotify"
        }
    }

    var detail: String {
        switch self {
        case .camera: return "Webcam mirror"
        case .location: return "Weather (automatic)"
        case .fullDiskAccess: return "Calendar local database"
        case .reminders: return "Due reminders peek in Calendar"
        case .automationMusic: return "Play/pause, skip, cover art, playlists"
        case .automationSpotify: return "Play/pause, skip, cover art"
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

    private static let defaultsKey = "dynamo.permissions.memory.v1"
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

    /// Call after a successful privileged operation so we remember it immediately.
    func recordGranted(_ permission: DynamoPermission) {
        update(permission, to: .granted)
        persist()
    }

    /// Call after an explicit denial / failed privileged operation.
    func recordDenied(_ permission: DynamoPermission) {
        update(permission, to: .denied)
        persist()
    }

    /// Re-read OS state. Safe to call often (launch, become active, Settings open).
    func refreshFromSystem() {
        update(.camera, to: Self.probeCamera())
        update(.location, to: Self.probeLocation())
        update(.fullDiskAccess, to: Self.probeFullDiskAccess())
        update(.reminders, to: Self.probeReminders())
        update(.automationMusic, to: Self.probeAutomation(bundleID: "com.apple.Music"))
        update(.automationSpotify, to: Self.probeAutomation(bundleID: "com.spotify.client"))
        persist()
    }

    func openSystemSettings(for permission: DynamoPermission) {
        let urls: [String]
        switch permission {
        case .camera:
            urls = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera"
            ]
        case .location:
            urls = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices"
            ]
        case .fullDiskAccess:
            urls = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
            ]
        case .reminders:
            urls = [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Reminders"
            ]
        case .automationMusic, .automationSpotify:
            urls = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            ]
        }
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - Probes

    private static func probeCamera() -> PermissionMemoryStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
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
            // authorizedWhenInUse / legacy .authorized on some SDKs
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
        if calExists { return .denied }
        return .unknown
    }

    /// Passive status read only — `EKEventStore.authorizationStatus(for:)`
    /// never prompts; only `requestFullAccessToReminders()` /
    /// `requestAccess(to:)` do, and those are only ever called from
    /// `LocalCalendarDatabaseProvider.requestRemindersAccess()` in response
    /// to explicit user action.
    private static func probeReminders() -> PermissionMemoryStatus {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess, .authorized: return .granted
            case .notDetermined: return .notDetermined
            case .denied, .restricted, .writeOnly: return .denied
            @unknown default: return .unknown
            }
        } else {
            switch status {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            @unknown default: return .unknown
            }
        }
    }

    /// True if we can open the file for reading (stronger than `isReadableFile`).
    private static func isEffectivelyReadable(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // Try a real open — FDA denials fail here even when isReadableFile is true/false inconsistently.
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return FileManager.default.isReadableFile(atPath: url.path)
        }
        try? handle.close()
        return true
    }

    /// Automation permission for controlling another app via Apple Events.
    private static func probeAutomation(bundleID: String) -> PermissionMemoryStatus {
        var address = AEAddressDesc()
        let createStatus = bundleID.withCString { cstr -> OSErr in
            AECreateDesc(typeApplicationBundleID, cstr, strlen(cstr), &address)
        }
        guard createStatus == noErr else { return .unknown }
        defer { AEDisposeDesc(&address) }

        // askUserIfNeeded: false — never pop a prompt during a background probe.
        let err = AEDeterminePermissionToAutomateTarget(
            &address,
            typeWildCard,
            typeWildCard,
            false
        )
        // errAEEventNotPermitted = -1743, errAEEventWouldRequireUserConsent = -1744
        switch Int(err) {
        case 0:
            return .granted
        case -1743:
            return .denied
        case -1744:
            return .notDetermined
        default:
            // App not running / not installed often returns a generic error —
            // keep last known rather than forcing denied if we never asked.
            return .unknown
        }
    }

    // MARK: - Persistence

    private func update(_ permission: DynamoPermission, to status: PermissionMemoryStatus) {
        // Don't clobber a remembered .granted with .unknown (e.g. Spotify not installed).
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
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        for (key, raw) in snap.values {
            guard let perm = DynamoPermission(rawValue: key),
                  let status = PermissionMemoryStatus(rawValue: raw)
            else { continue }
            statuses[perm] = status
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
