import AppKit

/// `--demo`: made-up data for screenshots. No hooks, no Spotify, no network, no adb, no files.
enum Demo {

    /// The demo Pomodoro's clock runs this many seconds ahead, so a focus period can be shown
    /// half-way with a minute strip already drawn.
    static var shift: TimeInterval = 0

    /// Live usage in demo mode never reads the Keychain.
    nonisolated struct NoLogin: LiveUsage.CredentialSource {
        func read() async -> Result<LiveUsageParser.Credential, LiveUsage.Failure> { .failure(.init("Demo mode")) }
    }

    static func fill(_ model: AppModel) {
        let now = Date()

        // Claude: three sessions in three states.
        func session(_ id: String, _ project: String, _ state: ClaudeStatus.State, _ activity: String,
                     since: TimeInterval, turn: TimeInterval?, last: Int? = nil, seen: TimeInterval) -> ClaudeSessionInfo {
            ClaudeSessionInfo(id: id, project: project, state: state, activity: activity, model: "claude-opus-5-5",
                              contextPercent: 42, cwd: nil, stateSince: now.addingTimeInterval(-since),
                              turnStartedAt: turn.map { now.addingTimeInterval(-$0) }, lastTurnSeconds: last,
                              firstSeenAt: now.addingTimeInterval(-seen))
        }
        var sessions = [
            session("a", "weather-kit", .working, "editing ForecastView.swift", since: 200, turn: 263, seen: 3000),
            session("b", "landing-page", .waiting, "Claude needs your permission to use Bash", since: 48, turn: nil, seen: 2000),
            session("c", "notes-api", .done, "answer ready", since: 30, turn: nil, last: 412, seen: 1000),
        ]
        let stepTexts = ["Got your message", "Reading ForecastService.swift", "Searching the code", "Running the tests", "Editing ForecastView.swift"]
        sessions[0].steps = stepTexts.enumerated().map { ClaudeStep(at: now.addingTimeInterval(-Double(263 - $0.offset * 55)), text: $0.element) }
        sessions[1].steps = [ClaudeStep(at: now.addingTimeInterval(-300), text: "Got your message"),
                             ClaudeStep(at: now.addingTimeInterval(-48), text: "Asked you: Claude needs your permission to use Bash")]
        if ProcessInfo.processInfo.environment["SECONDPAD_DEMO_ONE"] != nil { sessions = [sessions[0]] }
        let limits = PlanLimits(fiveHour: LimitWindow(percent: 63, resetsAt: now.addingTimeInterval(67 * 60).timeIntervalSince1970),
                                sevenDay: LimitWindow(percent: 24, resetsAt: now.addingTimeInterval(4 * 86_400 + 7 * 3600).timeIntervalSince1970),
                                receivedAt: now.addingTimeInterval(-40).timeIntervalSince1970, source: .statusLine)
        var stats = SystemStats()
        stats.cpuPercent = 34
        stats.topProcess = "Xcode"
        stats.topProcessCPU = 21
        stats.ramPercent = 71
        stats.ramUsedGB = 11.4
        stats.ramTotalGB = 16
        stats.compressedGB = 1.6
        stats.swapUsedGB = 0.8
        stats.swapTotalGB = 2
        stats.memoryPressure = 1
        stats.uptimeDays = 1.2
        stats.temperature = 58
        stats.fanLoad = 0.18
        stats.batteryPercent = 82
        stats.batteryCharging = true
        stats.coreLoads = [48, 31, 22, 17, 9, 6, 4, 3]
        stats.performanceCores = 4
        stats.topCPU = [ProcessRow(name: "Xcode", cpu: 21, bundleId: "com.apple.dt.Xcode"),
                        ProcessRow(name: "WindowServer", cpu: 9), ProcessRow(name: "swift-frontend", cpu: 7),
                        ProcessRow(name: "Safari", cpu: 4, bundleId: "com.apple.Safari"),
                        ProcessRow(name: "Music", cpu: 2, bundleId: "com.apple.Music"), ProcessRow(name: "kernel_task", cpu: 2)]
        stats.topMemory = [ProcessRow(name: "Xcode", memoryMB: 3420, bundleId: "com.apple.dt.Xcode"),
                           ProcessRow(name: "Safari", memoryMB: 1870, bundleId: "com.apple.Safari"),
                           ProcessRow(name: "WindowServer", memoryMB: 960), ProcessRow(name: "Music", memoryMB: 610, bundleId: "com.apple.Music"),
                           ProcessRow(name: "Finder", memoryMB: 240, bundleId: "com.apple.finder"), ProcessRow(name: "Dock", memoryMB: 120, bundleId: "com.apple.dock")]
        stats.sensors = [Sensor(name: "Chip (hottest point)", celsius: 58), Sensor(name: "CPU sensor 1", celsius: 54),
                         Sensor(name: "CPU sensor 2", celsius: 52), Sensor(name: "CPU sensor 3", celsius: 49), Sensor(name: "CPU sensor 4", celsius: 47)]
        stats.fanRPM = 1240
        stats.fanMaxRPM = 6800
        model.setDemo(sessions: sessions, limits: limits, stats: stats)

        // Spotify: a made-up track with a cover drawn here.
        model.spotify.setDemo(NowPlaying(title: "Low Tide Lanterns", artist: "The Quiet Harbour",
                                         album: "Night Swim", isPlaying: true, position: 74, duration: 214,
                                         positionStamp: now.timeIntervalSince1970),
                              artwork: cover())

        model.weather.setDemo(WeatherMessage(temperature: 18, code: 2, isDay: true, city: "Lakeside",
                                             updatedAt: now.timeIntervalSince1970))

        for (text, done) in [("Reply to the design review", false), ("Ship the onboarding fix", false),
                             ("Book the dentist", false), ("Write release notes", true), ("Water the plants", true)] {
            if let task = model.tasks.add(text), done { model.tasks.toggle(task.id) }
        }

        model.quickTimer.start(minutes: 15, now: now.addingTimeInterval(-4 * 60 - 12))

        fillPomodoro(model, now: now)
    }

    /// Demo numbers drift a little every second, so the sheets' charts show a curve.
    static func vary(_ base: SystemStats, at t: TimeInterval) -> SystemStats {
        var s = base
        let wave = sin(t / 23) * 0.5 + sin(t / 7) * 0.3 + sin(t / 3.1) * 0.2
        if base.cpuPercent < 100 {
            s.cpuPercent = max(3, min(97, base.cpuPercent + wave * 18))
            s.coreLoads = base.coreLoads.enumerated().map { i, v in max(1, min(100, v + sin(t / 5 + Double(i)) * 12)) }
            s.topCPU = base.topCPU.enumerated().map { i, p in var p = p; p.cpu = max(0.3, p.cpu + sin(t / 9 + Double(i)) * p.cpu * 0.4); return p }
        }
        if let temp = base.temperature, temp < 99 { s.temperature = temp + wave * 4 }
        s.ramPercent = min(99, base.ramPercent + sin(t / 40) * 2)
        return s
    }

    /// `--demo worst`: the realistic worst case for every value on both pages (dev only; it is
    /// how the layout is tested against long names, full lists, missing data and red numbers).
    static func fillWorst(_ model: AppModel) {
        let now = Date()
        let names = ["customer-feedback-from-enterprise-onboarding", "🦊-fox-app", "a", "Konstantin-Oberhauser-Wettstein-monorepo",
                     "customer-feedback-from-enterprise-onboarding", "api", "Đặng-Thị-Ngọc-Hân-portfolio", "ios", "web", "infra-terraform-modules"]
        let states: [ClaudeStatus.State] = [.working, .waiting, .error, .done, .working, .working, .waiting, .done, .working, .working]
        let activities = ["Run the full test suite for the payments service and summarise the failures by module",
                          "Claude needs your permission to use Bash: rm -rf build/DerivedData && xcodebuild -scheme App -destination generic/platform=iOS",
                          "limit reached", "answer ready", "editing Benachrichtigungseinstellungen.swift", "thinking", "asking you a question",
                          "stopped", "fetching docs.example.com", "using the infra-terraform-modules-and-policies skill"]
        let sessions = names.indices.map { i in
            ClaudeSessionInfo(id: "w\(i)", project: names[i], state: states[i], activity: activities[i], model: nil, contextPercent: nil,
                              cwd: nil, stateSince: now.addingTimeInterval(-Double(5000 + i * 900)),
                              turnStartedAt: states[i] == .working ? now.addingTimeInterval(-Double(3700 + i * 400)) : nil,
                              lastTurnSeconds: states[i] == .done ? 7384 : nil, firstSeenAt: now.addingTimeInterval(-Double(10_000 - i)))
        }
        var stats = SystemStats()
        stats.cpuPercent = 100
        stats.topProcess = "com.apple.WebKit.WebContent.Development"
        stats.topProcessCPU = 38
        stats.ramPercent = 99
        stats.ramUsedGB = 15.9
        stats.ramTotalGB = 16
        stats.compressedGB = 6.4
        stats.swapUsedGB = 12.4
        stats.swapTotalGB = 13
        stats.swapInMBs = 58
        stats.swapOutMBs = 41
        stats.memoryPressure = 4
        stats.uptimeDays = 41.3
        stats.temperature = 99
        stats.fanLoad = 1
        stats.fanRPM = 6800
        stats.fanMaxRPM = 6800
        stats.thermalState = "critical"
        stats.batteryPercent = 12   // low (red) but above 10 %, so the dashboard itself shows
        stats.batteryCharging = false
        stats.cpuPeak = true
        stats.heatPeak = true
        stats.memoryPeak = true
        stats.coreLoads = Array(repeating: 100, count: 10)
        stats.performanceCores = 8
        stats.topCPU = [ProcessRow(name: "com.apple.WebKit.WebContent.Development", cpu: 38),
                        ProcessRow(name: "Google Chrome Helper (Renderer)", cpu: 24, bundleId: nil),
                        ProcessRow(name: "Xcode", cpu: 18, bundleId: "com.apple.dt.Xcode"), ProcessRow(name: "kernel_task", cpu: 9.5),
                        ProcessRow(name: "WindowServer", cpu: 6.1), ProcessRow(name: "mds_stores", cpu: 4.4)]
        stats.topMemory = [ProcessRow(name: "Google Chrome Helper (Renderer)", memoryMB: 9100),
                           ProcessRow(name: "Xcode", memoryMB: 6200, bundleId: "com.apple.dt.Xcode"),
                           ProcessRow(name: "com.apple.WebKit.WebContent.Development", memoryMB: 2400),
                           ProcessRow(name: "Simulator", memoryMB: 1900), ProcessRow(name: "Docker", memoryMB: 1200), ProcessRow(name: "J", memoryMB: 3)]
        stats.sensors = (1...12).map { Sensor(name: $0 == 1 ? "Chip (hottest point)" : "CPU sensor \($0 - 1)", celsius: 99 - Double($0)) }
        model.setDemo(sessions: sessions, limits: nil, stats: stats)

        // Spotify closed: no track, not running.
        model.spotify.setDemo(NowPlaying(), artwork: nil)
        model.demoSpotifyClosed = true
        model.weather.setDemo(WeatherMessage(temperature: -12, code: 95, isDay: false,
                                             city: "Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch, Wales",
                                             updatedAt: now.timeIntervalSince1970 - 7200))

        let texts = ["Reply to bartholomew.fitzgerald@northwind-industries-holdings.example.com about the Q3 board deck",
                     "https://example.com/workspaces/acme/projects/q3-launch/docs/9f8e7d6c5b4a?tab=comments&filter=unresolved",
                     "Benachrichtigungseinstellungen", "J", "🦊 feed the fox", "<script>alert(1)</script> &amp; **bold**",
                     "Đặng Thị Ngọc Hân: review the portfolio copy"]
        for i in 0..<30 {
            let text = i < texts.count ? texts[i] : "Task \(i + 1): ship the onboarding fix for the enterprise workspace"
            if let task = model.tasks.add(text), i % 3 == 2 { model.tasks.toggle(task.id) }
        }

        // 12 pomodoros today, a long distracting app name, many distractions.
        let entries = (0..<12).map { i in
            PomodoroLogEntry(index: i + 1, completed: true, interruptions: 3, durationSeconds: 1500, purity: 31, focusBreaks: 9,
                             distractions: [FocusDistraction(app: "Google Chrome Helper (Renderer)", bundleId: nil, category: "other", colorHex: "#6e6e73", visits: 14, seconds: 610),
                                            FocusDistraction(app: "Telegram", bundleId: "ru.keepcoder.Telegram", category: "chat", colorHex: "#ff9f0a", visits: 31, seconds: 540),
                                            FocusDistraction(app: "YouTube", bundleId: "web.youtube", category: "video", colorHex: "#bf5af2", visits: 6, seconds: 1200),
                                            FocusDistraction(app: "Instagram", bundleId: "web.instagram", category: "social", colorHex: "#ff375f", visits: 9, seconds: 300),
                                            FocusDistraction(app: "Discord", bundleId: "com.hnc.Discord", category: "chat", colorHex: "#ff9f0a", visits: 4, seconds: 80),
                                            FocusDistraction(app: "Music", bundleId: "com.apple.Music", category: "music", colorHex: "#64d2ff", visits: 2, seconds: 30)],
                             minutes: [], endedAt: now.timeIntervalSince1970 - Double(i * 1800))
        }
        model.pomodoro.history.save(today: entries, completedSinceLongBreak: 0, now: now)
        model.pomodoro.reloadToday()
    }

    /// A week of past focus, two pomodoros done today, a third running 14 minutes in.
    private static func fillPomodoro(_ model: AppModel, now: Date) {
        let history = model.pomodoro.history
        let calendar = Calendar.current
        let pattern: [(count: Int, purity: Int)] = [(3, 82), (5, 91), (2, 64), (4, 77), (6, 88), (1, 58)]
        for (back, day) in pattern.enumerated() {
            let date = calendar.date(byAdding: .day, value: -(6 - back), to: now) ?? now
            let entries = (0..<day.count).map { i in
                PomodoroLogEntry(index: i + 1, completed: true, interruptions: 0, durationSeconds: 1500,
                                 purity: day.purity, focusBreaks: 1, distractions: [], minutes: [],
                                 endedAt: date.timeIntervalSince1970)
            }
            history.save(today: entries, completedSinceLongBreak: 0, now: date)
        }
        let today = [
            PomodoroLogEntry(index: 1, completed: true, interruptions: 0, durationSeconds: 1500, purity: 92, focusBreaks: 1,
                             distractions: [FocusDistraction(app: "Telegram", bundleId: nil, category: "chat", colorHex: "#ff9f0a", visits: 2, seconds: 95)],
                             minutes: [], endedAt: now.addingTimeInterval(-7200).timeIntervalSince1970),
            PomodoroLogEntry(index: 2, completed: true, interruptions: 1, durationSeconds: 1500, purity: 81, focusBreaks: 2,
                             distractions: [FocusDistraction(app: "YouTube", bundleId: "web.youtube", category: "video", colorHex: "#bf5af2", visits: 1, seconds: 240)],
                             minutes: [], endedAt: now.addingTimeInterval(-3600).timeIntervalSince1970),
        ]
        history.save(today: today, completedSinceLongBreak: 2, now: now)

        model.pomodoro.reloadToday()
        let pomodoro = model.pomodoro
        // Time on task / off task, as the focus tracker would report it.
        pomodoro.usageProvider = { _, _ in
            [FocusLedger.Usage(app: "Xcode", category: .code, seconds: 690),
             FocusLedger.Usage(app: "Terminal", category: .code, seconds: 70),
             FocusLedger.Usage(app: "YouTube", category: .video, seconds: 75),
             FocusLedger.Usage(app: "Telegram", category: .chat, seconds: 45)]
        }
        shift = 0
        pomodoro.start()
        // Walk 14 minutes forward, with a couple of slips on the way.
        let slips: [Int: (String, String?, ActivityCategory)] = [3: ("Telegram", nil, .chat), 8: ("YouTube", "web.youtube", .video),
                                                                  11: ("Telegram", nil, .chat)]
        for minute in 1...14 {
            if let slip = slips[minute - 1] {
                pomodoro.noteSwitch(app: slip.0, bundleID: slip.1, category: slip.2)
                shift += 40
                pomodoro.noteSwitch(app: "Xcode", bundleID: nil, category: .code)
                shift = TimeInterval(minute * 60)
            } else {
                shift = TimeInterval(minute * 60)
            }
            pomodoro.tick()
        }
        shift += 25
        pomodoro.noteSwitch(app: "YouTube", bundleID: "web.youtube", category: .video)
        pomodoro.tick()
    }

    /// A soft gradient cover with a moon, drawn here (no image from any product).
    static func cover() -> Data? {
        let size = 300
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSGradient(colors: [NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.33, alpha: 1),
                            NSColor(calibratedRed: 0.42, green: 0.23, blue: 0.52, alpha: 1),
                            NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.42, alpha: 1)])?.draw(in: rect, angle: 90)
        NSColor(calibratedRed: 1, green: 0.93, blue: 0.78, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: 170, y: 170, width: 70, height: 70)).fill()
        for (i, alpha) in [0.55, 0.4, 0.28].enumerated() {
            NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.2, alpha: alpha).setFill()
            let wave = NSBezierPath()
            let base = CGFloat(40 + i * 34)
            wave.move(to: NSPoint(x: 0, y: 0))
            wave.line(to: NSPoint(x: 0, y: base))
            for x in stride(from: 0, through: size, by: 10) {
                wave.line(to: NSPoint(x: CGFloat(x), y: base + 10 * sin(CGFloat(x) / 30 + CGFloat(i))))
            }
            wave.line(to: NSPoint(x: CGFloat(size), y: 0))
            wave.close()
            wave.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
