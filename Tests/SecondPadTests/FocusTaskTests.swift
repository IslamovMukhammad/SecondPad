import Foundation
import Testing
@testable import SecondPad

@Suite("Focus tracking")
struct FocusTrackingTests {

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func ledgerCountsTimePerAppInsideTheWindow() {
        var ledger = FocusLedger()
        ledger.begin(app: "Xcode", category: .code, at: t0)
        ledger.begin(app: "YouTube", category: .video, at: t0.addingTimeInterval(600))
        ledger.begin(app: "Xcode", category: .code, at: t0.addingTimeInterval(660))
        let usage = ledger.usage(from: t0, to: t0.addingTimeInterval(900))
        #expect(usage.first { $0.app == "Xcode" }?.seconds == 840)
        #expect(usage.first { $0.app == "YouTube" }?.seconds == 60)
        // Only the overlap with the window counts.
        #expect(ledger.usage(from: t0.addingTimeInterval(630), to: t0.addingTimeInterval(700)).first { $0.app == "YouTube" }?.seconds == 30)
        #expect(FocusLedger.purity(of: usage).percent == 93)
        #expect(FocusLedger.purity(of: []).percent == 100)
        ledger.reset()
        #expect(ledger.usage(from: t0, to: t0.addingTimeInterval(900)).isEmpty)
    }

    @Test func awayAndReadingAreNeutral() {
        let usage: [FocusLedger.Usage] = [.init(app: "Xcode", category: .code, seconds: 600),
                                          .init(app: "Away", category: .afk, seconds: 600)]
        #expect(FocusLedger.purity(of: usage).percent == 50)   // away time isn't on task
        #expect(!ActivityCategory.distraction.contains(.afk))
        #expect(!ActivityCategory.distraction.contains(.reading))
    }

    @Test func categories() {
        #expect(CategoryRules.category(bundleID: "com.apple.dt.Xcode") == .code)
        #expect(CategoryRules.category(bundleID: "ru.keepcoder.Telegram") == .chat)
        #expect(CategoryRules.category(bundleID: "com.example.unknown") == .other)
        #expect(CategoryRules.category(bundleID: nil) == .other)
        #expect(CategoryRules.category(domain: "youtube.com") == .video)
        #expect(CategoryRules.category(domain: "m.youtube.com") == .video)
        #expect(CategoryRules.category(domain: "github.com") == .code)
        #expect(CategoryRules.category(domain: "notyoutube.com") == .reading)
        #expect(CategoryRules.category(domain: "docs.example.org") == .reading)
        #expect(CategoryRules.category(domain: nil) == .other)
        #expect(CategoryRules.platform(domain: "www.instagram.com")?.name == "Instagram")
        #expect(CategoryRules.domain(fromURL: "https://www.youtube.com/watch?v=abc") == "youtube.com")
        #expect(CategoryRules.domain(fromURL: "chrome://newtab/") == "newtab")
        #expect(CategoryRules.domain(fromURL: "not a url") == nil)
    }

    @Test func awayRule() {
        #expect(CategoryRules.isAway(locked: true, idle: 0, mediaActive: false, claudeWorking: false, readingContext: false))
        #expect(!CategoryRules.isAway(locked: false, idle: 60, mediaActive: false, claudeWorking: false, readingContext: false))
        #expect(CategoryRules.isAway(locked: false, idle: 180, mediaActive: false, claudeWorking: false, readingContext: false))
        #expect(!CategoryRules.isAway(locked: false, idle: 180, mediaActive: true, claudeWorking: false, readingContext: false))
        #expect(!CategoryRules.isAway(locked: false, idle: 240, mediaActive: false, claudeWorking: true, readingContext: false))
        #expect(!CategoryRules.isAway(locked: false, idle: 500, mediaActive: false, claudeWorking: false, readingContext: true))
        #expect(CategoryRules.isAway(locked: false, idle: 700, mediaActive: false, claudeWorking: false, readingContext: true))
    }
}

@Suite("Daily tasks")
struct TaskTests {

    final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    @Test func addTickAndOrder() {
        let clock = Clock()
        let store = TaskStore(fileURL: nil, clock: { clock.now })
        #expect(store.add("   ") == nil)
        let a = store.add("  First\nline  ")!
        clock.now += 1
        let b = store.add("Second")!
        #expect(a.text == "First line")
        store.toggle(a.id)
        #expect(store.today.map(\.id) == [b.id, a.id])   // open first, done below
        #expect(store.today.last?.doneAt != nil)
        store.toggle(a.id)
        #expect(store.today.map(\.id) == [a.id, b.id])
        #expect(store.add(String(repeating: "x", count: 500))?.text.count == TaskStore.maxLength)
        store.delete(b.id)
        #expect(!store.today.contains { $0.id == b.id })
        store.toggle("no-such-id")
    }

    @Test func newDayCarriesOpenTasksAndArchivesDoneOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sp-tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let store = TaskStore(fileURL: nil, clock: { clock.now })
        let open = store.add("Still to do")!
        let done = store.add("Finished")!
        store.toggle(done.id)
        let yesterday = store.todayKey
        clock.now += 86_400
        #expect(store.rollIfNeeded())
        #expect(store.today.map(\.id) == [open.id])
        #expect(store.stored.days[yesterday]?.map(\.id) == [done.id])
        #expect(!store.rollIfNeeded())
        // A gap of several days: the last list still carries over; old days drop after 30 days.
        clock.now += 40 * 86_400
        store.rollIfNeeded()
        #expect(store.today.map(\.id) == [open.id])
        #expect(store.stored.days[yesterday] == nil)
    }

    @Test func savedAndRestored() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sp-tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tasks.json")
        let store = TaskStore(fileURL: url)
        let task = store.add("Persist me")!
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: url.path) { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(100))
        let again = TaskStore(fileURL: url)
        #expect(again.today.map(\.id) == [task.id])
    }
}
