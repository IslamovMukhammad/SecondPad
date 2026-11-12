import Foundation
import Testing
@testable import SecondPad

@Suite("Tablet web server rules")
struct WebServerRuleTests {

    let port: UInt16 = 8770
    let token = String(repeating: "ab", count: 32)

    private func get(_ path: String, _ headers: [String: String], key: String? = nil) -> HTTPRequest {
        HTTPRequest(method: "GET", path: path, query: key.map { ["k": $0] } ?? [:], headers: headers, body: Data())
    }

    @Test func onlyRequestsNamingThisServer() {
        #expect(WebServer.allows(get("/", ["host": "127.0.0.1:8770"]), port: port))
        #expect(WebServer.allows(get("/", ["host": "LOCALHOST:8770"]), port: port))
        // DNS rebinding: a page on evil.example resolving to 127.0.0.1 still sends its own Host.
        #expect(!WebServer.allows(get("/", ["host": "evil.example:8770"]), port: port))
        #expect(!WebServer.allows(get("/", ["host": "127.0.0.1:9999"]), port: port))
        #expect(!WebServer.allows(get("/", [:]), port: port))
        #expect(!WebServer.allows(HTTPRequest(method: "POST", path: "/", headers: ["host": "127.0.0.1:8770"], body: Data()), port: port))
    }

    @Test func webSocketNeedsThisPagesOrigin() {
        var headers = ["host": "127.0.0.1:8770", "upgrade": "websocket", "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
                       "origin": "http://127.0.0.1:8770"]
        #expect(WebServer.allowsUpgrade(get("/ws", headers, key: token), port: port, token: token))
        headers["origin"] = "http://localhost:8770"
        #expect(WebServer.allowsUpgrade(get("/ws", headers, key: token), port: port, token: token))
        headers["origin"] = "https://evil.example"
        #expect(!WebServer.allowsUpgrade(get("/ws", headers, key: token), port: port, token: token))
        headers["origin"] = nil
        #expect(!WebServer.allowsUpgrade(get("/ws", headers, key: token), port: port, token: token))
        headers["origin"] = "http://127.0.0.1:8770"
        #expect(!WebServer.allowsUpgrade(get("/other", headers, key: token), port: port, token: token))
        headers["upgrade"] = nil
        #expect(!WebServer.allowsUpgrade(get("/ws", headers, key: token), port: port, token: token))
    }

    @Test func webSocketNeedsTheKey() {
        let headers = ["host": "127.0.0.1:8770", "upgrade": "websocket", "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
                       "origin": "http://127.0.0.1:8770"]
        // Missing, wrong, one character off, too short, too long, empty: refused.
        let wrongs: [String?] = [nil, String(repeating: "cd", count: 32), String(token.dropLast()) + "c",
                                 String(token.dropLast()), token + "a", ""]
        for key in wrongs {
            #expect(!WebServer.allowsUpgrade(get("/ws", headers, key: key), port: port, token: token))
        }
        #expect(WebServer.allowsUpgrade(get("/ws", headers, key: token), port: port, token: token))
        // Parsed from the real request line, as the page sends it.
        let raw = "GET /ws?k=\(token) HTTP/1.1\r\nHost: 127.0.0.1:8770\r\nUpgrade: websocket\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nOrigin: http://127.0.0.1:8770\r\n\r\n"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else { Issue.record("not parsed"); return }
        #expect(WebServer.allowsUpgrade(request, port: port, token: token))
    }

    @Test func dataRoutesNeedTheKey() {
        let host = ["host": "127.0.0.1:8770"]
        for path in ["/artwork", "/appicon"] {
            #expect(!WebServer.authorized(get(path, host), token: token))                                    // missing
            #expect(!WebServer.authorized(get(path, host, key: String(repeating: "0", count: 64)), token: token))   // wrong
            #expect(WebServer.authorized(get(path, host, key: token), token: token))                         // right
        }
        #expect(!WebServer.authorized(get("/ws", host), token: token))
        // The page itself, its scripts and SecondPad's own icon load without it (the key is read
        // by the page's script).
        for path in ["/", "/app.js", "/styles.css", "/manifest.webmanifest", "/icon-192.png", "/sound/glass.wav"] {
            #expect(WebServer.authorized(get(path, host), token: token))
        }
    }

    @Test func pageKeyIsSavedPrivately() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("secondpad-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("web-token")
        let first = try #require(WebToken.load(from: url))
        #expect(WebToken.isWellFormed(first))
        #expect(first.count == 64)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // Same key after a relaunch; a damaged file gets a new one.
        #expect(WebToken.load(from: url) == first)
        try Data("not a key".utf8).write(to: url)
        let second = try #require(WebToken.load(from: url))
        #expect(second != first && WebToken.isWellFormed(second))
        #expect(WebToken.make() != WebToken.make())
        #expect(!WebToken.matches(nil, first))
        #expect(!WebToken.matches("", ""))
        #expect(WebToken.matches(first, first))
    }

    @Test func pageIsLockedDown() {
        let csp = WebServer.contentSecurityPolicy(port: port)
        #expect(csp.contains("script-src 'self'"))
        #expect(!csp.contains("unsafe"))
        #expect(csp.contains("ws://127.0.0.1:8770"))
        let html = String(decoding: HTTPResponse(contentType: "text/html; charset=utf-8", body: Data()).serialized(contentSecurityPolicy: csp), as: UTF8.self)
        #expect(html.contains("Content-Security-Policy:"))
        #expect(html.contains("X-Content-Type-Options: nosniff"))
        #expect(html.contains("Cache-Control: no-store"))
    }

    @Test func onlyListedFilesAreServed() {
        #expect(StaticFiles.files["/"]?.name == "index.html")
        for path in ["/../Info.plist", "/Web/index.html", "/%2e%2e/x", "/etc/passwd", "/index.html/"] {
            #expect(StaticFiles.files[path] == nil)
            #expect(StaticFiles.response(for: path) == nil)
        }
    }

    @Test func queryStrings() {
        let (path, query) = HTTPRequest.splitTarget("/appicon?id=com.apple.dt.Xcode&x=a%20b")
        #expect(path == "/appicon")
        #expect(query["id"] == "com.apple.dt.Xcode")
        #expect(query["x"] == "a b")
        guard case .complete(let request) = HTTPRequest.parse(Data("GET /artwork?v=3 HTTP/1.1\r\nHost: 127.0.0.1:8770\r\n\r\n".utf8)) else {
            Issue.record("not parsed"); return
        }
        #expect(request.path == "/artwork")
        #expect(request.query["v"] == "3")
    }
}

@Suite("WebSocket frames")
struct WebSocketTests {

    @Test func handshakeKeyFromTheRFC() {
        #expect(WebSocket.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    private func masked(_ text: String, opcode: UInt8 = 0x1, fin: Bool = true) -> Data {
        let payload = Array(text.utf8)
        let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
        var out: [UInt8] = [(fin ? 0x80 : 0) | opcode]
        if payload.count < 126 { out.append(0x80 | UInt8(payload.count)) }
        else { out += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] }
        out += mask
        out += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        return Data(out)
    }

    @Test func decodesMaskedTextFrames() {
        guard case .frame(let frame, let used) = WebSocket.decode(masked(#"{"command":"timer.stop"}"#)) else {
            Issue.record("not decoded"); return
        }
        #expect(frame.opcode == .text)
        #expect(String(decoding: frame.payload, as: UTF8.self) == #"{"command":"timer.stop"}"#)
        #expect(used == masked(#"{"command":"timer.stop"}"#).count)
        let long = String(repeating: "x", count: 300)
        guard case .frame(let big, _) = WebSocket.decode(masked(long)) else { Issue.record("long"); return }
        #expect(big.payload.count == 300)
    }

    @Test func partialAndHostileFrames() {
        let full = masked("hello")
        #expect(WebSocket.decode(full.prefix(3)) == .incomplete)
        // A client must mask.
        #expect(WebSocket.decode(Data([0x81, 0x02, 0x68, 0x69])) == .invalid)
        // Reserved bits set.
        #expect(WebSocket.decode(Data([0xF1, 0x80, 0, 0, 0, 0])) == .invalid)
        // Claims a payload far over the limit.
        var huge: [UInt8] = [0x81, 0x80 | 127]
        huge += [0, 0, 0, 0, 0x7F, 0xFF, 0xFF, 0xFF]
        #expect(WebSocket.decode(Data(huge)) == .invalid)
    }

    @Test func encodesServerFrames() {
        let small = WebSocket.text("hi")
        #expect(Array(small) == [0x81, 0x02, 0x68, 0x69])
        let medium = WebSocket.text(String(repeating: "a", count: 200))
        #expect(Array(medium.prefix(4)) == [0x81, 126, 0, 200])
        let large = WebSocket.encode(.text, Data(count: 70_000))
        #expect(large[1] == 127)
        #expect(large.count == 70_000 + 10)
        guard case .frame(let back, _) = WebSocket.decode(small, requireMask: false) else { Issue.record("round trip"); return }
        #expect(back.payload == Data("hi".utf8))
    }
}

@Suite("Commands from the tablet", .serialized)
struct CommandTests {

    @Test func onlyKnownCommandsDoAnything() {
        let model = AppModel(demo: true, defaults: TestDefaults.make("commands"))
        let timer = model.quickTimer
        model.command(#"{"command":"timer.minutes","minutes":500}"#)
        #expect(timer.minutes == QuickTimer.maxMinutes)
        model.command(#"{"command":"timer.start","minutes":7}"#)
        #expect(timer.isRunning)
        #expect(timer.minutes == 7)
        model.command(#"{"command":"timer.stop"}"#)
        #expect(!timer.isRunning)
        model.command(#"{"command":"timer.sound","on":false}"#)
        #expect(!timer.soundOnTablet)

        let task = model.tasks.add("Test the tablet")!
        model.command(#"{"command":"task.toggle","id":"\#(task.id)"}"#)
        #expect(model.tasks.today.first { $0.id == task.id }?.done == true)

        // Garbage, unknown commands, huge messages: ignored without a crash.
        let before = model.tasks.today
        for text in ["not json", "{}", #"{"command":"mac.lock"}"#, #"{"command":"task.toggle","id":5}"#,
                     #"{"command":"timer.start","minutes":"x"}"#.replacingOccurrences(of: "start", with: "minutes"),
                     "{\"command\":\"task.toggle\",\"id\":\"" + String(repeating: "a", count: 5000) + "\"}"] {
            model.command(text)
        }
        #expect(model.tasks.today == before)
    }

    @Test func demoModeNeverTouchesHooksOrTheKeychain() async {
        let model = AppModel(demo: true, defaults: TestDefaults.make("demo"))
        model.installHooks()
        #expect(model.hookError?.hasPrefix("Demo mode") == true)
        model.removeHooks()
        #expect(model.hookError?.hasPrefix("Demo mode") == true)
        #expect(!model.liveUsage.enabled)
        model.liveUsage.enabled = true
        await model.liveUsage.poll()
        #expect(!model.liveUsage.holdsCredential)
        #expect(UserDefaults.standard.object(forKey: LiveUsage.enabledKey) == nil
                || UserDefaults.standard.bool(forKey: LiveUsage.enabledKey) == false)
    }

    @Test func messagesAreJSONWithAType() throws {
        let model = AppModel(demo: true, defaults: TestDefaults.make("messages"))
        for text in [model.claudeMessage(), model.limitsMessage(), model.mediaMessage(), model.weekMessage(),
                     model.settingsMessage(), AppModel.json(model.pomodoro.message), AppModel.json(model.tasks.message),
                     AppModel.json(model.quickTimer.message()), AppModel.json(model.weather.latest), AppModel.json(SystemStats())] {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect(object["type"] is String)
        }
    }
}
