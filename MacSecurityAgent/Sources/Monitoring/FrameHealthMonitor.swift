import Foundation

/// Tracks whether camera frames are actually arriving.
///
/// The camera queue calls `recordFrame()` for every frame; the coordinator
/// evaluates the health once per second. Monitoring is never reported as
/// active when frames have stopped.
public final class FrameHealthMonitor: Sendable {
    public enum Health: Sendable, Equatable {
        case inactive
        case waitingForFirstFrame(elapsed: TimeInterval)
        case healthy
        case stalled(secondsSinceLastFrame: TimeInterval)
    }

    private struct State {
        var startedAt: TimeInterval?
        var lastFrameAt: TimeInterval?
        var frameCount = 0
    }

    private let state = LockedValue(State())
    private let clock: @Sendable () -> TimeInterval

    public init(clock: @escaping @Sendable () -> TimeInterval = MonotonicClock.now) {
        self.clock = clock
    }

    public func markStarted() {
        let now = clock()
        state.withLock { $0 = State(startedAt: now, lastFrameAt: nil, frameCount: 0) }
    }

    public func markStopped() {
        state.withLock { $0 = State() }
    }

    public func recordFrame() {
        let now = clock()
        state.withLock {
            $0.lastFrameAt = now
            $0.frameCount &+= 1
        }
    }

    public var frameCount: Int {
        state.withLock { $0.frameCount }
    }

    public func evaluate(stallThreshold: TimeInterval = 5, firstFrameTimeout: TimeInterval = 10) -> Health {
        let now = clock()
        return state.withLock { state -> Health in
            guard let startedAt = state.startedAt else { return .inactive }
            guard let last = state.lastFrameAt else {
                let elapsed = now - startedAt
                return elapsed > firstFrameTimeout ? .stalled(secondsSinceLastFrame: elapsed) : .waitingForFirstFrame(elapsed: elapsed)
            }
            let age = now - last
            return age > stallThreshold ? .stalled(secondsSinceLastFrame: age) : .healthy
        }
    }
}
