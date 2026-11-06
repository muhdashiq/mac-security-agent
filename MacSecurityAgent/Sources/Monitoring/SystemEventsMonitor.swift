#if canImport(AppKit)
import AppKit

/// Forwards display-sleep and system-sleep notifications to the coordinator.
@MainActor
public final class SystemEventsMonitor {
    public struct Handlers {
        public var displayDidSleep: @MainActor @Sendable () -> Void
        public var displayDidWake: @MainActor @Sendable () -> Void
        public var systemWillSleep: @MainActor @Sendable () -> Void
        public var systemDidWake: @MainActor @Sendable () -> Void

        public init(
            displayDidSleep: @escaping @MainActor @Sendable () -> Void,
            displayDidWake: @escaping @MainActor @Sendable () -> Void,
            systemWillSleep: @escaping @MainActor @Sendable () -> Void,
            systemDidWake: @escaping @MainActor @Sendable () -> Void
        ) {
            self.displayDidSleep = displayDidSleep
            self.displayDidWake = displayDidWake
            self.systemWillSleep = systemWillSleep
            self.systemDidWake = systemDidWake
        }
    }

    private var tokens: [NSObjectProtocol] = []

    public init() {}

    public func start(handlers: Handlers) {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, @MainActor @Sendable () -> Void)] = [
            (NSWorkspace.screensDidSleepNotification, handlers.displayDidSleep),
            (NSWorkspace.screensDidWakeNotification, handlers.displayDidWake),
            (NSWorkspace.willSleepNotification, handlers.systemWillSleep),
            (NSWorkspace.didWakeNotification, handlers.systemDidWake),
        ]
        for (name, handler) in pairs {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            })
        }
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach { center.removeObserver($0) }
        tokens.removeAll()
    }
}
#endif
