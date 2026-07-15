import AppKit
import ApplicationServices
import AVFoundation
import CoreLocation
import Foundation

/// High-level permission Dynamo cares about. OS TCC still owns the real grant;
/// this store **remembers** last-known status so UI doesn't reset every launch,
/// and re-probes the system when the app becomes active.
enum DynamoPermission: String, CaseIterable, Codable {
    case camera
    case location
    case fullDiskAccess
    case automationMusic
    case automationSpotify
    case automationMessages

    var displayName: String {
        switch self {
        case .camera: return "Camera"
        case .location: return "Location"
        case .fullDiskAccess: return "Full Disk Access"
        case .automationMusic: return "Control Music"
        case .automationSpotify: return "Control Spotify"
        case .automationMessages: return "Control Messages"
        }
    }

    var detail: String {
        switch self {
        case .camera: return "Webcam mirror"
        case .location: return "Weather (automatic)"
        case .fullDiskAccess: return "Calendar + Messages local databases"
        case .automationMusic: return "Play/pause, skip, cover art, playlists"
        case .automationSpotify: return "Play/pause, skip, cover art"
        case .automationMessages: return "Send replies from the notch"
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
        update(.automationMusic, to: Self.probeAutomation(bundleID: "com.apple.Music"))
        update(.automationSpotify, to: Self.probeAutomation(bundleID: "com.spotify.client"))
        update(.automationMessages, to: Self.probeAutomation(bundleID: "com.apple.MobileSMS"))
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
        case .automationMusic, .automationSpotify, .automationMessages:
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
        let messagesDB = home
            .appendingPathComponent("Library/Messages/chat.db")

        let calOK = isEffectivelyReadable(calendarDB)
        let msgOK = isEffectivelyReadable(messagesDB)

        // If either protected path is readable, FDA (or equivalent) is working
        // for Dynamo. If neither file exists, treat as unknown.
        let calExists = FileManager.default.fileExists(atPath: calendarDB.path)
        let msgExists = FileManager.default.fileExists(atPath: messagesDB.path)

        if calOK || msgOK { return .granted }
        if calExists || msgExists { return .denied }
        return .unknown
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
        if statuses[permission] != status {
            statuses[permission] = status
            objectWillChange.send()
        } else if statuses[permission] == nil {
            statuses[permission] = status
        }
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
