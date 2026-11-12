import CryptoKit
import Foundation

/// The page's files, read once from the app bundle. Only names on this list are ever served:
/// nothing in a URL turns into a path on disk.
enum StaticFiles {

    nonisolated static let files: [String: (name: String, type: String)] = [
        "/": ("index.html", "text/html; charset=utf-8"),
        "/index.html": ("index.html", "text/html; charset=utf-8"),
        "/styles.css": ("styles.css", "text/css; charset=utf-8"),
        "/logic.js": ("logic.js", "text/javascript; charset=utf-8"),
        "/app.js": ("app.js", "text/javascript; charset=utf-8"),
        "/focus.js": ("focus.js", "text/javascript; charset=utf-8"),
        "/sheets.js": ("sheets.js", "text/javascript; charset=utf-8"),
        "/standby.js": ("standby.js", "text/javascript; charset=utf-8"),
        "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json"),
    ]

    /// `Contents/Resources/Web` in the app. `SECONDPAD_WEB` points elsewhere while developing.
    static var directory: URL? {
        if let override = ProcessInfo.processInfo.environment["SECONDPAD_WEB"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true)
    }

    private static var cache: [String: Data] = [:]

    /// A fingerprint of the page's files. The page reloads itself when it changes, so a tablet
    /// that kept the page open across an app update never runs old code against a new app.
    static var build: String {
        guard let directory else { return "none" }
        var hasher = SHA256()
        for name in Set(files.values.map(\.name)).sorted() {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)) { hasher.update(data: data) }
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func response(for path: String) -> HTTPResponse? {
        guard let entry = files[path], let directory else { return nil }
        // Development override: always fresh. Bundle: read once.
        let fresh = ProcessInfo.processInfo.environment["SECONDPAD_WEB"] != nil
        if fresh || cache[entry.name] == nil {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(entry.name)) else { return nil }
            cache[entry.name] = data
        }
        guard let body = cache[entry.name] else { return nil }
        return HTTPResponse(contentType: entry.type, body: body)
    }
}
