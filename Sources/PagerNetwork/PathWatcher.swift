import Foundation
import Network

/// Says when a usable network appears or changes (off to on, or Wi-Fi to cellular), when anything still waiting is
/// worth trying at once: the elevator doors have opened.
public final class PathWatcher: Sendable {
    private let monitor = NWPathMonitor()

    /// `satisfied` is called on every change of whether there's a network; `returned` when there is a new one.
    public init(
        satisfied: @escaping @Sendable (Bool) -> Void = { _ in },
        returned: @escaping @Sendable () -> Void
    ) {
        let state = PathState()
        monitor.pathUpdateHandler = { path in
            let (isUp, isNew) = state.update(
                up: path.status == .satisfied, interfaces: path.availableInterfaces.map(\.name)
            )
            satisfied(isUp)
            if isNew {
                returned()
            }
        }
        monitor.start(queue: DispatchQueue(label: "agent-pager.path-watcher"))
    }

    deinit {
        monitor.cancel()
    }
}

/// The monitor's queue is serial and the only caller.
final class PathState: @unchecked Sendable {
    private var up: Bool?
    private var interface: String?

    /// The first answer is where things stand, not news.
    func update(up isUp: Bool, interfaces: [String]) -> (up: Bool, isNew: Bool) {
        let first = interfaces.first
        defer {
            up = isUp
            interface = first
        }
        guard let was = up else {
            return (isUp, false)
        }
        return (isUp, isUp && (!was || first != interface))
    }
}
