import AppKit
import Contacts
import Foundation

/// Resolves a contact thumbnail for Peek chrome (Messages / FaceTime / etc.).
///
/// - Uses the **Contacts** framework only — no network.
/// - Image bytes are used ephemerally for the Peek; nothing is written to disk.
/// - Soft-fails when Contacts is denied or the name doesn’t match.
@MainActor
enum ContactPhotoResolver {
    private static let store = CNContactStore()
    private static var didRequestAccess = false

    /// Best-effort thumbnail PNG/JPEG for a display name (notification title).
    static func imageData(matchingName rawName: String) -> Data? {
        let name = sanitize(rawName)
        guard name.count >= 2 else { return nil }
        guard ensureAccess() else { return nil }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor
        ]

        // Prefer predicate name match, then lightweight scan of image-bearing contacts.
        if let data = lookupByPredicate(name: name, keys: keys) {
            return data
        }
        return lookupByScan(name: name, keys: keys)
    }

    // MARK: - Access

    @discardableResult
    static func ensureAccess() -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            guard !didRequestAccess else { return false }
            didRequestAccess = true
            // Fire async; next text/call after grant will resolve a photo.
            store.requestAccess(for: .contacts) { _, _ in }
            return false
        case .denied, .restricted:
            return false
        @unknown default:
            // Includes newer states such as limited Contacts access.
            return true
        }
    }

    /// Prompt once early so the first text/call can resolve a photo.
    static func requestAccessOnLaunchIfNeeded() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .notDetermined else { return }
        didRequestAccess = true
        store.requestAccess(for: .contacts) { _, _ in }
    }

    // MARK: - Lookup

    private static func lookupByPredicate(name: String, keys: [CNKeyDescriptor]) -> Data? {
        let predicate = CNContact.predicateForContacts(matchingName: name)
        guard let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keys) else {
            return nil
        }
        return bestImage(in: contacts, preferredName: name)
    }

    private static func lookupByScan(name: String, keys: [CNKeyDescriptor]) -> Data? {
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var matches: [CNContact] = []
        let needle = name.lowercased()
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                let full = displayName(contact).lowercased()
                guard !full.isEmpty else { return }
                if full == needle
                    || full.contains(needle)
                    || needle.contains(full)
                    || tokensMatch(full, needle) {
                    if contact.imageDataAvailable, contact.thumbnailImageData != nil {
                        matches.append(contact)
                        if matches.count >= 4 { stop.pointee = true }
                    }
                }
            }
        } catch {
            return nil
        }
        return bestImage(in: matches, preferredName: name)
    }

    private static func bestImage(in contacts: [CNContact], preferredName: String) -> Data? {
        let ranked = contacts.sorted { a, b in
            score(a, preferred: preferredName) > score(b, preferred: preferredName)
        }
        for c in ranked {
            if let data = c.thumbnailImageData, !data.isEmpty { return data }
        }
        return nil
    }

    private static func score(_ contact: CNContact, preferred: String) -> Int {
        let full = displayName(contact).lowercased()
        let p = preferred.lowercased()
        if full == p { return 100 }
        if full.hasPrefix(p) || p.hasPrefix(full) { return 80 }
        if full.contains(p) || p.contains(full) { return 60 }
        if tokensMatch(full, p) { return 40 }
        return 0
    }

    private static func displayName(_ c: CNContact) -> String {
        let parts = [c.givenName, c.familyName].filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        if !c.nickname.isEmpty { return c.nickname }
        if !c.organizationName.isEmpty { return c.organizationName }
        return CNContactFormatter.string(from: c, style: .fullName) ?? ""
    }

    private static func tokensMatch(_ a: String, _ b: String) -> Bool {
        let ta = Set(a.split(separator: " ").map { String($0) }.filter { $0.count > 1 })
        let tb = Set(b.split(separator: " ").map { String($0) }.filter { $0.count > 1 })
        return !ta.isEmpty && !tb.isEmpty && !ta.isDisjoint(with: tb)
    }

    private static func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip common notification prefixes / suffixes.
        for prefix in ["Message from ", "Facetime ", "FaceTime ", "Call from ", "Missed call from "] {
            if s.lowercased().hasPrefix(prefix.lowercased()) {
                s = String(s.dropFirst(prefix.count))
            }
        }
        // Drop trailing " is calling" style.
        if let range = s.range(of: " is calling", options: .caseInsensitive) {
            s = String(s[..<range.lowerBound])
        }
        if let range = s.range(of: " called you", options: .caseInsensitive) {
            s = String(s[..<range.lowerBound])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
