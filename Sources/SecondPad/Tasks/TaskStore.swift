import Foundation

nonisolated struct QuickTask: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var text: String
    var done: Bool
    let createdAt: Double
    var doneAt: Double?
}

/// Today's quick tasks: typed on the Mac, ticked on the tablet or in the menu. Stored locally
/// in `tasks.json` (Application Support), nowhere else.
///
/// Day rollover: each day has its own list. On a new day the unfinished tasks of the last day
/// move over; the finished ones stay in that day's list as the archive (kept 30 days).
final class TaskStore {

    nonisolated static let keepDays = 30
    nonisolated static let maxLength = 200

    struct Stored: Codable, Equatable {
        var version = 1
        var days: [String: [QuickTask]] = [:]
    }

    private(set) var stored = Stored()
    private let fileURL: URL?
    private let clock: () -> Date
    var onChange: (() -> Void)?

    static var defaultFileURL: URL { AppSupport.directory.appendingPathComponent("tasks.json") }

    /// `fileURL` nil: memory only (tests, demo).
    init(fileURL: URL? = TaskStore.defaultFileURL, clock: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.clock = clock
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let value = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = value
        }
        rollIfNeeded()
    }

    var todayKey: String { PomodoroHistory.dayKey(clock()) }

    /// Today's list, open first (oldest first), then done (oldest first).
    var today: [QuickTask] {
        (stored.days[todayKey] ?? []).sorted {
            $0.done != $1.done ? !$0.done : $0.createdAt < $1.createdAt
        }
    }

    @discardableResult
    func add(_ text: String) -> QuickTask? {
        rollIfNeeded()
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let task = QuickTask(id: UUID().uuidString, text: String(clean.prefix(Self.maxLength)), done: false,
                             createdAt: clock().timeIntervalSince1970)
        stored.days[todayKey, default: []].append(task)
        save()
        return task
    }

    func toggle(_ id: String) {
        rollIfNeeded()
        guard var list = stored.days[todayKey], let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].done.toggle()
        list[index].doneAt = list[index].done ? clock().timeIntervalSince1970 : nil
        stored.days[todayKey] = list
        save()
    }

    func delete(_ id: String) {
        guard var list = stored.days[todayKey] else { return }
        list.removeAll { $0.id == id }
        stored.days[todayKey] = list
        save()
    }

    /// Called at start, before every change and once a minute. `true` if the day turned.
    @discardableResult
    func rollIfNeeded() -> Bool {
        let key = todayKey
        guard stored.days[key] == nil else { return false }
        let earlier = stored.days.keys.filter { $0 < key }.sorted()
        guard let last = earlier.last, let previous = stored.days[last] else {
            stored.days[key] = []
            return false
        }
        stored.days[last] = previous.filter(\.done)
        stored.days[key] = previous.filter { !$0.done }
        let cutoff = PomodoroHistory.dayKey(clock().addingTimeInterval(-Double(Self.keepDays) * 86_400))
        stored.days = stored.days.filter { $0.key >= cutoff }
        save(notify: false)
        return true
    }

    struct Message: Encodable {
        let type = "tasks"
        let day: String
        let items: [QuickTask]
        private enum CodingKeys: String, CodingKey { case type, day, items }
    }

    var message: Message { Message(day: todayKey, items: today) }

    private func save(notify: Bool = true) {
        if let fileURL, let data = try? JSONEncoder().encode(stored) { AppSupport.write(data, to: fileURL) }
        if notify { onChange?() }
    }
}
