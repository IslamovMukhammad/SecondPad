import Foundation

nonisolated enum ISODate {
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// An epoch number (seconds), a numeric string, or an ISO-8601 string.
    static func epoch(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let number = Double(text), number.isFinite { return number }
        return parse(text)?.timeIntervalSince1970
    }
}
