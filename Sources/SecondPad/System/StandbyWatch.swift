import AppKit

/// Is anyone at the Mac? When the screen saver starts, the screen locks, the displays sleep or the
/// Mac goes to sleep, the tablet turns into a big calm clock (as the original's StandBy). Each one
/// is tracked on its own: you can lock without a screen saver, and displays can sleep while
/// unlocked; any of them is enough, and the clock goes away only when all are back.
/// macOS announces all of these to every app; no permission is needed.
nonisolated struct StandbyState: Equatable, Sendable {

    enum Event: Sendable {
        case screenSaverStarted, screenSaverStopped
        case locked, unlocked
        case displaysSlept, displaysWoke
        case macWillSleep, macWoke
    }

    private(set) var screenSaver = false
    private(set) var locked = false
    private(set) var displaysAsleep = false
    private(set) var macAsleep = false

    var isActive: Bool { screenSaver || locked || displaysAsleep || macAsleep }

    mutating func apply(_ event: Event) {
        switch event {
        case .screenSaverStarted: screenSaver = true
        case .screenSaverStopped: screenSaver = false
        case .locked: locked = true
        case .unlocked: locked = false
        case .displaysSlept: displaysAsleep = true
        case .displaysWoke: displaysAsleep = false
        case .macWillSleep: macAsleep = true
        // Waking from sleep: the displays and the lock report themselves again if they stay off.
        case .macWoke: macAsleep = false; displaysAsleep = false
        }
    }
}

final class StandbyWatch {

    private(set) var state = StandbyState()
    var isActive: Bool { state.isActive }
    var onChange: (() -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let pairs: [(NotificationCenter, Notification.Name, StandbyState.Event)] = [
            (workspace, NSWorkspace.willSleepNotification, .macWillSleep),
            (workspace, NSWorkspace.didWakeNotification, .macWoke),
            (workspace, NSWorkspace.screensDidSleepNotification, .displaysSlept),
            (workspace, NSWorkspace.screensDidWakeNotification, .displaysWoke),
            (distributed, Notification.Name("com.apple.screensaver.didstart"), .screenSaverStarted),
            (distributed, Notification.Name("com.apple.screensaver.didstop"), .screenSaverStopped),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .locked),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .unlocked),
        ]
        for (center, name, event) in pairs {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(event) }
            }
            observers.append((center, token))
        }
    }

    func stop() {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
    }

    func apply(_ event: StandbyState.Event) {
        let was = state.isActive
        state.apply(event)
        if state.isActive != was { onChange?() }
    }
}
