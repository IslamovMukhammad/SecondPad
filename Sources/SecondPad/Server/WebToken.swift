import Foundation
import Security

/// The tablet page's key. The web server listens on 127.0.0.1 only, but any program on this Mac
/// (even another macOS user's) could still talk to it; the key keeps them out of the feed and the
/// commands.
///
/// 32 random bytes, made once per install and kept in `web-token` (0600) in SecondPad's folder, so
/// the tablet keeps working after a Mac restart or a SecondPad relaunch. SecondPad opens the page
/// with `?k=<key>`; the page keeps it (localStorage) and sends it on the WebSocket and on every
/// data route.
nonisolated enum WebToken {

    static let byteCount = 32

    @MainActor static var defaultFileURL: URL { AppSupport.directory.appendingPathComponent("web-token") }

    /// The saved key, or a new one (saved 0600). Nil only when the system can't make random bytes.
    static func load(from url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let saved = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isWellFormed(saved) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return saved
            }
        }
        guard let fresh = make() else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Created 0600 from the start (no window where the file is readable by others).
        let created = FileManager.default.createFile(atPath: url.path, contents: Data(fresh.utf8),
                                                     attributes: [.posixPermissions: 0o600])
        if !created { try? Data(fresh.utf8).write(to: url, options: .atomic) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return fresh
    }

    /// A new key: 32 random bytes as 64 lowercase hex characters (safe in a URL and a shell).
    static func make() -> String? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isWellFormed(_ text: String) -> Bool {
        text.utf8.count == byteCount * 2 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Compares in constant time (the time doesn't tell how many characters were right).
    static func matches(_ given: String?, _ expected: String) -> Bool {
        guard let given else { return false }
        let a = Array(given.utf8), b = Array(expected.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<b.count { difference |= b[i] ^ (i < a.count ? a[i] : 0) }
        return difference == 0 && !b.isEmpty
    }
}
