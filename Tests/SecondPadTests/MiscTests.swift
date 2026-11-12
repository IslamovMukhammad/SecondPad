import Foundation
import Testing
@testable import SecondPad

@Suite("Claude card timers")
struct TurnTimerTests {

    @Test func turnStartsOnThePromptAndFreezesOnStop() {
        let status = ClaudeStatus()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let payload: [String: Any] = ["session_id": "s1", "cwd": "/tmp/demo-project"]
        status.handle(event: "SessionStart", payload: payload, now: t0)
        #expect(status.sessionInfos.first?.turnStartedAt == nil)
        status.handle(event: "UserPromptSubmit", payload: payload, now: t0.addingTimeInterval(5))
        #expect(status.sessionInfos.first?.turnStartedAt == t0.addingTimeInterval(5))
        status.handle(event: "PreToolUse", payload: payload.merging(["tool_name": "Read"]) { $1 }, now: t0.addingTimeInterval(20))
        #expect(status.sessionInfos.first?.turnStartedAt == t0.addingTimeInterval(5))
        status.handle(event: "Stop", payload: payload, now: t0.addingTimeInterval(125))
        let info = status.sessionInfos.first
        #expect(info?.state == .done)
        #expect(info?.turnStartedAt == nil)
        #expect(info?.lastTurnSeconds == 120)
        #expect(info?.firstSeenAt == t0)
        #expect(info?.project == "demo-project")
    }
}

@Suite("Weather, link, system, media")
struct MiscTests {

    @Test func weatherParsingAndURLs() throws {
        let data = Data(#"{"current":{"temperature_2m":17.6,"weather_code":3,"is_day":0}}"#.utf8)
        let reading = try #require(WeatherService.parse(data, city: "Lakeside"))
        #expect(reading.temperature == 18 && reading.code == 3 && !reading.isDay && reading.city == "Lakeside")
        #expect(WeatherService.parse(Data("{}".utf8), city: "x") == nil)
        let url = try #require(WeatherService.forecastURL(WeatherPlace(name: "Lakeside, Somewhere", latitude: 41.31111, longitude: 69.2797)))
        #expect(url.host == "api.open-meteo.com")
        #expect(!url.absoluteString.contains("Lakeside"))   // only coordinates leave the Mac
        let places = WeatherService.parsePlaces(Data(#"{"results":[{"name":"Lakeside","admin1":"North","country":"Nowhere","latitude":1.5,"longitude":2.5},{"name":"Bad"}]}"#.utf8))
        #expect(places == [WeatherPlace(name: "Lakeside, North", latitude: 1.5, longitude: 2.5)])
        #expect(WeatherService.geocodeURL("New York")?.host == "geocoding-api.open-meteo.com")
    }

    @Test func adbParsing() {
        #expect(TabletLink.firstDevice("List of devices attached\nR52T\tunauthorized\nHT7A\tdevice\n\n") == "HT7A")
        #expect(TabletLink.firstDevice("List of devices attached\n\n") == nil)
        #expect(TabletLink.firstDevice(nil) == nil)
        let args = TabletLink.openArguments(serial: "HT7A", url: "http://127.0.0.1:8770/?k=ab12")
        #expect(args.contains("com.android.chrome"))
        #expect(args.contains("'http://127.0.0.1:8770/?k=ab12'"))   // quoted for the tablet's shell
        #expect(!args.joined(separator: " ").contains("forward"))   // no DevTools forwarding
    }

    @Test func topProcessAndPeaks() {
        let out = "%CPU   RSS COMMAND\n 380,0 204800 Google Chrome Helper (Renderer)\n 12.0 1048576 Xcode\n 3.0 102400 Google Chrome Helper (Renderer)\n 0.0 10 M-weird\n"
        let tops = SystemMonitor.parseProcesses(out, cores: 10)
        #expect(tops.cpu.first?.name == "Google Chrome Helper (Renderer)")
        #expect(tops.cpu.first?.cpu == 38)                     // share of the whole Mac
        #expect(tops.memory.first?.name == "Xcode")
        #expect(tops.memory.first?.memoryMB == 1024)
        #expect(tops.memory.dropFirst().first?.memoryMB == 300)   // helpers with one name add up
        #expect(!tops.cpu.contains { $0.name.contains("M-") })
        #expect(SystemMonitor.parseProcesses("%CPU RSS COMMAND\n").cpu.isEmpty)
        var gate = PeakGate(enter: 85, exit: 70)
        let t0 = Date()
        let g0 = gate.feed(95, now: t0)
        #expect(!g0)
        let g1 = gate.feed(95, now: t0.addingTimeInterval(3))
        #expect(!g1)
        let g2 = gate.feed(95, now: t0.addingTimeInterval(5))
        #expect(g2)
        let g3 = gate.feed(75, now: t0.addingTimeInterval(6))
        #expect(g3)      // above exit: stays on
        let g4 = gate.feed(60, now: t0.addingTimeInterval(7))
        #expect(g4)      // dropping, not for 5 s yet
        let g5 = gate.feed(60, now: t0.addingTimeInterval(12))
        #expect(!g5)
        let g6 = gate.feed(nil, now: t0.addingTimeInterval(13))
        #expect(!g6)
        let monitor = SystemMonitor()
        _ = monitor.sample()
        let stats = monitor.sample()
        #expect(stats.ramTotalGB > 0)
        #expect(!stats.coreLoads.isEmpty)
        #expect(stats.coreLoads.allSatisfy { $0 >= 0 && $0 <= 100 })
        #expect(stats.cpuPercent >= 0 && stats.cpuPercent <= 100)
    }

    @Test func peakRulesMatchTheOriginal() {
        #expect(SystemMonitor.memoryStall(pressure: 4, swapMBs: 0))
        #expect(SystemMonitor.memoryStall(pressure: 2, swapMBs: 6))
        #expect(!SystemMonitor.memoryStall(pressure: 2, swapMBs: 1))   // warning alone isn't a stall
        #expect(!SystemMonitor.memoryStall(pressure: 1, swapMBs: 50))
        // A one-second spike to 99 °C from 60 °C barely moves the smoothed value.
        let spike = SystemMonitor.smooth(60, 99, dt: 1)!
        #expect(spike < 65)
        #expect(SystemMonitor.smooth(nil, 70, dt: 1) == 70)
        #expect(SystemMonitor.smooth(70, nil, dt: 1) == 70)
        var t: Double? = 60
        for _ in 0..<40 { t = SystemMonitor.smooth(t, 99, dt: 1) }   // 40 s of real heat gets there
        #expect(t! > 95)
    }

    @Test func spotifyCoversOnlyFromSpotify() {
        #expect(SpotifyService.isAllowedArtwork("https://i.scdn.co/image/ab67616d0000b273"))
        #expect(SpotifyService.isAllowedArtwork("https://mosaic.scdn.co/640/abc"))
        #expect(!SpotifyService.isAllowedArtwork("http://i.scdn.co/image/x"))
        #expect(!SpotifyService.isAllowedArtwork("https://i.scdn.co.evil.example/x"))
        #expect(!SpotifyService.isAllowedArtwork("file:///etc/passwd"))
        #expect(!SpotifyService.isAllowedArtwork(""))
        #expect(SpotifyParser.parse("NOT_RUNNING") == .notRunning)
        // Controls only ever talk to Spotify.
        for action in [SpotifyService.Action.playPause, .next, .previous] {
            #expect(SpotifyService.script(for: action).hasPrefix("tell application \"Spotify\" to "))
        }
        #expect(!SpotifyService.pollScript.contains("System Events"))
    }

    @Test func wavHeader() {
        let samples: [Float] = [0, 0.5, -0.5, 1]
        let data = samples.withUnsafeBufferPointer { Chime.wav(channels: [$0.baseAddress!], frames: 4, sampleRate: 44_100) }
        #expect(data.count == 44 + 8)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(Array(data[44..<46]) == [0, 0])
        #expect(Chime.glassWAV().map { $0.count > 1000 } ?? true)
    }

    @Test func siteIconsOnlyForKnownSites() async throws {
        #expect(SiteIcons.host(for: "web.youtube") == "youtube.com")
        #expect(SiteIcons.host(for: "web.evil") == nil)
        #expect(SiteIcons.host(for: "com.apple.Music") == nil)
        #expect(SiteIcons.candidates(host: "youtube.com").allSatisfy { $0.scheme == "https" && $0.host?.hasSuffix("youtube.com") == true })
        let icons = SiteIcons()
        let png = try #require(IconArt.png(size: 32))
        let asked = Box()
        icons.fetch = { url in await asked.add(url); return png }
        let out = try #require(await icons.png(for: "web.github"))
        #expect(out.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(await icons.png(for: "web.unknown") == nil)
        #expect(await asked.urls.count == 1)                         // cached after the first fetch
        #expect(SiteIcons.redraw(Data("<html>not an image</html>".utf8)) == nil)
    }

    actor Box { var urls: [URL] = []; func add(_ url: URL) { urls.append(url) } }

    @Test func iconDrawsAtEverySize() throws {
        for size in [16, 32, 192, 512, 1024] {
            let png = try #require(IconArt.png(size: size))
            #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        }
        #expect(AppIcons.png(bundleID: "../../etc") == nil)
        #expect(AppIcons.png(bundleID: "web.youtube") == nil)
    }
}

@Suite("StandBy clock")
struct StandbyTests {

    @Test func anyAwaySignalShowsTheClockUntilAllAreBack() {
        var state = StandbyState()
        #expect(!state.isActive)
        state.apply(.screenSaverStarted)
        #expect(state.isActive)
        state.apply(.locked)                 // the screen saver locks too
        state.apply(.screenSaverStopped)     // back at the login window: still locked
        #expect(state.isActive)
        state.apply(.unlocked)
        #expect(!state.isActive)
        // Lock without a screen saver; displays asleep while unlocked.
        state.apply(.locked); #expect(state.isActive)
        state.apply(.unlocked); #expect(!state.isActive)
        state.apply(.displaysSlept); #expect(state.isActive)
        state.apply(.displaysWoke); #expect(!state.isActive)
    }

    @Test func sleepAndWake() {
        var state = StandbyState()
        state.apply(.displaysSlept)
        state.apply(.macWillSleep)
        #expect(state.isActive)
        // Waking clears sleep and the display state; a lock that is still there keeps the clock.
        state.apply(.macWoke)
        #expect(!state.isActive)
        state.apply(.locked)
        state.apply(.macWillSleep)
        state.apply(.macWoke)
        #expect(state.isActive)
        state.apply(.unlocked)
        #expect(!state.isActive)
    }

    @Test func watchReportsOnlyChanges() {
        let watch = StandbyWatch()
        var changes = 0
        watch.onChange = { changes += 1 }
        watch.apply(.locked)
        watch.apply(.screenSaverStarted)     // already away: no new message
        watch.apply(.screenSaverStopped)
        watch.apply(.unlocked)
        #expect(changes == 2)
    }

    @Test func messageFollowsTheSetting() throws {
        let model = AppModel(demo: true, defaults: TestDefaults.make("standby"))
        let decode = { (text: String) throws -> [String: Any] in
            try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        var message = try decode(model.standbyMessage())
        #expect(message["type"] as? String == "standby")
        #expect(message["active"] as? Bool == false)
        #expect(model.standbyOnSleep)        // on by default
        model.standbyOnSleep = false
        message = try decode(model.standbyMessage())
        #expect(message["active"] as? Bool == false)
    }
}

@Suite("Opening the page")
struct PageURLTests {
    @Test func inBrowserCarriesTheKey() throws {
        let model = AppModel(demo: true, defaults: TestDefaults.make("browser"))
        let url = try #require(model.browserURL)
        #expect(url.host == "127.0.0.1")
        #expect(url.port == Int(model.web.port))
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "k" }?.value
        #expect(key == model.web.token)
        #expect(WebToken.isWellFormed(key ?? ""))
        #expect(model.link.pageURL == url.absoluteString)   // the tablet and the browser open the same page
    }
}

@Suite("StandBy font")
struct StandbyFontTests {
    private func get(_ path: String, key: String?) -> HTTPRequest {
        HTTPRequest(method: "GET", path: path, query: key.map { ["k": $0] } ?? [:], headers: ["host": "127.0.0.1:8770"], body: Data())
    }

    @Test func fontNeedsTheKeyAndTheSetting() async throws {
        let model = AppModel(demo: true, defaults: TestDefaults.make("macfont"))
        let token = model.web.token
        // The key: missing / wrong refused, right one allowed.
        #expect(!WebServer.authorized(get("/font/rounded", key: nil), token: token))
        #expect(!WebServer.authorized(get("/font/rounded", key: String(repeating: "0", count: 64)), token: token))
        #expect(WebServer.authorized(get("/font/rounded", key: token), token: token))
        // The setting: off by default → nothing is served; on → this Mac's font (if it has one).
        #expect(!model.standbyMacFont)
        #expect(model.settingsMessage().contains("\"macFont\":false"))
        #expect(await model.route(get("/font/rounded", key: token)) == nil)
        model.standbyMacFont = true
        #expect(model.settingsMessage().contains("\"macFont\":true"))
        let response = await model.route(get("/font/rounded", key: token))
        if FileManager.default.fileExists(atPath: AppModel.roundedFontPath) {
            #expect(response?.contentType == "font/ttf")
            #expect((response?.body.count ?? 0) > 100_000)
        } else {
            #expect(response == nil)
        }
    }
}
