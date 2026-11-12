import Foundation

/// The USB link to an Android tablet: `adb reverse` makes the tablet's 127.0.0.1:8770 reach the
/// Mac's, and Chrome is opened on the page once, when the tablet is plugged in and no page shows up.
///
/// Needs `adb` (Android platform tools) and USB debugging on the tablet. Nothing else is opened:
/// no network port, no DevTools forwarding.
final class TabletLink {

    enum Status: Equatable {
        case noADB
        case noDevice
        case linked(String)
    }

    private(set) var status: Status = .noDevice
    var onChange: (() -> Void)?
    /// Is a page connected right now (the web server knows).
    var hasViewer: () -> Bool = { false }

    let port: UInt16
    private let token: String
    private var timer: Timer?
    private var linkedSerial: String?
    private var silentSince: Date?
    private var recoveryStep = 0
    private let adbPath: String?

    nonisolated static let adbCandidates = [
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb",
        NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
    ]

    init(port: UInt16, token: String) {
        self.port = port
        self.token = token
        adbPath = Self.adbCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The page with its key; the page keeps the key and drops it from the address bar.
    var pageURL: String { "http://127.0.0.1:\(port)/?k=\(token)" }

    func start() {
        guard adbPath != nil else { set(.noADB); return }
        schedule(after: 0)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Menu: "Open on tablet".
    func openPageNow() {
        guard let serial = linkedSerial, let adbPath else { return }
        let args = Self.openArguments(serial: serial, url: pageURL)
        Task.detached { Self.run(adbPath, args) }
    }

    private func set(_ value: Status) {
        guard value != status else { return }
        status = value
        onChange?()
    }

    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(delay, 0.1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.check() } }
        }
        timer?.tolerance = 1
    }

    private func check() async {
        guard let adbPath else { return }
        let serial = await Task.detached { Self.firstDevice(Self.run(adbPath, ["devices"])) }.value
        if let serial {
            if serial != linkedSerial {
                linkedSerial = serial
                silentSince = nil
                recoveryStep = 0
                set(.linked(serial))
                await connect(serial: serial, adbPath: adbPath)
            } else {
                await keepTunnel(serial: serial, adbPath: adbPath)
            }
        } else {
            linkedSerial = nil
            silentSince = nil
            recoveryStep = 0
            set(.noDevice)
        }
        schedule(after: linkedSerial != nil ? 10 : 4)
    }

    private func connect(serial: String, adbPath: String) async {
        let reverse = reverseArguments(serial: serial)
        _ = await Task.detached { Self.run(adbPath, reverse) }.value
        // Chrome may still have the page open from last time: give it a moment to reconnect.
        try? await Task.sleep(for: .seconds(8))
        guard !hasViewer(), linkedSerial == serial else { return }
        openPageNow()
    }

    /// The tunnel can vanish (adb restarted, cable wobble): it is re-created when it's missing,
    /// and once more after 25 s of a silent page. Only SecondPad's own tunnel is touched: the adb
    /// server is never restarted (that would cut other apps' tunnels), and the page is not pushed
    /// back to the front: if you switched the tablet to something else, it stays there
    /// ("Open on Tablet" in the menu brings it back).
    private func keepTunnel(serial: String, adbPath: String) async {
        let port = self.port
        let reverse = reverseArguments(serial: serial)
        let listed = await Task.detached {
            Self.run(adbPath, ["-s", serial, "reverse", "--list"])?.contains("tcp:\(port)") ?? false
        }.value
        if !listed {
            _ = await Task.detached { Self.run(adbPath, reverse) }.value
            return
        }
        if hasViewer() {
            silentSince = nil
            recoveryStep = 0
            return
        }
        let since = silentSince ?? Date()
        silentSince = since
        if Date().timeIntervalSince(since) > 25, recoveryStep == 0 {
            recoveryStep = 1
            await Task.detached {
                Self.run(adbPath, ["-s", serial, "reverse", "--remove", "tcp:\(port)"])
                Self.run(adbPath, reverse)
            }.value
        }
    }

    private func reverseArguments(serial: String) -> [String] {
        ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"]
    }

    // MARK: - Pure helpers (unit-tested)

    /// The first device in `adb devices` that is ready (not "unauthorized" / "offline").
    nonisolated static func firstDevice(_ output: String?) -> String? {
        guard let output else { return nil }
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t")
            guard parts.count == 2, parts[1].trimmingCharacters(in: .whitespaces) == "device" else { continue }
            return String(parts[0])
        }
        return nil
    }

    /// Opens the page in Chrome. The application id makes Chrome reuse the tab it opened for us
    /// last time instead of piling up new tabs.
    /// The address is quoted: `adb shell` hands the line to the tablet's shell, where `?` and `&`
    /// mean something.
    nonisolated static func openArguments(serial: String, url: String) -> [String] {
        ["-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", "'\(url)'",
         "--es", "com.android.browser.application_id", "secondpad", "com.android.chrome"]
    }

    @discardableResult
    nonisolated static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
