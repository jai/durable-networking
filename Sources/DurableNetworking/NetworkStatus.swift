import Network
import Synchronization

/// The network now, from the system's path monitor: one for the process. Whether there is one (`isOnline`), and
/// whether it asks for thrift (`isConstrained`, Low Data Mode on Wi-Fi or cellular), when work nobody asked for, like
/// reading ahead, waits for a network that doesn't. For news of a network returning, use `PathWatcher`.
public final class NetworkStatus: Sendable {
    public static let shared = NetworkStatus()

    private struct Now {
        var isOnline = true
        var isConstrained = false
    }

    private let monitor = NWPathMonitor()
    private let now = Mutex(Now())

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.now.withLock { $0 = Now(isOnline: path.status == .satisfied, isConstrained: path.isConstrained) }
        }
        monitor.start(queue: DispatchQueue(label: "durable-networking.status"))
    }

    public var isOnline: Bool {
        now.withLock { $0.isOnline }
    }

    public var isConstrained: Bool {
        now.withLock { $0.isConstrained }
    }
}
