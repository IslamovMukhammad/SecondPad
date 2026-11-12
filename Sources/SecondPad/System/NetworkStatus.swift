import Foundation
import Network

/// Is the Mac online? The tablet's Tasks header shows it as a small wifi mark (dim when fine,
/// red and breathing when offline, three blips when it changes).
final class NetworkStatus {
    private(set) var isOnline = true
    var onChange: (() -> Void)?
    private var monitor: NWPathMonitor?

    func start() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isOnline != online else { return }
                    self.isOnline = online
                    self.onChange?()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "SecondPad.net"))
        self.monitor = monitor
    }
}
