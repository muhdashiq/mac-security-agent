import Foundation

/// Suppresses new events for a configurable interval after an event ends.
///
/// The cooldown starts when an event *finishes* (after its recording), so a
/// continuous movement produces one event with one recording rather than a
/// stream of duplicate notifications.
public struct EventCooldown: Sendable, Equatable {
    public var interval: TimeInterval
    public private(set) var endsAt: Date?

    public init(interval: TimeInterval = 30) {
        self.interval = max(0, interval)
    }

    public func isActive(at date: Date) -> Bool {
        guard let endsAt else { return false }
        return date < endsAt
    }

    public func remaining(at date: Date) -> TimeInterval {
        guard let endsAt else { return 0 }
        return max(0, endsAt.timeIntervalSince(date))
    }

    public mutating func begin(at date: Date) {
        endsAt = date.addingTimeInterval(interval)
    }

    public mutating func reset() {
        endsAt = nil
    }
}
