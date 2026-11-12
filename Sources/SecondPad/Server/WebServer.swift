import Foundation
import Network

/// One HTTP answer.
nonisolated struct HTTPResponse: Sendable {
    var status = "200 OK"
    var contentType = "text/plain; charset=utf-8"
    var body = Data()
    /// Pages and scripts are never cached, so a rebuilt app is seen at once; images may be.
    var cacheable = false

    static let notFound = HTTPResponse(status: "404 Not Found", body: Data("Not found".utf8))
    static let forbidden = HTTPResponse(status: "403 Forbidden", body: Data("Forbidden".utf8))
    static let unauthorized = HTTPResponse(status: "401 Unauthorized", body: Data("Unauthorized".utf8))
    static let badRequest = HTTPResponse(status: "400 Bad Request", body: Data("Bad request".utf8))

    func serialized(contentSecurityPolicy: String) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: \(cacheable ? "max-age=3600" : "no-store")\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        if contentType.hasPrefix("text/html") { head += "Content-Security-Policy: \(contentSecurityPolicy)\r\n" }
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

/// The tablet's web server: static page + one WebSocket, on 127.0.0.1 only.
///
/// The tablet reaches it through `adb reverse` (USB). Nothing listens on the network: the listener
/// is bound to the loopback address. On top of that every request must name this server in its
/// `Host` header (so a web page can't reach it through DNS rebinding), a WebSocket must come
/// from this page's own origin, and the WebSocket and the data routes need the page's key
/// (`WebToken`), so other programs on this Mac can't read the feed or send commands.
final class WebServer {

    nonisolated static let defaultPort: UInt16 = 8770
    /// Routes that show something about you (your cover art, your apps) or this Mac's own font.
    /// The page, its scripts, SecondPad's own icon and the chime stay open: the same for everyone.
    nonisolated static let protectedPaths: Set<String> = ["/artwork", "/appicon", "/font/rounded"]

    let port: UInt16
    let token: String
    private var listener: NWListener?
    private var retry: Timer?
    private let queue = DispatchQueue(label: "SecondPad.web")
    private var viewers: [ObjectIdentifier: WebClient] = [:]
    private(set) var lastError: String?

    /// GET requests (other than /ws). Return nil for 404. May wait (an icon download).
    var route: ((HTTPRequest) async -> HTTPResponse?)?
    /// A new tablet page connected: send it the current state.
    var onViewer: ((WebClient) -> Void)?
    /// A text message from a page.
    var onMessage: ((String) -> Void)?

    var viewerCount: Int { viewers.count }

    init(port: UInt16 = WebServer.defaultPort, token: String) {
        self.port = port
        self.token = token
    }

    func start() {
        stop()
        do {
            let params = NWParameters.tcp
            // No address reuse: nothing else may share this port. Right after a relaunch the port
            // can still be held for a few seconds; the listener then tries again (below).
            params.allowLocalEndpointReuse = false
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: params)
            let port = self.port
            let token = self.token
            let queue = self.queue
            listener.newConnectionHandler = { [weak self] connection in
                let client = WebClient(connection: connection, port: port, token: token, queue: queue)
                client.handler = { event in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event, from: client) } }
                }
                client.start()
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let error), .waiting(let error):
                    let text = error.localizedDescription
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.failed(text) } }
                case .ready:
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.lastError = nil } }
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The port is busy (still held after a relaunch): try again in 2 s, for as long as it takes.
    private func failed(_ text: String) {
        lastError = text
        guard retry == nil else { return }
        listener?.cancel()
        listener = nil
        retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retry = nil
                self?.start()
            }
        }
    }

    func stop() {
        retry?.invalidate()
        retry = nil
        listener?.cancel()
        listener = nil
        viewers.values.forEach { $0.close() }
        viewers.removeAll()
    }

    func broadcast(_ text: String) {
        let frame = WebSocket.text(text)
        viewers.values.forEach { $0.send(frame) }
    }

    func send(_ text: String, to client: WebClient) {
        client.send(WebSocket.text(text))
    }

    private func handle(_ event: WebClient.Event, from client: WebClient) {
        switch event {
        case .request(let request):
            let csp = Self.contentSecurityPolicy(port: port)
            guard Self.allows(request, port: port) else {
                client.respond(HTTPResponse.forbidden.serialized(contentSecurityPolicy: csp))
                return
            }
            guard Self.authorized(request, token: token) else {
                client.respond(HTTPResponse.unauthorized.serialized(contentSecurityPolicy: csp))
                return
            }
            let route = self.route
            Task {
                let response = await route?(request) ?? .notFound
                client.respond(response.serialized(contentSecurityPolicy: csp))
            }
        case .upgraded:
            viewers[ObjectIdentifier(client)] = client
            onViewer?(client)
        case .text(let text):
            onMessage?(text)
        case .closed:
            viewers.removeValue(forKey: ObjectIdentifier(client))
        }
    }

    // MARK: - Rules (pure, unit-tested)

    nonisolated static func allowedHosts(port: UInt16) -> Set<String> {
        ["127.0.0.1:\(port)", "localhost:\(port)"]
    }

    /// Plain GETs must name this server; anything else is refused.
    nonisolated static func allows(_ request: HTTPRequest, port: UInt16) -> Bool {
        guard request.method == "GET" else { return false }
        guard let host = request.headers["host"]?.lowercased(), allowedHosts(port: port).contains(host) else { return false }
        return true
    }

    /// The WebSocket and the data routes need the page's key (`?k=`); the rest is open.
    nonisolated static func authorized(_ request: HTTPRequest, token: String) -> Bool {
        guard request.path == "/ws" || protectedPaths.contains(request.path) else { return true }
        return WebToken.matches(request.query["k"], token)
    }

    /// The WebSocket also needs this page's own origin (browsers always send it) and its key.
    nonisolated static func allowsUpgrade(_ request: HTTPRequest, port: UInt16, token: String) -> Bool {
        guard allows(request, port: port), request.path == "/ws", authorized(request, token: token) else { return false }
        guard request.headers["upgrade"]?.lowercased() == "websocket",
              request.headers["sec-websocket-key"]?.isEmpty == false else { return false }
        guard let origin = request.headers["origin"]?.lowercased() else { return false }
        return allowedHosts(port: port).contains { "http://\($0)" == origin }
    }

    nonisolated static func contentSecurityPolicy(port: UInt16) -> String {
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
            + "media-src 'self'; connect-src 'self' ws://127.0.0.1:\(port) ws://localhost:\(port); "
            + "object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
    }
}

/// One connection. All its state lives on the server queue.
nonisolated final class WebClient: @unchecked Sendable {

    enum Event: Sendable {
        case request(HTTPRequest)
        case upgraded
        case text(String)
        case closed
    }

    private let connection: NWConnection
    private let port: UInt16
    private let token: String
    private let queue: DispatchQueue
    private var buffer = Data()
    private var isWebSocket = false
    private var fragments = Data()
    private var closed = false
    var handler: (@Sendable (Event) -> Void)?

    init(connection: NWConnection, port: UInt16, token: String, queue: DispatchQueue) {
        self.connection = connection
        self.port = port
        self.token = token
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func send(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    /// Answers a plain request and closes.
    func respond(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.close() })
        }
    }

    func close() {
        queue.async { [self] in
            connection.cancel()
            finish()
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        handler?(.closed)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            self.process()
            if error != nil || isComplete { self.connection.cancel(); self.finish(); return }
            if !self.closed { self.receive() }
        }
    }

    private func process() {
        if isWebSocket { processFrames(); return }
        switch HTTPRequest.parse(buffer) {
        case .complete(let request):
            buffer.removeAll()
            if request.path == "/ws" {
                guard WebServer.allowsUpgrade(request, port: port, token: token), let key = request.headers["sec-websocket-key"] else {
                    let refusal = WebServer.authorized(request, token: token) ? HTTPResponse.forbidden : HTTPResponse.unauthorized
                    connection.send(content: refusal.serialized(contentSecurityPolicy: ""),
                                    completion: .contentProcessed { [weak self] _ in self?.close() })
                    return
                }
                let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    + "Sec-WebSocket-Accept: \(WebSocket.acceptKey(for: key))\r\n\r\n"
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                isWebSocket = true
                handler?(.upgraded)
            } else {
                handler?(.request(request))
            }
        case .incomplete:
            break
        case .invalid, .tooLarge:
            buffer.removeAll()
            connection.send(content: HTTPResponse.badRequest.serialized(contentSecurityPolicy: ""),
                            completion: .contentProcessed { [weak self] _ in self?.close() })
        }
    }

    private func processFrames() {
        while true {
            switch WebSocket.decode(buffer) {
            case .incomplete:
                return
            case .invalid:
                connection.send(content: WebSocket.encode(.close, Data([0x03, 0xF2])),   // 1010-ish: refuse
                                completion: .contentProcessed { [weak self] _ in self?.close() })
                buffer.removeAll()
                return
            case .frame(let frame, let consumed):
                buffer.removeFirst(consumed)
                switch frame.opcode {
                case .text, .continuation:
                    fragments.append(frame.payload)
                    guard fragments.count <= WebSocket.maxPayload else { close(); return }
                    if frame.fin {
                        let text = String(decoding: fragments, as: UTF8.self)
                        fragments.removeAll()
                        handler?(.text(text))
                    }
                case .ping:
                    connection.send(content: WebSocket.encode(.pong, frame.payload), completion: .contentProcessed { _ in })
                case .close:
                    connection.send(content: WebSocket.encode(.close, Data()),
                                    completion: .contentProcessed { [weak self] _ in self?.close() })
                    return
                case .binary, .pong:
                    break
                }
            }
        }
    }
}
