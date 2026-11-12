import Foundation

/// One finished focus period.
nonisolated struct PomodoroLogEntry: Codable, Equatable, Sendable {
    let index: Int
    /// true = ran to the end; false = reset half-way (not counted as a pomodoro).
    let completed: Bool
    /// Manual pauses during it.
    let interruptions: Int
    /// Time really spent in focus.
    let durationSeconds: Int
    /// Share of the period on task, 0…100.
    let purity: Int
    /// Times focus moved from work to a distraction.
    let focusBreaks: Int
    let distractions: [FocusDistraction]
    /// One entry per finished minute: true = distracted in that minute.
    let minutes: [Bool]
    let endedAt: Double
}

/// One distracting app inside a focus period: how often and how long.
nonisolated struct FocusDistraction: Codable, Equatable, Sendable {
    let app: String
    /// Real apps get their icon from `/appicon?id=`; sites ("web.youtube") get a letter badge.
    let bundleId: String?
    let category: String
    let colorHex: String
    let visits: Int
    let seconds: Int
}

/// The Pomodoro log on disk (100 days): today's periods survive a restart, and the Deep Focus
/// page's week chart is built from it. Written only when a period ends, atomically, off the main
/// thread.
final class PomodoroHistory {

    nonisolated static let keepDays = 100

    struct Stored: Codable, Equatable {
        var version = 1
        var completedSinceLongBreak = 0
        /// "yyyy-MM-dd" → that day's periods
        var days: [String: [PomodoroLogEntry]] = [:]
    }

    private(set) var stored = Stored()
    private let fileURL: URL?

    static var defaultFileURL: URL { AppSupport.directory.appendingPathComponent("pomodoro-log.json") }

    /// `fileURL` nil: memory only (tests, demo).
    init(fileURL: URL? = PomodoroHistory.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let value = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = value
        }
    }

    nonisolated static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func today(now: Date = Date()) -> (entries: [PomodoroLogEntry], completedSinceLongBreak: Int) {
        let entries = stored.days[Self.dayKey(now)] ?? []
        return (entries, entries.isEmpty ? 0 : stored.completedSinceLongBreak)
    }

    func save(today entries: [PomodoroLogEntry], completedSinceLongBreak: Int, now: Date = Date()) {
        stored.days[Self.dayKey(now)] = entries
        stored.completedSinceLongBreak = completedSinceLongBreak
        let cutoff = Self.dayKey(now.addingTimeInterval(-Double(Self.keepDays) * 86_400))
        stored.days = stored.days.filter { $0.key >= cutoff }
        guard let fileURL, let data = try? JSONEncoder().encode(stored) else { return }
        AppSupport.write(data, to: fileURL)
    }

    struct WeekDay: Encodable, Equatable {
        let date: String
        let focusSeconds: Int
        /// Purity weighted by duration; nil when there was no focus that day.
        let purity: Int?
    }

    /// The last 7 days, oldest first, today last: focus time and quality per day.
    func week(now: Date = Date(), calendar: Calendar = .current) -> [WeekDay] {
        (0..<7).reversed().map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: now) ?? now
            let key = Self.dayKey(day, calendar: calendar)
            let entries = stored.days[key] ?? []
            let seconds = entries.reduce(0) { $0 + $1.durationSeconds }
            let weighted = entries.reduce(0) { $0 + $1.purity * $1.durationSeconds }
            return WeekDay(date: key, focusSeconds: seconds, purity: seconds > 0 ? weighted / seconds : nil)
        }
    }
}
