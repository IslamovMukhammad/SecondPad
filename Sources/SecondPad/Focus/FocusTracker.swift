import AppKit
import ApplicationServices

/// Time per app inside one focus period. Pure, unit-tested.
nonisolated struct FocusLedger: Sendable {
    struct Segment: Sendable, Equatable {
        let app: String
        let category: ActivityCategory
        let start: Date
        let end: Date
    }

    struct Usage: Codable, Equatable, Sendable {
        let app: String
        let category: ActivityCategory
        let seconds: Int
    }

    private(set) var segments: [Segment] = []
    private var open: (app: String, category: ActivityCategory, start: Date)?

    mutating func begin(app: String, category: ActivityCategory, at date: Date) {
        close(at: date)
        open = (app, category, date)
    }

    mutating func close(at date: Date) {
        guard let current = open else { return }
        if date.timeIntervalSince(current.start) >= 1 {
            segments.append(Segment(app: current.app, category: current.category, start: current.start, end: date))
        }
        open = nil
    }

    mutating func reset() {
        segments.removeAll()
        open = nil
    }

    /// Seconds per app between `start` and `end` (the open segment counts up to `end`).
    func usage(from start: Date, to end: Date) -> [Usage] {
        var all = segments
        if let current = open, end > current.start {
            all.append(Segment(app: current.app, category: current.category, start: current.start, end: end))
        }
        var totals: [String: (ActivityCategory, Double)] = [:]
        for segment in all {
            let overlap = min(segment.end, end).timeIntervalSince(max(segment.start, start))
            guard overlap > 0 else { continue }
            let key = segment.app + "\u{1F}" + segment.category.rawValue
            totals[key] = (segment.category, (totals[key]?.1 ?? 0) + overlap)
        }
        return totals.map { key, value in
            Usage(app: String(key.split(separator: "\u{1F}").first ?? ""), category: value.0, seconds: Int(value.1.rounded()))
        }.sorted { $0.seconds > $1.seconds }
    }

    /// Share of time on task, 0…100 (100 when nothing was recorded), and the on-task seconds.
    static func purity(of usage: [Usage]) -> (percent: Int, onTask: Int) {
        let total = usage.reduce(0) { $0 + $1.seconds }
        let onTask = usage.filter { ActivityCategory.onTask.contains($0.category) }.reduce(0) { $0 + $1.seconds }
        let percent = total > 0 ? Int((Double(onTask) / Double(total) * 100).rounded()) : 100
        return (percent, onTask)
    }
}

/// Watches the frontmost app, ONLY while a Pomodoro focus period runs (`active`). Outside focus
/// nothing is looked at or recorded. Chrome's active tab is read as a domain (never the full URL,
/// never in incognito) to tell YouTube from GitHub.
final class FocusTracker {

    private(set) var ledger = FocusLedger()
    /// A real app/category change: the Pomodoro counts visits and focus breaks.
    var onSwitch: ((_ app: String, _ id: String?, _ category: ActivityCategory) -> Void)?
    /// Is any Claude session working right now (keeps a quiet minute from counting as away)?
    var claudeWorking: () -> Bool = { false }

    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var currentApp: String?
    private var currentCategory: ActivityCategory = .other
    private var polling = false
    private var lastDomainCheck = Date.distantPast
    private var lastDomain: String?
    private var lastMediaCheck = Date.distantPast
    private var lastMediaActive = false
    private(set) var active = false

    /// Noise that flashes to the front for a moment (banners, Spotlight…).
    private static let systemNoise: Set<String> = [
        "com.apple.UserNotificationCenter", "com.apple.Spotlight", "com.apple.loginwindow",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver",
    ]

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            currentApp = nil
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer?.tolerance = 1
            tick()
        } else {
            ledger.close(at: Date())
            timer?.invalidate(); timer = nil
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observer = nil
            currentApp = nil
        }
    }

    /// A new focus period.
    func resetLedger() {
        ledger.reset()
        currentApp = nil
    }

    func usage(from start: Date, to end: Date) -> [FocusLedger.Usage] { ledger.usage(from: start, to: end) }

    private func tick() {
        guard active, !polling else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let bundleID = front?.bundleIdentifier
        guard !Self.systemNoise.contains(bundleID ?? ""), bundleID != Bundle.main.bundleIdentifier else { return }
        polling = true
        let appName = front?.localizedName ?? "Unknown"
        let pid = front?.processIdentifier ?? -1
        let idle = Self.secondsSinceInput()
        let locked = Self.screenLocked()
        let isBrowser = CategoryRules.browserBundleIDs.contains(bundleID ?? "")
        let now = Date()
        let needsDomain = isBrowser && now.timeIntervalSince(lastDomainCheck) > 8
        let needsMedia = !locked && idle >= 90 && now.timeIntervalSince(lastMediaCheck) > 8
        let claude = claudeWorking()
        Task.detached(priority: .utility) {
            let domain: String?? = needsDomain ? .some(ChromeTab.activeDomain(pid: pid)) : .none
            let media: Bool? = needsMedia ? Self.hasMediaAssertion(pid: pid) : nil
            await MainActor.run {
                self.apply(appName: appName, bundleID: bundleID, isBrowser: isBrowser, idle: idle, locked: locked,
                           claudeWorking: claude, freshDomain: domain, freshMedia: media)
            }
        }
    }

    private func apply(appName: String, bundleID: String?, isBrowser: Bool, idle: TimeInterval, locked: Bool,
                       claudeWorking: Bool, freshDomain: String??, freshMedia: Bool?) {
        defer { polling = false }
        guard active else { return }
        if let freshDomain { lastDomain = freshDomain; lastDomainCheck = Date() }
        if let freshMedia { lastMediaActive = freshMedia; lastMediaCheck = Date() }
        if !isBrowser { lastDomain = nil }
        let domain = isBrowser ? lastDomain : nil
        let away = CategoryRules.isAway(
            locked: locked, idle: idle, mediaActive: idle >= 90 && lastMediaActive, claudeWorking: claudeWorking,
            readingContext: CategoryRules.isReadingContext(isBrowser: isBrowser, bundleID: bundleID, domain: domain))
        let category: ActivityCategory = away ? .afk
            : isBrowser ? CategoryRules.category(domain: domain) : CategoryRules.category(bundleID: bundleID)
        let platform = (isBrowser && !away) ? domain.flatMap(CategoryRules.platform(domain:)) : nil
        let app = away ? "Away" : (platform?.name ?? appName)
        guard app != currentApp || category != currentCategory else { return }
        let now = Date()
        ledger.begin(app: app, category: category, at: now)
        currentApp = app
        currentCategory = category
        onSwitch?(app, away ? nil : (platform?.id ?? bundleID), category)
    }

    // MARK: - System reads

    nonisolated private static func secondsSinceInput() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
    }

    nonisolated private static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Is the front app playing video/audio (it then holds a power assertion)?
    nonisolated private static func hasMediaAssertion(pid: pid_t) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let marker = "pid \(pid)("
        return output.split(separator: "\n").contains {
            $0.contains(marker) && ($0.contains("Video Wake Lock") || $0.contains("Playing audio"))
        }
    }
}

/// Chrome's active-tab domain. The window title (Accessibility, no process) is checked first;
/// AppleScript runs only when the title changed or 2 minutes passed.
nonisolated enum ChromeTab {
    nonisolated(unsafe) private static var cache: (title: String?, domain: String?, at: Date) = (nil, nil, .distantPast)

    static func activeDomain(pid: pid_t) -> String? {
        let title = windowTitle(pid: pid)
        if let title, title == cache.title, Date().timeIntervalSince(cache.at) < 120 { return cache.domain }
        let domain = probe()
        cache = (title, domain, Date())
        return domain
    }

    private static func windowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    static let script = """
    if application "Google Chrome" is running then
        tell application "Google Chrome"
            if (count of windows) is 0 then return ""
            set w to front window
            if (mode of w) is "incognito" then return "PRIVATE"
            return URL of active tab of w
        end tell
    end if
    return ""
    """

    private static func probe() -> String? {
        var error: NSDictionary?
        guard let text = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
              !text.isEmpty, text != "PRIVATE" else { return nil }
        return CategoryRules.domain(fromURL: text)
    }
}
