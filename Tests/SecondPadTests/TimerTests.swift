import Foundation
import Testing
@testable import SecondPad

private func scratch(_ name: String) -> UserDefaults { TestDefaults.make(name) }

@Suite("Quick timer", .serialized)
struct QuickTimerTests {

    @Test func clampsAndRuns() {
        let timer = QuickTimer(defaults: scratch("quick1"))
        #expect(timer.minutes == 10)
        timer.setMinutes(0)
        #expect(timer.minutes == 1)
        timer.setMinutes(99)
        #expect(timer.minutes == 60)
        let now = Date()
        timer.start(minutes: 5, now: now)
        #expect(timer.isRunning)
        #expect(abs(timer.remaining(now: now) - 300) < 0.01)
        let message = timer.message(now: now.addingTimeInterval(60))
        #expect(message.running && abs(message.remainingMs - 240_000) < 10 && message.totalMs == 300_000)
        timer.stop()
        #expect(!timer.isRunning)
        #expect(timer.message().remainingMs == 0)
    }

    @Test func survivesARestart() {
        let defaults = scratch("quick2")
        let now = Date()
        QuickTimer(defaults: defaults).start(minutes: 15, now: now)
        let again = QuickTimer(defaults: defaults, now: now.addingTimeInterval(60))
        #expect(again.isRunning)
        #expect(again.minutes == 15)
        // Ended while the app was closed: not running.
        let later = QuickTimer(defaults: defaults, now: now.addingTimeInterval(16 * 60))
        #expect(!later.isRunning)
    }

    @Test func finishChimesOnceAndTellsTheTablet() {
        let timer = QuickTimer(defaults: scratch("quick3"))
        var chimes = 0, finishes = 0, changes = 0
        timer.chime = { chimes += 1 }
        timer.onFinish = { finishes += 1 }
        timer.onChange = { changes += 1 }
        let start = Date()
        timer.start(minutes: 1, now: start)
        timer.finishIfDue(now: start.addingTimeInterval(30))
        #expect(timer.isRunning && finishes == 0)
        timer.finishIfDue(now: start.addingTimeInterval(61))
        timer.finishIfDue(now: start.addingTimeInterval(62))
        #expect(!timer.isRunning)
        #expect(chimes == 1 && finishes == 1)
        timer.soundOnMac = false
        timer.start(minutes: 1, now: start)
        timer.finishIfDue(now: start.addingTimeInterval(61))
        #expect(chimes == 1 && finishes == 2)
        #expect(changes > 0)
    }
}

/// A clock the test moves by hand.
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@Suite("Pomodoro", .serialized)
struct PomodoroTests {

    private func make(_ name: String, clock: TestClock) -> PomodoroTimer {
        let defaults = scratch(name)
        defaults.set(25, forKey: "pomodoro.focus")
        return PomodoroTimer(history: PomodoroHistory(fileURL: nil), defaults: defaults, clock: { clock.now })
    }

    @Test func focusEndsInAPromptNotAnAutoStart() {
        let clock = TestClock()
        let p = make("p1", clock: clock)
        var prompts: [PomodoroTimer.Prompt?] = []
        p.onPrompt = { prompts.append($0) }
        p.start()
        #expect(p.phase == .focus && p.running)
        clock.advance(25 * 60)
        p.tick()
        #expect(p.phase == .breakTime && !p.running)
        #expect(p.prompt == .startBreak && prompts.last == .startBreak)
        #expect(p.completed == 1)
        #expect(p.todayLog.count == 1 && p.todayLog[0].completed)
        p.answer(true)
        #expect(p.phase == .breakTime && p.running && p.prompt == nil)
        clock.advance(5 * 60)
        p.tick()
        #expect(p.prompt == .startFocus)
        p.answer(false)   // "Not now": back to Ready
        #expect(p.phase == .idle && !p.running)
        p.reset()
    }

    @Test func fourthFocusEarnsALongBreakAndSkipStartsFocus() {
        let clock = TestClock()
        let p = make("p2", clock: clock)
        for round in 1...4 {
            if round == 1 { p.start() } else { p.answer(false) }   // Skip the break
            clock.advance(25 * 60)
            p.tick()
        }
        #expect(p.prompt == .startLongBreak)
        #expect(p.phase == .longBreak)
        #expect(p.completed == 4)
        #expect(p.message.prompt == "longBreak")
        p.reset()
    }

    @Test func resetHalfWayDoesNotCount() {
        let clock = TestClock()
        let p = make("p3", clock: clock)
        p.start()
        clock.advance(10 * 60)
        p.tick()
        p.reset()
        #expect(p.completed == 0)
        #expect(p.todayLog.count == 1 && !p.todayLog[0].completed)
        #expect(p.phase == .idle)
    }

    @Test func pausesCountAndSleepPausesWithoutCounting() {
        let clock = TestClock()
        let p = make("p4", clock: clock)
        p.start()
        clock.advance(60)
        p.pause()
        #expect(p.interruptionsThisFocus == 1 && !p.running)
        clock.advance(600)   // paused time doesn't run down
        #expect(p.message.remaining == 24 * 60)
        p.start()
        p.macWentAway()
        #expect(!p.running && p.autoPaused)
        #expect(p.interruptionsThisFocus == 1)
        p.reset()
    }

    @Test func distractionsVisitsAndBreaks() {
        let clock = TestClock()
        let p = make("p5", clock: clock)
        p.noteSwitch(app: "Telegram", bundleID: "ru.keepcoder.Telegram", category: .chat)   // ignored: not focusing
        p.start()
        p.noteSwitch(app: "Xcode", bundleID: nil, category: .code)
        p.noteSwitch(app: "Telegram", bundleID: "ru.keepcoder.Telegram", category: .chat)
        clock.advance(30)
        p.noteSwitch(app: "Instagram", bundleID: "web.instagram", category: .social)   // same slip, 2nd visit
        clock.advance(20)
        p.noteSwitch(app: "Xcode", bundleID: nil, category: .code)
        clock.advance(70)
        p.noteSwitch(app: "Telegram", bundleID: "ru.keepcoder.Telegram", category: .chat)
        p.tick()
        let live = p.message.live
        #expect(live?.focusBreaks == 2)
        #expect(live?.distractedNow == "Telegram")
        #expect(live?.distractedNowBundleId == "ru.keepcoder.Telegram")
        #expect(live?.distractions.first?.app == "Telegram")
        #expect(live?.distractions.first?.visits == 2)
        #expect(live?.distractions.first { $0.app == "Instagram" }?.seconds == 20)
        // Minute strip: minute 0 had a slip, minute 1 (in Xcode, then Telegram at its end) too.
        #expect(live?.minutes == [true, true] || live?.minutes == [true])
        p.reset()
    }

    @Test func purityFromTheTracker() {
        let clock = TestClock()
        let p = make("p6", clock: clock)
        p.usageProvider = { _, _ in
            [.init(app: "Xcode", category: .code, seconds: 900), .init(app: "YouTube", category: .video, seconds: 100)]
        }
        p.start()
        #expect(p.message.live?.purity == 90)
        clock.advance(25 * 60)
        p.tick()
        #expect(p.todayLog.last?.purity == 90)
        p.reset()
    }

    @Test func newDayStartsTheCountAgainAndTheWeekKeepsIt() {
        let clock = TestClock()
        let p = make("p7", clock: clock)
        p.start()
        clock.advance(25 * 60)
        p.tick()
        #expect(p.completed == 1)
        let week = p.history.week(now: clock.now)
        #expect(week.count == 7)
        #expect(week.last?.focusSeconds == 25 * 60)
        clock.advance(86_400)
        p.checkDay()
        #expect(p.completed == 0 && p.todayLog.isEmpty)
        #expect(p.history.week(now: clock.now).dropLast().last?.focusSeconds == 25 * 60)
        p.reset()
    }
}
