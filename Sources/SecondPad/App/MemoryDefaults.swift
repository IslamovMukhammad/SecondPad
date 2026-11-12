import Foundation

/// Settings that live in memory only: demo mode and the tests use it, so neither leaves a file
/// in ~/Library/Preferences nor sees the real settings.
nonisolated final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private let lock = NSLock()

    static func make() -> MemoryDefaults { MemoryDefaults(suiteName: nil)! }

    override init?(suiteName: String?) { super.init(suiteName: suiteName) }

    override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    override func removeObject(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
    override func set(_ value: Int, forKey key: String) { set(NSNumber(value: value) as Any, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(NSNumber(value: value) as Any, forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(NSNumber(value: value) as Any, forKey: key) }
    override func set(_ value: Bool, forKey key: String) { set(NSNumber(value: value) as Any, forKey: key) }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    override func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    override func float(forKey key: String) -> Float { (object(forKey: key) as? NSNumber)?.floatValue ?? 0 }
    override func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    override func dictionaryRepresentation() -> [String: Any] { lock.withLock { values } }
    override func removePersistentDomain(forName domainName: String) { lock.withLock { values.removeAll() } }
}
