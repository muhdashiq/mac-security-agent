import Foundation
#if canImport(Network)
import Network
#endif

/// Reports internet reachability changes.
public protocol NetworkStatusProviding: AnyObject, Sendable {
    func start(onChange: @escaping @Sendable (Bool) -> Void)
    func stop()
}

#if canImport(Network)
/// `NWPathMonitor` based reachability. Outbound only; no listener is created.
public final class NetworkMonitor: NetworkStatusProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.macsecurityagent.network")
    private let lock = NSLock()
    private var monitor: NWPathMonitor?

    public init() {}

    public func start(onChange: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            onChange(path.status == .satisfied)
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        monitor?.cancel()
        monitor = nil
    }
}
#endif
