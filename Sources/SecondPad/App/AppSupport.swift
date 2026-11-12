import Foundation

/// `~/Library/Application Support/SecondPad/` (0700): the hook socket and token, the hook
/// scripts, the plan limits, the Pomodoro log and the task list live here, readable by you only.
enum AppSupport {
    static let name = "SecondPad"

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }()

    /// Small JSON files (plan limits, Pomodoro log, tasks). Written atomically, off the main thread.
    nonisolated static func write(_ data: Data, to url: URL) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
