import AppKit

/// What the Now playing strip shows.
struct NowPlaying: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var artworkURL: String = ""
    var isPlaying: Bool = false
    /// Playback position captured at `positionStamp` (seconds).
    var position: Double = 0
    var duration: Double = 0
    var positionStamp: Double = 0

    var isEmpty: Bool { title.isEmpty && artist.isEmpty }

    /// Position extrapolated to now, so the progress bar moves smoothly
    /// between the sparse updates the player gives us.
    func livePosition(now: Double = Date().timeIntervalSince1970) -> Double {
        guard duration > 0 else { return 0 }
        guard isPlaying, positionStamp > 0 else { return min(position, duration) }
        return min(max(position + (now - positionStamp), 0), duration)
    }

    var progress: Double { duration > 0 ? livePosition() / duration : 0 }
}

/// Turns the AppleScript reply into a state. Pure, so it is unit-tested.
enum SpotifyParser {
    enum Result: Equatable {
        case notRunning
        case stopped
        case track(NowPlaying)
    }

    static let separator = "|||"

    /// `output` is what `SpotifyService.pollScript` returns:
    /// title ||| artist ||| album ||| artwork url ||| duration (ms) ||| position (s) ||| state
    static func parse(_ output: String?, now: Double = Date().timeIntervalSince1970) -> Result {
        guard let output, !output.isEmpty, output != "NOT_RUNNING" else { return .notRunning }
        if output == "STOPPED" { return .stopped }
        let parts = output.components(separatedBy: separator)
        guard parts.count >= 7 else { return .stopped }
        return .track(NowPlaying(
            title: parts[0],
            artist: parts[1],
            album: parts[2],
            artworkURL: parts[3],
            isPlaying: parts[6].trimmingCharacters(in: .whitespaces) == "playing",
            position: number(parts[5]) ?? 0,
            // Spotify reports the track length in milliseconds and the position in seconds.
            duration: (number(parts[4]) ?? 0) / 1000,
            positionStamp: now))
    }

    /// AppleScript formats reals with the system locale, so "12,5" is as likely as "12.5".
    static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
}

/// Reads Spotify's "now playing" and drives it, through AppleScript only: no Web API, no keys,
/// no login. Same approach as the author's BarDeck.
///
/// The first call makes macOS ask once for permission to control Spotify (Automation).
@MainActor
final class SpotifyService {

    nonisolated static let bundleID = "com.spotify.client"

    private(set) var nowPlaying = NowPlaying()
    var onChange: ((NowPlaying) -> Void)?

    private let queue = DispatchQueue(label: "SecondPad.spotify", qos: .userInitiated)
    private var timer: Timer?
    private var polling = false
    private var observers: [NSObjectProtocol] = []
    /// Demo mode feeds a made-up track instead of asking Spotify.
    var isDemo = false

    /// `if application … is running` never launches Spotify, unlike a bare `tell`.
    static let pollScript = """
    if application "Spotify" is running then
        tell application "Spotify"
            if player state is stopped then return "STOPPED"
            set t to current track
            return (name of t) & "|||" & (artist of t) & "|||" & (album of t) & "|||" & (artwork url of t) & "|||" & ((duration of t) as string) & "|||" & ((player position) as string) & "|||" & ((player state) as string)
        end tell
    else
        return "NOT_RUNNING"
    end if
    """

    func start() {
        guard !isDemo else { return }
        // Spotify announces every play, pause and track change; the timer only keeps the
        // position honest (and catches anything the notification misses).
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            })
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.bundleID else { return }
            MainActor.assumeIsolated { self?.publish(NowPlaying()) }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.5
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach {
            DistributedNotificationCenter.default().removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func poll() {
        guard !isDemo, !polling else { return }
        guard isRunning else {
            if !nowPlaying.isEmpty { publish(NowPlaying()) }
            return
        }
        polling = true
        let script = Self.pollScript
        queue.async { [weak self] in
            let output = Self.run(script)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.polling = false
                    switch SpotifyParser.parse(output) {
                    case .track(let track): self.publish(track)
                    case .stopped, .notRunning: self.publish(NowPlaying())
                    }
                }
            }
        }
    }

    // MARK: - Cover art

    /// The current cover, downloaded by the Mac so the tablet needs no internet of its own.
    private(set) var artwork: Data?
    private(set) var artworkVersion = 0
    private var artworkFor = ""

    /// Only Spotify's own image hosts, only https.
    nonisolated static func isAllowedArtwork(_ text: String) -> Bool {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "i.scdn.co" || host.hasSuffix(".scdn.co") || host.hasSuffix(".spotifycdn.com")
    }

    private func loadArtwork(for track: NowPlaying) {
        guard track.artworkURL != artworkFor else { return }
        artworkFor = track.artworkURL
        guard Self.isAllowedArtwork(track.artworkURL), let url = URL(string: track.artworkURL) else {
            artwork = nil
            artworkVersion += 1
            onChange?(nowPlaying)
            return
        }
        let wanted = track.artworkURL
        Task {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.cachePolicy = .returnCacheDataElseLoad
            let data = try? await URLSession.shared.data(for: request).0
            guard self.artworkFor == wanted else { return }
            // A cover is a small JPEG; anything huge or not an image is ignored.
            if let data, data.count < 2_000_000, data.starts(with: [0xFF, 0xD8]) || data.starts(with: [0x89, 0x50]) {
                self.artwork = data
            } else {
                self.artwork = nil
            }
            self.artworkVersion += 1
            self.onChange?(self.nowPlaying)
        }
    }

    /// Demo mode: a cover drawn in code.
    func setDemo(_ track: NowPlaying, artwork: Data?) {
        nowPlaying = track
        self.artwork = artwork
        artworkVersion += 1
        onChange?(track)
    }

    func publish(_ track: NowPlaying) {
        loadArtwork(for: track)
        // Only a real change is pushed: the position stamp moves on every poll.
        var a = track, b = nowPlaying
        a.position = 0; a.positionStamp = 0; b.position = 0; b.positionStamp = 0
        let jumped = abs(track.livePosition() - nowPlaying.livePosition()) > 1.5
        nowPlaying = track
        if a != b || jumped { onChange?(track) }
    }

    // MARK: - Controls

    enum Action: String {
        case playPause = "playpause"
        case next = "next track"
        case previous = "previous track"
    }

    /// Every control goes to Spotify only (AppleScript addressed to Spotify; never the system's
    /// media keys, so YouTube, Music or anything else playing is never touched).
    /// With Spotify closed: play opens it and starts playing; previous / next do nothing.
    func perform(_ action: Action) {
        guard !isDemo else { return }
        guard isRunning else {
            if action == .playPause { launchAndPlay() }
            return
        }
        let script = Self.script(for: action)
        queue.async { [weak self] in
            _ = Self.run(script)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.poll() } }
        }
    }

    /// The only AppleScript a control ever runs. Pure, unit-tested.
    nonisolated static func script(for action: Action) -> String {
        "tell application \"Spotify\" to \(action.rawValue)"
    }

    /// Opens Spotify, waits until it is running (up to 10 s), then plays.
    private func launchAndPlay() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.playWhenReady(triesLeft: 20) }
            }
        }
    }

    private func playWhenReady(triesLeft: Int) {
        guard triesLeft > 0 else { return }
        guard isRunning else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self.playWhenReady(triesLeft: triesLeft - 1) } }
            return
        }
        queue.async { [weak self] in
            // Spotify needs a moment after launch before it accepts "play".
            usleep(1_200_000)
            _ = Self.run("tell application \"Spotify\" to play")
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.poll() } }
        }
    }

    nonisolated private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return result?.stringValue
    }
}
