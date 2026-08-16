import AppKit
import Contacts
import Foundation

/// Resolves a **message contact** thumbnail for Peek chrome.
///
/// Tuned for Messages / iMessage / SMS / messenger Peeks so the island
/// can tint to the contact photo. On-device Contacts only — no network,
/// no disk cache of photos.
@MainActor
enum ContactPhotoResolver {
    private static let store = CNContactStore()
    private static var didRequestAccess = false

    private static var keys: [CNKeyDescriptor] {
        [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor
        ]
    }

    // MARK: - Message peeks

    /// Best photo for a **message** Peek from notification title + body.
    /// Tries name, group first member, phone, email — in that order.
    static func imageDataForMessage(title: String, body: String = "") -> Data? {
        guard ensureAccess() else { return nil }

        // 1) Direct name from title (usual Messages layout: title = contact).
        for candidate in messageNameCandidates(title: title, body: body) {
            if let data = imageData(matchingName: candidate) {
                return data
            }
        }

        // 2) Phone number in title or body
        for phone in phoneCandidates(title: title, body: body) {
            if let data = imageData(matchingPhone: phone) {
                return data
            }
        }

        // 3) Email-like token
        for email in emailCandidates(title: title, body: body) {
            if let data = imageData(matchingEmail: email) {
                return data
            }
        }

        return nil
    }

    /// Best-effort thumbnail for a free-form display name.
    static func imageData(matchingName rawName: String) -> Data? {
        let name = sanitizeMessageName(rawName)
        guard name.count >= 2 else { return nil }
        guard ensureAccess() else { return nil }

        if let data = lookupByPredicate(name: name) {
            return data
        }
        // Group-style "Alex, Sam" → first segment with a photo.
        if name.contains(",") {
            for part in name.split(separator: ",").map({ sanitizeMessageName(String($0)) }) where part.count >= 2 {
                if let data = lookupByPredicate(name: part) { return data }
            }
        }
        // "Alex and Sam" / "Alex & Sam"
        for separator in [" and ", " & "] {
            if let range = name.range(of: separator, options: .caseInsensitive) {
                let first = sanitizeMessageName(String(name[..<range.lowerBound]))
                if first.count >= 2, let data = lookupByPredicate(name: first) {
                    return data
                }
            }
        }
        return lookupByScan(name: name)
    }

    static func imageData(matchingPhone raw: String) -> Data? {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        guard ensureAccess() else { return nil }

        let phone = CNPhoneNumber(stringValue: raw)
        let predicate = CNContact.predicateForContacts(matching: phone)
        if let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keys),
           let data = firstImage(in: contacts) {
            return data
        }
        // Fallback: scan last-7 digits
        let tail = String(digits.suffix(7))
        return scanPhones(matchingTail: tail)
    }

    static func imageData(matchingEmail raw: String) -> Data? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), email.count >= 5 else { return nil }
        guard ensureAccess() else { return nil }
        // CNContact has no email predicate that works well cross-version — scan lightly.
        return scanEmails(matching: email)
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
            store.requestAccess(for: .contacts) { _, _ in }
            return false
        case .denied, .restricted:
            return false
        @unknown default:
            return true
        }
    }

    /// Prompt once early so the first message Peek can resolve a photo.
    static func requestAccessOnLaunchIfNeeded() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .notDetermined else { return }
        didRequestAccess = true
        store.requestAccess(for: .contacts) { _, _ in }
    }

    // MARK: - Message name parsing

    private static func messageNameCandidates(title: String, body: String) -> [String] {
        var out: [String] = []
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)

        if !t.isEmpty {
            out.append(t)
            // "Alex: hey" style
            if let colon = t.range(of: ":") {
                let before = String(t[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
                if before.count >= 2, before.count < 40 { out.append(before) }
            }
        }
        // Some layouts put the contact in the body first line.
        if !b.isEmpty {
            let firstLine = b.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? b
            if firstLine.count >= 2, firstLine.count <= 48, !firstLine.contains("://") {
                // Avoid using full message text as a name.
                let words = firstLine.split(separator: " ")
                if words.count <= 5 {
                    out.append(firstLine)
                }
            }
        }
        // Dedup preserving order
        var seen = Set<String>()
        return out.compactMap { raw in
            let s = sanitizeMessageName(raw)
            guard s.count >= 2, !seen.contains(s.lowercased()) else { return nil }
            seen.insert(s.lowercased())
            return s
        }
    }

    private static func phoneCandidates(title: String, body: String) -> [String] {
        let blob = "\(title) \(body)"
        // Loose match: +1 (555) 123-4567 / 555-123-4567 / 10+ digits
        let pattern = #"(\+?\d[\d\s().-]{6,}\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(blob.startIndex..<blob.endIndex, in: blob)
        let matches = regex.matches(in: blob, range: range)
        return matches.compactMap { m in
            guard let r = Range(m.range, in: blob) else { return nil }
            let s = String(blob[r])
            let digits = s.filter(\.isNumber)
            return digits.count >= 7 ? s : nil
        }
    }

    private static func emailCandidates(title: String, body: String) -> [String] {
        let blob = "\(title) \(body)"
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        let range = NSRange(blob.startIndex..<blob.endIndex, in: blob)
        return regex.matches(in: blob, range: range).compactMap { m in
            guard let r = Range(m.range, in: blob) else { return nil }
            return String(blob[r])
        }
    }

    private static func sanitizeMessageName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "Message from ", "Messages from ", "New message from ",
            "iMessage from ", "SMS from ", "Text from ",
            "Facetime ", "FaceTime ", "Call from ", "Missed call from "
        ]
        for prefix in prefixes {
            if s.lowercased().hasPrefix(prefix.lowercased()) {
                s = String(s.dropFirst(prefix.count))
            }
        }
        for suffix in [" is calling", " called you", " sent you a message"] {
            if let range = s.range(of: suffix, options: .caseInsensitive) {
                s = String(s[..<range.lowerBound])
            }
        }
        // Drop trailing group counts: "Alex and 2 others"
        if let range = s.range(of: #" and \d+ others?"#, options: [.regularExpression, .caseInsensitive]) {
            s = String(s[..<range.lowerBound])
        }
        // Strip emoji noise at edges lightly
        while s.last?.isWhitespace == true || s.last?.isPunctuation == true {
            s = String(s.dropLast())
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Lookup

    private static func lookupByPredicate(name: String) -> Data? {
        let predicate = CNContact.predicateForContacts(matchingName: name)
        guard let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keys) else {
            return nil
        }
        return bestImage(in: contacts, preferredName: name)
    }

    private static func lookupByScan(name: String) -> Data? {
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var matches: [CNContact] = []
        let needle = name.lowercased()
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                let full = displayName(contact).lowercased()
                guard !full.isEmpty else { return }
                if full == needle
                    || full.hasPrefix(needle)
                    || needle.hasPrefix(full)
                    || full.contains(needle)
                    || tokensMatch(full, needle) {
                    if imageBytes(for: contact) != nil {
                        matches.append(contact)
                        if matches.count >= 6 { stop.pointee = true }
                    }
                }
            }
        } catch {
            return nil
        }
        return bestImage(in: matches, preferredName: name)
    }

    private static func scanPhones(matchingTail tail: String) -> Data? {
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var hit: Data?
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                for labeled in contact.phoneNumbers {
                    let digits = labeled.value.stringValue.filter(\.isNumber)
                    if digits.hasSuffix(tail), let data = imageBytes(for: contact) {
                        hit = data
                        stop.pointee = true
                        return
                    }
                }
            }
        } catch {
            return nil
        }
        return hit
    }

    private static func scanEmails(matching email: String) -> Data? {
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var hit: Data?
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                for labeled in contact.emailAddresses {
                    if (labeled.value as String).lowercased() == email,
                       let data = imageBytes(for: contact) {
                        hit = data
                        stop.pointee = true
                        return
                    }
                }
            }
        } catch {
            return nil
        }
        return hit
    }

    private static func bestImage(in contacts: [CNContact], preferredName: String) -> Data? {
        let ranked = contacts.sorted {
            score($0, preferred: preferredName) > score($1, preferred: preferredName)
        }
        return firstImage(in: ranked)
    }

    private static func firstImage(in contacts: [CNContact]) -> Data? {
        for c in contacts {
            if let data = imageBytes(for: c) { return data }
        }
        return nil
    }

    /// Prefer full image when present (richer palette); else thumbnail.
    private static func imageBytes(for contact: CNContact) -> Data? {
        if contact.imageDataAvailable {
            if let full = contact.imageData, !full.isEmpty { return full }
            if let thumb = contact.thumbnailImageData, !thumb.isEmpty { return thumb }
        }
        return nil
    }

    private static func score(_ contact: CNContact, preferred: String) -> Int {
        let full = displayName(contact).lowercased()
        let p = preferred.lowercased()
        var s = 0
        if full == p { s += 100 }
        else if full.hasPrefix(p) || p.hasPrefix(full) { s += 80 }
        else if full.contains(p) || p.contains(full) { s += 60 }
        else if tokensMatch(full, p) { s += 40 }
        if contact.imageDataAvailable { s += 10 }
        return s
    }

    private static func displayName(_ c: CNContact) -> String {
        let parts = [c.givenName, c.familyName].filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        if !c.nickname.isEmpty { return c.nickname }
        if !c.organizationName.isEmpty { return c.organizationName }
        return CNContactFormatter.string(from: c, style: .fullName) ?? ""
    }

    private static func tokensMatch(_ a: String, _ b: String) -> Bool {
        let ta = Set(a.split(separator: " ").map { String($0).lowercased() }.filter { $0.count > 1 })
        let tb = Set(b.split(separator: " ").map { String($0).lowercased() }.filter { $0.count > 1 })
        return !ta.isEmpty && !tb.isEmpty && !ta.isDisjoint(with: tb)
    }
}
