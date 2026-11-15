import Network
import Synchronization

/// Whether the network asks for thrift (Low Data Mode, on Wi-Fi or cellular): work the user didn't ask for, like
/// reading ahead, waits for a network that doesn't.
public final class NetworkThrift: Sendable {
    public static let shared = NetworkThrift()

    private let monitor = NWPathMonitor()
    private let constrained = Mutex(false)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.constrained.withLock { $0 = path.isConstrained }
        }
        monitor.start(queue: DispatchQueue(label: "durable-networking.thrift"))
    }

    public var isConstrained: Bool {
        constrained.withLock { $0 }
    }
}
