import AppKit

/// The Quick timer. It lives on the Mac, so the tablet and the menu bar show and drive the same
/// one: set it anywhere, it's the same everywhere. It survives an app restart.
///
/// The tablet gets the *remaining* milliseconds, not the end time: the tablet's clock may be a
/// few seconds off the Mac's, the remaining time is right either way.
final class QuickTimer {

    nonisolated static let minMinutes = 1
    nonisolated static let maxMinutes = 60
    nonisolated static let presets = [5, 10, 15, 20]

    private(set) var minutes: Int
    private(set) var endsAt: Date?
    private(set) var totalSeconds: TimeInterval = 0
    var soundOnMac: Bool { didSet { defaults.set(soundOnMac, forKey: Keys.soundMac); publish() } }
    var soundOnTablet: Bool { didSet { defaults.set(soundOnTablet, forKey: Keys.soundTablet); publish() } }

    /// State changed (tablet + menu).
    var onChange: (() -> Void)?
    /// It ran out (not stopped by hand).
    var onFinish: (() -> Void)?
    /// Plays the Mac chime; tests replace it.
    var chime: () -> Void = { QuickTimer.playChime() }

    private let defaults: UserDefaults
    private var finishWork: DispatchWorkItem?
    private var watchdog: Timer?

    private enum Keys {
        static let minutes = "quickTimer.minutes"
        static let endsAt = "quickTimer.endsAt"
        static let total = "quickTimer.total"
        static let soundMac = "quickTimer.soundMac"
        static let soundTablet = "quickTimer.soundTablet"
    }

    var isRunning: Bool { endsAt != nil }

    func remaining(now: Date = Date()) -> TimeInterval { max(0, (endsAt?.timeIntervalSince(now) ?? 0)) }

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        let saved = defaults.integer(forKey: Keys.minutes)
        minutes = saved == 0 ? 10 : Self.clamp(saved)
        soundOnMac = defaults.object(forKey: Keys.soundMac) as? Bool ?? true
        soundOnTablet = defaults.object(forKey: Keys.soundTablet) as? Bool ?? true
        let end = defaults.double(forKey: Keys.endsAt)
        if end > now.timeIntervalSince1970 {
            endsAt = Date(timeIntervalSince1970: end)
            totalSeconds = defaults.double(forKey: Keys.total)
            scheduleFinish()
        }
    }

    // MARK: - Control (tablet and menu)

    func setMinutes(_ value: Int) {
        minutes = Self.clamp(value)
        defaults.set(minutes, forKey: Keys.minutes)
        publish()
    }

    func start(minutes value: Int? = nil, now: Date = Date()) {
        if let value { minutes = Self.clamp(value); defaults.set(minutes, forKey: Keys.minutes) }
        totalSeconds = TimeInterval(minutes * 60)
        endsAt = now.addingTimeInterval(totalSeconds)
        persist()
        scheduleFinish()
        publish()
    }

    func stop() {
        finishWork?.cancel()
        watchdog?.invalidate(); watchdog = nil
        endsAt = nil
        totalSeconds = 0
        persist()
        publish()
    }

    struct Message: Encodable {
        let type = "quicktimer"
        let minutes: Int
        let running: Bool
        let remainingMs: Double
        let totalMs: Double
        let soundTablet: Bool
        private enum CodingKeys: String, CodingKey { case type, minutes, running, remainingMs, totalMs, soundTablet }
    }

    func message(now: Date = Date()) -> Message {
        Message(minutes: minutes, running: isRunning, remainingMs: remaining(now: now) * 1000,
                totalMs: totalSeconds * 1000, soundTablet: soundOnTablet)
    }

    nonisolated static func clamp(_ value: Int) -> Int { max(minMinutes, min(maxMinutes, value)) }

    // MARK: - Finishing

    /// Two ways to notice the end: a work item at the exact time, and a 1 s watchdog in case the
    /// work item woke early (sleep, clock change) and would otherwise leave it stuck at 00:00.
    private func scheduleFinish() {
        finishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.finishIfDue() } }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining(), execute: work)
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishIfDue() }
        }
        watchdog?.tolerance = 0.3
    }

    func finishIfDue(now: Date = Date()) {
        guard isRunning else { return }
        if remaining(now: now) > 0.05 { return }
        finishWork?.cancel()
        watchdog?.invalidate(); watchdog = nil
        endsAt = nil
        totalSeconds = 0
        persist()
        publish()
        if soundOnMac { chime() }
        onFinish?()
    }

    private func publish() { onChange?() }

    private func persist() {
        defaults.set(endsAt?.timeIntervalSince1970 ?? 0, forKey: Keys.endsAt)
        defaults.set(totalSeconds, forKey: Keys.total)
    }

    /// Three times, in step with the tablet's three green flashes.
    static func playChime() {
        for delay in [0.0, 0.52, 1.04] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { NSSound(named: "Glass")?.play() }
        }
    }
}
