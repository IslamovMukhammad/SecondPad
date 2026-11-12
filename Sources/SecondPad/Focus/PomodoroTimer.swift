import AppKit

/// Live state of the running focus period, for the Deep Focus page.
nonisolated struct FocusLive: Encodable, Equatable, Sendable {
    let elapsedSeconds: Int
    let focusBreaks: Int
    let purity: Int
    let onTaskSeconds: Int
    let distractions: [FocusDistraction]
    /// In a distracting app right now: the tablet says "You're in …" at once.
    let distractedNow: String?
    let distractedNowBundleId: String?
    let minutes: [Bool]
    let currentMinuteDistracted: Bool
}

nonisolated struct PomodoroMessage: Encodable, Equatable, Sendable {
    let type = "pomodoro"
    /// idle | focus | break | longBreak
    let phase: String
    let running: Bool
    let remaining: Int
    let total: Int
    /// Pomodoros finished today.
    let completed: Int
    let completedSinceLongBreak: Int
    let longBreakEvery: Int
    let interruptionsThisFocus: Int
    let todayLog: [PomodoroLogEntry]
    let breakMinutes: Int
    let focusMinutes: Int
    let live: FocusLive?
    /// A period ended and waits for an answer: "break" | "longBreak" | "focus".
    let prompt: String?
    /// Focus paused itself because the Mac slept or locked.
    let autoPaused: Bool

    private enum CodingKeys: String, CodingKey {
        case type, phase, running, remaining, total, completed, completedSinceLongBreak, longBreakEvery,
             interruptionsThisFocus, todayLog, breakMinutes, focusMinutes, live, prompt, autoPaused
    }
}

/// The Pomodoro, started and stopped on the Mac (the tablet shows it and answers the prompt).
///
/// Classic rules: a long break after every 4 finished focus periods; a focus period reset half-way
/// doesn't count ("a pomodoro is indivisible"); a manual pause counts as an interruption; today's
/// count starts over every day. Time follows the wall clock (`endsAt`), not ticks, so sleep
/// can't skew it. Focus pauses itself when the Mac sleeps, its screen sleeps or it locks (you're
/// not at the desk); a break keeps running. When a period ends nothing starts by itself: a sound
/// plays and the Mac and the tablet ask.
final class PomodoroTimer {

    enum Phase: String { case idle, focus, breakTime = "break", longBreak }
    enum Prompt: String { case startBreak = "break", startLongBreak = "longBreak", startFocus = "focus" }

    nonisolated static let longBreakEvery = 4

    var focusMinutes: Int { didSet { defaults.set(focusMinutes, forKey: "pomodoro.focus"); if phase == .idle { remaining = focusDuration }; publish() } }
    var breakMinutes: Int { didSet { defaults.set(breakMinutes, forKey: "pomodoro.break"); publish() } }
    var longBreakMinutes: Int { didSet { defaults.set(longBreakMinutes, forKey: "pomodoro.longBreak"); publish() } }

    private(set) var phase: Phase = .idle
    private(set) var running = false
    private(set) var remaining: Int
    private(set) var completed = 0
    private(set) var completedSinceLongBreak = 0
    private(set) var interruptionsThisFocus = 0
    private(set) var todayLog: [PomodoroLogEntry] = []
    private(set) var prompt: Prompt?
    private(set) var autoPaused = false

    var onChange: (() -> Void)?
    /// A prompt appeared (or was re-sent as a reminder) or went away.
    var onPrompt: ((Prompt?) -> Void)?
    /// The focus tracker turns on and off with this (a pause stops it, resuming continues).
    var onFocusRunning: ((Bool) -> Void)?
    /// A new focus period: the tracker starts a fresh ledger.
    var onFocusBegin: (() -> Void)?
    /// Seconds per app in [start, end], from the focus tracker.
    var usageProvider: ((Date, Date) -> [FocusLedger.Usage])?

    let history: PomodoroHistory
    private let defaults: UserDefaults
    private let clock: () -> Date
    private var timer: Timer?
    private var reminder: Timer?
    private var remindersLeft = 0
    private var endsAt: Date?
    private var focusStartedAt: Date?
    private var lastDay: String
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private struct Tally { var bundleID: String?; var category: ActivityCategory; var visits = 0; var seconds: Double = 0 }
    private var tallies: [String: Tally] = [:]
    private var focusBreaks = 0
    private var currentDistraction: (app: String, since: Date)?
    private var lastSwitchWasDistraction = false
    private var minuteMarks: [Bool] = []
    private var distractedThisMinute = false

    var focusDuration: Int { focusMinutes * 60 }
    var breakDuration: Int { breakMinutes * 60 }
    var longBreakDuration: Int { longBreakMinutes * 60 }

    init(history: PomodoroHistory, defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init) {
        self.history = history
        self.defaults = defaults
        self.clock = clock
        focusMinutes = defaults.object(forKey: "pomodoro.focus") as? Int ?? 25
        breakMinutes = defaults.object(forKey: "pomodoro.break") as? Int ?? 5
        longBreakMinutes = defaults.object(forKey: "pomodoro.longBreak") as? Int ?? 20
        remaining = (defaults.object(forKey: "pomodoro.focus") as? Int ?? 25) * 60
        lastDay = PomodoroHistory.dayKey(clock())
        let restored = history.today(now: clock())
        todayLog = restored.entries
        completed = restored.entries.filter(\.completed).count
        completedSinceLongBreak = min(restored.completedSinceLongBreak, Self.longBreakEvery - 1)
    }

    /// Reads today's log again (the demo writes it after start).
    func reloadToday() {
        let restored = history.today(now: clock())
        todayLog = restored.entries
        completed = restored.entries.filter(\.completed).count
        completedSinceLongBreak = min(restored.completedSinceLongBreak, Self.longBreakEvery - 1)
        publish()
    }

    // MARK: - Sleep and lock

    func watchSleep() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let away: @Sendable (Notification) -> Void = { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.macWentAway() } } }
        let back: @Sendable (Notification) -> Void = { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.macCameBack() } } }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main, using: away)))
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main, using: back)))
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observers.append((distributed, distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main, using: away)))
        }
        for name in ["com.apple.screenIsUnlocked", "com.apple.screensaver.didstop"] {
            observers.append((distributed, distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main, using: back)))
        }
    }

    func macWentAway() {
        guard phase == .focus, running else { return }
        pause(automatic: true)
    }

    /// Focus doesn't resume by itself; a break that ended during sleep asks now.
    private func macCameBack() {
        if running { tick() }
    }

    // MARK: - Message

    var message: PomodoroMessage {
        PomodoroMessage(phase: phase.rawValue, running: running, remaining: currentRemaining, total: currentTotal,
                        completed: completed, completedSinceLongBreak: completedSinceLongBreak,
                        longBreakEvery: Self.longBreakEvery, interruptionsThisFocus: interruptionsThisFocus,
                        todayLog: todayLog, breakMinutes: breakMinutes, focusMinutes: focusMinutes, live: liveFocus,
                        prompt: prompt?.rawValue, autoPaused: autoPaused)
    }

    private var liveFocus: FocusLive? {
        guard phase == .focus, let start = focusStartedAt else { return nil }
        let now = clock()
        let (purity, onTask) = FocusLedger.purity(of: usageProvider?(start, now) ?? [])
        return FocusLive(elapsedSeconds: max(0, focusDuration - currentRemaining), focusBreaks: focusBreaks,
                         purity: purity, onTaskSeconds: onTask, distractions: distractionRows(now: now),
                         distractedNow: currentDistraction?.app,
                         distractedNowBundleId: currentDistraction.flatMap { tallies[$0.app]?.bundleID },
                         minutes: minuteMarks, currentMinuteDistracted: distractedThisMinute)
    }

    private func distractionRows(now: Date) -> [FocusDistraction] {
        tallies.map { app, tally in
            var seconds = tally.seconds
            if let current = currentDistraction, current.app == app { seconds += now.timeIntervalSince(current.since) }
            return FocusDistraction(app: app, bundleId: tally.bundleID, category: tally.category.rawValue,
                                    colorHex: tally.category.colorHex, visits: tally.visits, seconds: Int(seconds))
        }
        .sorted { $0.visits != $1.visits ? $0.visits > $1.visits : ($0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.app < $1.app) }
    }

    // MARK: - Distractions

    /// Every real app change while focusing. A visit to a distracting app counts for that app;
    /// moving from work (or neutral) into a distraction is one focus break (Telegram → Instagram is
    /// one break, two visits).
    func noteSwitch(app: String, bundleID: String?, category: ActivityCategory) {
        guard phase == .focus, running else { return }
        let now = clock()
        closeDistraction(at: now)
        let isDistraction = ActivityCategory.distraction.contains(category)
        if isDistraction {
            var tally = tallies[app] ?? Tally(bundleID: bundleID, category: category)
            tally.visits += 1
            tallies[app] = tally
            if !lastSwitchWasDistraction { focusBreaks += 1 }
            currentDistraction = (app, now)
            distractedThisMinute = true
        }
        lastSwitchWasDistraction = isDistraction
        publish()
    }

    private func closeDistraction(at now: Date) {
        guard let current = currentDistraction else { return }
        tallies[current.app]?.seconds += now.timeIntervalSince(current.since)
        currentDistraction = nil
    }

    private var currentTotal: Int {
        switch phase {
        case .idle, .focus: focusDuration
        case .breakTime: breakDuration
        case .longBreak: longBreakDuration
        }
    }

    // MARK: - Control (Mac only)

    func start() {
        rollDayIfNeeded()
        if prompt != nil { answer(true); return }
        if phase == .idle { beginFocus() }
        autoPaused = false
        run()
        publish()
    }

    func pause() { pause(automatic: false) }

    private func pause(automatic: Bool) {
        guard running else { return }
        remaining = currentRemaining
        running = false
        endsAt = nil
        timer?.invalidate(); timer = nil
        if phase == .focus {
            if !automatic { interruptionsThisFocus += 1 }
            closeDistraction(at: clock())
            onFocusRunning?(false)
        }
        autoPaused = automatic
        publish()
    }

    func toggle() { running ? pause() : start() }

    /// Cancels the period. A focus period reset half-way is logged as not completed.
    func reset() {
        if phase == .focus, let started = focusStartedAt { logFocusEnd(completedNaturally: false, start: started) }
        running = false
        endsAt = nil
        timer?.invalidate(); timer = nil
        phase = .idle
        remaining = focusDuration
        interruptionsThisFocus = 0
        focusStartedAt = nil
        autoPaused = false
        onFocusRunning?(false)
        setPrompt(nil)
        publish()
    }

    /// yes: start the break / the focus. no: skip the break (focus at once) / not now (back to Ready).
    func answer(_ yes: Bool) {
        guard let asked = prompt else { return }
        setPrompt(nil)
        switch (asked, yes) {
        case (.startBreak, true), (.startLongBreak, true):
            remaining = currentTotal
            run()
        case (.startBreak, false), (.startLongBreak, false), (.startFocus, true):
            beginFocus()
            run()
        case (.startFocus, false):
            reset()
            return
        }
        publish()
    }

    // MARK: - Inside

    private func run() {
        running = true
        endsAt = clock().addingTimeInterval(TimeInterval(remaining))
        if phase == .focus { onFocusRunning?(true) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.2
    }

    private var currentRemaining: Int {
        guard running, let endsAt else { return remaining }
        return max(0, Int(endsAt.timeIntervalSince(clock()).rounded(.up)))
    }

    /// Called every second by the timer (and by tests).
    func tick() {
        guard running else { return }
        rollDayIfNeeded()
        remaining = currentRemaining
        if phase == .focus {
            let elapsedMinutes = (focusDuration - remaining) / 60
            while minuteMarks.count < elapsedMinutes {
                minuteMarks.append(distractedThisMinute)
                distractedThisMinute = currentDistraction != nil
            }
        }
        if remaining <= 0 { finishPhase() }
        publish()
    }

    private func finishPhase() {
        running = false
        endsAt = nil
        timer?.invalidate(); timer = nil
        if phase == .focus {
            if let started = focusStartedAt { logFocusEnd(completedNaturally: true, start: started) }
            onFocusRunning?(false)
            completed += 1
            completedSinceLongBreak += 1
            if completedSinceLongBreak >= Self.longBreakEvery {
                phase = .longBreak
                remaining = longBreakDuration
                completedSinceLongBreak = 0
                setPrompt(.startLongBreak)
            } else {
                phase = .breakTime
                remaining = breakDuration
                setPrompt(.startBreak)
            }
        } else {
            remaining = 0
            setPrompt(.startFocus)
        }
    }

    /// A prompt plays a sound and is reminded every 3 minutes, at most twice.
    private func setPrompt(_ value: Prompt?) {
        guard value != prompt else { return }
        prompt = value
        reminder?.invalidate(); reminder = nil
        onPrompt?(value)
        guard value != nil else { return }
        remindersLeft = 2
        reminder = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let current = self.prompt, self.remindersLeft > 0 else { self?.reminder?.invalidate(); return }
                self.remindersLeft -= 1
                self.onPrompt?(current)
            }
        }
    }

    private func beginFocus() {
        autoPaused = false
        phase = .focus
        remaining = focusDuration
        interruptionsThisFocus = 0
        focusStartedAt = clock()
        tallies.removeAll()
        focusBreaks = 0
        currentDistraction = nil
        lastSwitchWasDistraction = false
        minuteMarks.removeAll()
        distractedThisMinute = false
        onFocusBegin?()
    }

    private func logFocusEnd(completedNaturally: Bool, start: Date) {
        let end = clock()
        let (purity, _) = FocusLedger.purity(of: usageProvider?(start, end) ?? [])
        closeDistraction(at: end)
        let entry = PomodoroLogEntry(index: todayLog.count + 1, completed: completedNaturally,
                                     interruptions: interruptionsThisFocus,
                                     durationSeconds: max(0, Int(end.timeIntervalSince(start))), purity: purity,
                                     focusBreaks: focusBreaks, distractions: distractionRows(now: end),
                                     minutes: minuteMarks, endedAt: end.timeIntervalSince1970)
        todayLog.append(entry)
        history.save(today: todayLog, completedSinceLongBreak: completedSinceLongBreak + (completedNaturally ? 1 : 0), now: end)
        focusStartedAt = nil
    }

    private func rollDayIfNeeded() {
        let today = PomodoroHistory.dayKey(clock())
        guard today != lastDay else { return }
        lastDay = today
        completed = 0
        completedSinceLongBreak = 0
        todayLog.removeAll()
    }

    /// The day changed while nothing ran (called by the model every minute).
    func checkDay() {
        let before = lastDay
        rollDayIfNeeded()
        if before != lastDay { publish() }
    }

    private func publish() { onChange?() }
}
