import AppKit
import Combine

/// The wiring: every source → JSON messages for the tablet, the tablet's taps → the sources.
final class AppModel: ObservableObject {

    // What the menu and Settings show.
    @Published private(set) var sessions: [ClaudeSessionInfo] = []
    @Published private(set) var limits: PlanLimits?
    @Published private(set) var hooks = ClaudeHooks.InstallState()
    @Published private(set) var hookError: String?
    @Published private(set) var linkStatus: TabletLink.Status = .noDevice
    @Published private(set) var viewers = 0
    @Published private(set) var revision = 0
    @Published var breathingPattern: String {
        didSet { defaults.set(breathingPattern, forKey: Self.breathingKey); broadcastSettings() }
    }
    /// The tablet shows a big clock while the Mac sleeps, locks or runs its screen saver.
    @Published var standbyOnSleep: Bool {
        didSet { defaults.set(standbyOnSleep, forKey: Self.standbyKey); broadcastStandby() }
    }
    /// The StandBy clock in this Mac's own SF Pro Rounded (sent to the tablet over the cable, never
    /// stored in the app). Off by default: Apple licenses its fonts for Apple platforms.
    @Published var standbyMacFont: Bool {
        didSet { defaults.set(standbyMacFont, forKey: Self.macFontKey); broadcastSettings() }
    }

    let isDemo: Bool
    let web: WebServer
    let liveUsage: LiveUsage
    let spotify = SpotifyService()
    let quickTimer: QuickTimer
    let pomodoro: PomodoroTimer
    let tasks: TaskStore
    let weather: WeatherService
    let link: TabletLink
    var serverError: String? { web.lastError }

    nonisolated static let breathingKey = "breathing.pattern"
    nonisolated static let standbyKey = "standby.onSleep"
    nonisolated static let macFontKey = "standby.macFont"
    /// The Mac's rounded system font, read when the tablet asks (only with the setting on).
    nonisolated static let roundedFontPath = "/System/Library/Fonts/SFNSRounded.ttf"
    nonisolated static let breathingPatterns = ["box", "478", "sigh"]

    private let defaults: UserDefaults
    private let events = EventServer()
    private let status = ClaudeStatus()
    private let planLimits: ClaudeLimits
    private let tracker = FocusTracker()
    private let monitor = SystemMonitor()
    private let network = NetworkStatus()
    private let standby = StandbyWatch()
    /// `--demo standby`: the clock shows (for the screenshot).
    private var demoStandby = false
    private let readQueue = DispatchQueue(label: "SecondPad.transcripts", qos: .utility)
    private var timers: [Timer] = []
    private var lastStats: SystemStats?
    private var demoStats: SystemStats?

    init(demo: Bool = false, defaults: UserDefaults = .standard) {
        isDemo = demo
        // Demo mode never reads or writes the real settings, hooks or Keychain.
        let defaults = demo ? Self.scratchDefaults() : defaults
        self.defaults = defaults
        breathingPattern = defaults.string(forKey: Self.breathingKey).flatMap { Self.breathingPatterns.contains($0) ? $0 : nil } ?? "box"
        standbyOnSleep = defaults.object(forKey: Self.standbyKey) as? Bool ?? true
        standbyMacFont = defaults.bool(forKey: Self.macFontKey)
        // SECONDPAD_PORT (dev): run a demo next to the real app, e.g. for screenshots.
        let port = ProcessInfo.processInfo.environment["SECONDPAD_PORT"].flatMap(UInt16.init) ?? WebServer.defaultPort
        web = WebServer(port: port, token: Self.pageToken(demo: demo))
        liveUsage = demo
            ? LiveUsage(defaults: defaults, credentials: Demo.NoLogin(), fetch: { _ in throw URLError(.notConnectedToInternet) })
            : LiveUsage(defaults: defaults)
        planLimits = ClaudeLimits(fileURL: demo ? nil : ClaudeLimits.defaultFileURL)
        quickTimer = QuickTimer(defaults: defaults)
        pomodoro = PomodoroTimer(history: PomodoroHistory(fileURL: demo ? nil : PomodoroHistory.defaultFileURL),
                                 defaults: defaults,
                                 clock: demo ? { Date().addingTimeInterval(Demo.shift) } : Date.init)
        tasks = TaskStore(fileURL: demo ? nil : TaskStore.defaultFileURL)
        weather = WeatherService(defaults: defaults)
        link = TabletLink(port: web.port, token: web.token)
    }

    /// The tablet page's key: saved once per install. A demo makes its own for each launch
    /// (SECONDPAD_TOKEN sets it, so the screenshot scripts can open the demo page).
    private static func pageToken(demo: Bool) -> String {
        if demo {
            if let given = ProcessInfo.processInfo.environment["SECONDPAD_TOKEN"], WebToken.isWellFormed(given) { return given }
            return WebToken.make() ?? fallbackToken()
        }
        return WebToken.load(from: WebToken.defaultFileURL) ?? fallbackToken()
    }

    /// Only if the system can't make random bytes (it always can): a per-launch key from two UUIDs.
    private static func fallbackToken() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Demo mode never touches the real settings: they live in memory only.
    private static func scratchDefaults() -> UserDefaults { MemoryDefaults.make() }

    // MARK: - Start / stop

    func start() {
        web.route = { [weak self] request in await self?.route(request) }
        web.onViewer = { [weak self] client in self?.sendSnapshot(to: client) }
        web.onMessage = { [weak self] text in self?.command(text) }
        web.start()

        quickTimer.onChange = { [weak self] in self?.broadcastQuickTimer() }
        quickTimer.onFinish = { [weak self] in
            guard let self else { return }
            self.web.broadcast(Self.json(["type": "quicktimer.done", "sound": self.quickTimer.soundOnTablet]))
        }
        pomodoro.onChange = { [weak self] in self?.broadcastPomodoro() }
        pomodoro.onPrompt = { [weak self] prompt in self?.promptChanged(prompt) }
        tasks.onChange = { [weak self] in self?.broadcastTasks() }
        weather.onChange = { [weak self] in self?.broadcastWeather() }
        spotify.onChange = { [weak self] _ in self?.broadcastMedia() }
        link.onChange = { [weak self] in self?.linkStatus = self?.link.status ?? .noDevice }
        link.hasViewer = { [weak self] in (self?.web.viewerCount ?? 0) > 0 }

        if isDemo {
            spotify.isDemo = true
            if ProcessInfo.processInfo.arguments.contains("worst") { Demo.fillWorst(self) } else { Demo.fill(self) }
            demoStandby = ProcessInfo.processInfo.arguments.contains("standby")
            // SECONDPAD_MAC_FONT=1: the demo uses the Mac's SF Rounded (for the side-by-side picture).
            if ProcessInfo.processInfo.environment["SECONDPAD_MAC_FONT"] == "1" { standbyMacFont = true }
        } else {
            limits = planLimits.latest
            refreshHookState()
            events.onRequest = { [weak self] path, object in self?.receive(path: path, object: object) }
            events.start()
            discoverSessions()
            standby.onChange = { [weak self] in self?.broadcastStandby() }
            standby.start()
            liveUsage.onLimits = { [weak self] object in
                guard let self, let next = self.planLimits.ingest(object, source: .live) else { return }
                self.limits = next
                self.broadcastLimits()
            }
            liveUsage.start()
            tracker.claudeWorking = { [weak self] in self?.sessions.contains { $0.state == .working } ?? false }
            tracker.onSwitch = { [weak self] app, id, category in self?.pomodoro.noteSwitch(app: app, bundleID: id, category: category) }
            pomodoro.usageProvider = { [weak self] start, end in self?.tracker.usage(from: start, to: end) ?? [] }
            pomodoro.onFocusBegin = { [weak self] in self?.tracker.resetLedger() }
            pomodoro.onFocusRunning = { [weak self] on in self?.tracker.setActive(on) }
            pomodoro.watchSleep()
            spotify.start()
            network.onChange = { [weak self] in self?.broadcastNetwork() }
            network.start()
            weather.start()
            link.start()
        }

        every(1) { $0.tickStats() }
        every(2) { $0.tickClaude() }
        every(60) { $0.tickDay() }
    }

    func stop() {
        timers.forEach { $0.invalidate() }
        web.stop()
        events.stop()
        link.stop()
    }

    private func every(_ seconds: TimeInterval, _ body: @escaping @MainActor @Sendable (AppModel) -> Void) {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { body(self) } }
        }
        timer.tolerance = seconds * 0.2
        timers.append(timer)
    }

    // MARK: - Claude

    func installHooks() {
        guard !isDemo else { hookError = "Demo mode: nothing is installed."; return }
        do { try ClaudeHooks.install(); hookError = nil } catch { hookError = error.localizedDescription }
        refreshHookState()
    }

    func removeHooks() {
        guard !isDemo else { hookError = "Demo mode: nothing is removed."; return }
        do { try ClaudeHooks.uninstall(); hookError = nil } catch { hookError = error.localizedDescription }
        refreshHookState()
    }

    func refreshHookState() {
        guard !isDemo else { return }
        let next = ClaudeHooks.state()
        guard next != hooks else { return }
        hooks = next
        broadcastClaude()
        broadcastLimits()
    }

    private func receive(path: String, object: [String: Any]) {
        switch path {
        case "/claude-event":
            guard let event = object["event"] as? String else { return }
            status.handle(event: event, payload: object["payload"] as? [String: Any] ?? [:])
            publishSessions()
            readTranscripts()
        case "/claude-limits":
            if let next = planLimits.ingest(object, source: .statusLine) {
                limits = next
                broadcastLimits()
            }
        default:
            break
        }
    }

    /// Sessions already running when SecondPad starts show up at once (from Claude Code's
    /// transcripts), instead of waiting for their next hook.
    private func discoverSessions() {
        readQueue.async { [weak self] in
            let found = TranscriptReader.recent()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    var added = false
                    for f in found where self.status.adopt(f) { added = true }
                    if added { self.publishSessions() }
                }
            }
        }
    }

    private func tickClaude() {
        guard !isDemo else { return }
        if status.refresh() { publishSessions() }
        readTranscripts()
    }

    private func publishSessions() {
        let next = status.sessionInfos
        guard next != sessions else { return }
        sessions = next
        broadcastClaude()
    }

    private func readTranscripts() {
        for read in status.transcriptReads() {
            readQueue.async { [weak self] in
                let result = TranscriptReader.read(read)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if self.status.apply(read, result: result) { self.publishSessions() }
                    }
                }
            }
        }
    }

    // MARK: - Periodic

    private func tickStats() {
        // Sampling costs a little; nobody looks when no page is open.
        viewers = web.viewerCount
        guard web.viewerCount > 0 else { return }
        let stats = demoStats.map { Demo.vary($0, at: Date().timeIntervalSince1970) } ?? monitor.sample()
        lastStats = stats
        web.broadcast(Self.json(stats))
    }

    private func tickDay() {
        if tasks.rollIfNeeded() { broadcastTasks() }
        pomodoro.checkDay()
        refreshHookState()
    }

    // MARK: - Pomodoro prompt on the Mac

    var onPromptUI: ((PomodoroTimer.Prompt?) -> Void)?

    private func promptChanged(_ prompt: PomodoroTimer.Prompt?) {
        if prompt != nil, !isDemo { NSSound(named: "Glass")?.play() }
        onPromptUI?(prompt)
        broadcastPomodoro()
    }

    // MARK: - Messages to the tablet

    nonisolated static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private var now: Double { Date().timeIntervalSince1970 }

    func claudeMessage() -> String {
        let rows: [[String: Any]] = sessions.map { s in
            var row: [String: Any] = ["id": s.id, "project": s.project, "state": s.state.rawValue,
                                      "activity": s.activity, "stateSince": s.stateSince.timeIntervalSince1970,
                                      "firstSeenAt": s.firstSeenAt.timeIntervalSince1970]
            if let t = s.turnStartedAt { row["turnStartedAt"] = t.timeIntervalSince1970 }
            if let d = s.lastTurnSeconds { row["lastTurnSeconds"] = d }
            if let model = s.model { row["model"] = ToolText.prettyModel(model) }
            if let ctx = s.contextPercent { row["contextPercent"] = ctx }
            row["steps"] = s.steps.suffix(6).map { ["at": $0.at.timeIntervalSince1970, "text": $0.text] as [String: Any] }
            return row
        }
        return Self.json(["type": "claude", "sessions": rows, "hooksInstalled": isDemo || hooks.hooks, "sentAt": now])
    }

    func limitsMessage() -> String {
        func window(_ w: LimitWindow?) -> Any {
            guard let w else { return NSNull() }
            var out: [String: Any] = ["percent": w.percent]
            if let r = w.resetsAt { out["resetsAt"] = r }
            return out
        }
        var object: [String: Any] = ["type": "limits", "sentAt": now,
                                     "statusLine": isDemo || hooks.statusLine,
                                     "foreignStatusLine": !isDemo && hooks.foreignStatusLine,
                                     "liveUsage": isDemo || liveUsage.enabled]
        if let limits {
            object["fiveHour"] = window(limits.fiveHour)
            object["sevenDay"] = window(limits.sevenDay)
            object["receivedAt"] = limits.receivedAt
            object["source"] = limits.source.rawValue
        }
        return Self.json(object)
    }

    func mediaMessage() -> String {
        let track = spotify.nowPlaying
        let running = isDemo ? !demoSpotifyClosed : spotify.isRunning
        return Self.json([
            "type": "media", "running": running, "title": track.title, "artist": track.artist,
            "playing": track.isPlaying, "album": track.album,
            // Position at sentAt; the tablet moves the progress bar on by itself while playing.
            "position": track.livePosition(), "duration": track.duration, "sentAt": now,
            "artwork": spotify.artwork == nil ? "" : "/artwork?v=\(spotify.artworkVersion)",
        ])
    }

    func weekMessage() -> String {
        Self.json(["type": "week", "days": pomodoro.history.week().map { day -> [String: Any] in
            var row: [String: Any] = ["date": day.date, "focusSeconds": day.focusSeconds]
            if let p = day.purity { row["purity"] = p }
            return row
        }])
    }

    /// "In Browser": the page with its key (without it the page can't connect).
    var browserURL: URL? { URL(string: link.pageURL) }

    /// `{"type":"standby","active":…}`: the Mac is away (and the clock is switched on in Settings).
    func standbyMessage() -> String {
        Self.json(["type": "standby", "active": standbyOnSleep && (isDemo ? demoStandby : standby.isActive)])
    }
    func broadcastStandby() { web.broadcast(standbyMessage()) }

    func settingsMessage() -> String {
        Self.json(["type": "settings", "breathingPattern": breathingPattern, "macFont": standbyMacFont])
    }

    private func sendSnapshot(to client: WebClient) {
        viewers = web.viewerCount
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let messages = [
            Self.json(["type": "hello", "version": version, "build": StaticFiles.build, "demo": isDemo]),
            settingsMessage(), Self.json(["type": "netstatus", "online": network.isOnline]), claudeMessage(), limitsMessage(), mediaMessage(), Self.json(weather.latest),
            Self.json(pomodoro.message), weekMessage(), Self.json(tasks.message), Self.json(quickTimer.message()),
        ] + (lastStats.map { [Self.json($0)] } ?? []) + [standbyMessage()]
        messages.forEach { web.send($0, to: client) }
    }

    func broadcastClaude() { web.broadcast(claudeMessage()); revision += 1 }
    func broadcastLimits() { web.broadcast(limitsMessage()); revision += 1 }
    func broadcastMedia() { web.broadcast(mediaMessage()) }
    func broadcastWeather() { web.broadcast(Self.json(weather.latest)) }
    func broadcastTasks() { web.broadcast(Self.json(tasks.message)); revision += 1 }
    func broadcastQuickTimer() { web.broadcast(Self.json(quickTimer.message())); revision += 1 }
    func broadcastSettings() { web.broadcast(settingsMessage()) }
    func broadcastNetwork() { web.broadcast(Self.json(["type": "netstatus", "online": network.isOnline])) }

    private var lastPomodoroPhase = ""
    private var lastPomodoroCompleted = -1
    func broadcastPomodoro() {
        let message = pomodoro.message
        web.broadcast(Self.json(message))
        // The week chart changes only when a period ends.
        if message.completed != lastPomodoroCompleted || message.phase != lastPomodoroPhase {
            lastPomodoroCompleted = message.completed
            lastPomodoroPhase = message.phase
            web.broadcast(weekMessage())
            revision += 1
        }
    }

    // MARK: - Commands from the tablet (whitelist)

    func command(_ text: String) {
        guard text.utf8.count <= 4096,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let name = object["command"] as? String else { return }
        switch name {
        case "media.prev": spotify.perform(.previous)
        case "media.next": spotify.perform(.next)
        case "media.playpause": spotify.perform(.playPause)
        case "timer.start":
            quickTimer.start(minutes: (object["minutes"] as? NSNumber)?.intValue)
        case "timer.stop":
            quickTimer.stop()
        case "timer.minutes":
            if let minutes = (object["minutes"] as? NSNumber)?.intValue { quickTimer.setMinutes(minutes) }
        case "timer.sound":
            if let on = object["on"] as? Bool { quickTimer.soundOnTablet = on }
        case "task.toggle":
            if let id = object["id"] as? String, id.count <= 64 { tasks.toggle(id) }
        case "pomodoro.answer":
            if let yes = object["yes"] as? Bool { pomodoro.answer(yes) }
        default:
            break
        }
    }

    // MARK: - Routes

    private let siteIcons = SiteIcons()

    func route(_ request: HTTPRequest) async -> HTTPResponse? {
        switch request.path {
        case "/artwork":
            guard let data = spotify.artwork else { return nil }
            let png = data.starts(with: [0x89, 0x50])
            return HTTPResponse(contentType: png ? "image/png" : "image/jpeg", body: data, cacheable: true)
        case "/appicon":
            guard let id = request.query["id"] else { return nil }
            // Sites are fetched from the site itself; demo mode stays offline.
            if id.hasPrefix("web.") {
                guard !isDemo, let data = await siteIcons.png(for: id) else { return nil }
                return HTTPResponse(contentType: "image/png", body: data, cacheable: true)
            }
            guard let data = AppIcons.png(bundleID: id) else { return nil }
            return HTTPResponse(contentType: "image/png", body: data, cacheable: true)
        case "/font/rounded":
            guard standbyMacFont, let data = FileManager.default.contents(atPath: Self.roundedFontPath) else { return nil }
            return HTTPResponse(contentType: "font/ttf", body: data, cacheable: true)
        case "/sound/glass.wav":
            guard let data = Chime.glassWAV() else { return nil }
            return HTTPResponse(contentType: "audio/wav", body: data, cacheable: true)
        case "/icon-192.png", "/icon-512.png":
            let size = request.path == "/icon-192.png" ? 192 : 512
            guard let data = IconArt.png(size: size) else { return nil }
            return HTTPResponse(contentType: "image/png", body: data, cacheable: true)
        default:
            return StaticFiles.response(for: request.path)
        }
    }

    // MARK: - Demo

    var demoSpotifyClosed = false

    func setDemo(sessions: [ClaudeSessionInfo], limits: PlanLimits?, stats: SystemStats) {
        self.sessions = sessions
        self.limits = limits
        demoStats = stats
        hooks = ClaudeHooks.InstallState(hooks: true, statusLine: true, foreignStatusLine: false)
        broadcastClaude()
        broadcastLimits()
    }
}
