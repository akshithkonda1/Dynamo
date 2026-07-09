import Foundation

/// Shared JSON persistence for list-shaped widget data (clipboard history,
/// pinned snippets, checklist items, stock watchlists). UserDefaults is
/// reserved for small settings — growing lists live here under Application Support.
enum AppSupportStore {
    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Dynamo", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func fileURL(named name: String) -> URL {
        rootDirectory.appendingPathComponent(name)
    }

    static func load<T: Decodable>(_ type: T.Type, from fileName: String) -> T? {
        let url = fileURL(named: fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to fileName: String) {
        let url = fileURL(named: fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
