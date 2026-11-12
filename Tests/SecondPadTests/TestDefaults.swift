@testable import SecondPad
import Foundation

/// Settings for tests: in memory only, so test runs never write to ~/Library/Preferences.
nonisolated enum TestDefaults {
    static func make(_ name: String) -> UserDefaults { MemoryDefaults.make() }
}
