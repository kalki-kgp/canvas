import Foundation

/// Plain file storage under ~/Library/Application Support/Canvas/data.
/// The web app decides what lives where; this only guards the paths.
final class Store {
    let root: URL

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    enum StoreError: Error { case badPath }

    /// "a/b/c.json" → URL inside root, or nil when any component is unsafe
    func url(for path: String) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, parts.count <= 6 else { return nil }
        for part in parts {
            guard !part.hasPrefix("."), part.count <= 200,
                  part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })
            else { return nil }
        }
        return parts.reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    func read(_ path: String) -> Data? {
        guard let url = url(for: path) else { return nil }
        return try? Data(contentsOf: url)
    }

    func write(_ path: String, _ data: Data) throws {
        guard let url = url(for: path) else { throw StoreError.badPath }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// true when something was deleted
    func delete(_ path: String) throws -> Bool {
        guard let url = url(for: path) else { throw StoreError.badPath }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }

    /// files directly in a directory, newest first
    func list(_ path: String) -> [[String: Any]]? {
        guard let url = url(for: path) else { return nil }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.compactMap { item -> (String, Int, Double)? in
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return (item.lastPathComponent, values.fileSize ?? 0,
                    (values.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000)
        }
        .sorted { $0.2 > $1.2 }
        .map { ["name": $0.0, "size": $0.1, "mtime": $0.2] }
    }

    static func contentType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "txt": return "text/plain; charset=utf-8"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}
