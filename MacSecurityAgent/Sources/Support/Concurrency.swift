import Foundation

/// A small lock-protected box for state that is shared between a dispatch
/// queue (for example the camera queue) and Swift concurrency code.
///
/// `Synchronization.Mutex` would be preferable but requires macOS 15; this
/// type keeps the deployment target at macOS 14.
public final class LockedValue<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value {
        withLock { $0 }
    }

    public func set(_ newValue: Value) {
        withLock { $0 = newValue }
    }
}

/// Wraps a non-Sendable value whose thread confinement is guaranteed by the
/// caller (for example an `AVAssetWriter` that is only touched on the camera
/// queue but must be referenced from a completion handler).
public struct UncheckedSendableBox<Value>: @unchecked Sendable {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }
}

/// Monotonic clock used for frame-health measurements. `systemUptime` does not
/// jump when the wall clock changes.
public enum MonotonicClock {
    public static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
