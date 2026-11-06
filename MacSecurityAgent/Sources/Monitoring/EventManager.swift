import Foundation

/// Owns the event lifecycle: creates events (enforcing "one active event" and
/// the cooldown), records delivery progress and persists metadata.
public actor EventManager {
    public enum BeginResult: Sendable, Equatable {
        case started(SecurityEvent)
        case rejectedEventInProgress(EventID)
        case rejectedCooldown(remaining: TimeInterval)
    }

    private let repository: EventRepository
    private let now: @Sendable () -> Date
    private let logger = AppLogger(category: "Events")
    private var cooldown: EventCooldown
    private var activeEventID: EventID?

    public init(
        repository: EventRepository,
        cooldownInterval: TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.cooldown = EventCooldown(interval: cooldownInterval)
        self.now = now
    }

    public var currentEventID: EventID? { activeEventID }

    /// Applies to cooldowns started after the change.
    public func setCooldownInterval(_ interval: TimeInterval) {
        cooldown.interval = max(0, interval)
    }

    public func cooldownRemaining() -> TimeInterval {
        cooldown.remaining(at: now())
    }

    /// Creates a new event unless one is already active or the cooldown runs.
    public func beginEvent(changedFraction: Double, detectedAt: Date? = nil) async -> BeginResult {
        if let activeEventID {
            return .rejectedEventInProgress(activeEventID)
        }
        let date = detectedAt ?? now()
        if cooldown.isActive(at: date) {
            return .rejectedCooldown(remaining: cooldown.remaining(at: date))
        }
        let id = await repository.allocateEventID()
        let event = SecurityEvent(id: id, detectedAt: date, changedAreaPercent: changedFraction * 100)
        activeEventID = id
        await repository.upsert(event)
        logger.info("Event \(id) started (\(String(format: "%.1f", changedFraction * 100))% changed)")
        return .started(event)
    }

    @discardableResult
    public func update(_ id: EventID, _ change: @escaping @Sendable (inout SecurityEvent) -> Void) async -> SecurityEvent? {
        // The read-modify-write runs inside the repository actor in one step,
        // so concurrent updates (upload callbacks vs. the motion handler)
        // can never overwrite each other.
        let date = now()
        return await repository.modify(id) { event in
            change(&event)
            Self.recomputeStage(&event, now: date)
        }
    }

    @discardableResult
    public func setStatus(_ status: DeliveryStatus, for artifact: EventArtifact, of id: EventID) async -> SecurityEvent? {
        await update(id) { event in
            // Never regress a terminal status (e.g. a late "uploading" report
            // after the item was already delivered).
            if event.status(of: artifact).isTerminal && !status.isTerminal { return }
            event.setStatus(status, for: artifact)
        }
    }

    @discardableResult
    public func markRecordingStarted(_ id: EventID) async -> SecurityEvent? {
        let date = now()
        return await update(id) { event in
            event.recordingStartedAt = date
            event.stage = .recording
        }
    }

    @discardableResult
    public func markRecordingFinished(_ id: EventID, duration: TimeInterval) async -> SecurityEvent? {
        await update(id) { event in
            event.recordingDuration = duration
        }
    }

    /// Ends the active event and starts the cooldown.
    public func finishActiveEvent(_ id: EventID) async {
        guard activeEventID == id else { return }
        activeEventID = nil
        cooldown.begin(at: now())
    }

    /// Ends the active event because monitoring stopped.
    public func interruptActiveEvent(reason: String) async {
        guard let id = activeEventID else { return }
        activeEventID = nil
        await update(id) { event in
            for artifact in [EventArtifact.alert, .snapshot, .video] where event.status(of: artifact) == .pending {
                event.setStatus(.skipped(reason), for: artifact)
            }
        }
    }

    public func resetCooldown() {
        cooldown.reset()
    }

    /// Called at launch: events that were recording when the app terminated
    /// lost their (unfinalised) video.
    public func recoverInterruptedEvents() async -> [SecurityEvent] {
        let candidates = await repository.recent(limit: 50).filter { !$0.allArtifactsTerminal }
        var recovered: [SecurityEvent] = []
        for event in candidates {
            let updated = await update(event.id) { event in
                if event.status(of: .video) == .pending {
                    event.setStatus(.failed("Application terminated during recording"), for: .video)
                }
                if event.status(of: .snapshot) == .pending {
                    event.setStatus(.failed("Application terminated"), for: .snapshot)
                }
                if event.status(of: .alert) == .pending {
                    event.setStatus(.failed("Application terminated"), for: .alert)
                }
                if event.stage == .recording || event.stage == .motionDetected {
                    event.stage = .interrupted
                }
            }
            if let updated { recovered.append(updated) }
        }
        return recovered
    }

    public func event(_ id: EventID) async -> SecurityEvent? {
        await repository.event(id: id)
    }

    public func recentEvents(limit: Int = 20) async -> [SecurityEvent] {
        await repository.recent(limit: limit)
    }

    public func lastEvent() async -> SecurityEvent? {
        await repository.recent(limit: 1).first
    }

    public func clearHistory() async {
        await repository.removeAll(keeping: activeEventID)
    }

    static func recomputeStage(_ event: inout SecurityEvent, now: Date) {
        if event.stage == .interrupted { return }
        if event.allArtifactsTerminal {
            event.stage = event.isDeliveryConfirmed ? .completed : .incomplete
            if event.completedAt == nil { event.completedAt = now }
            return
        }
        switch event.videoStatus {
        case .queued, .uploading:
            event.stage = .videoQueued
            return
        default:
            break
        }
        if event.recordingStartedAt != nil {
            event.stage = .recording
            return
        }
        switch event.snapshotStatus {
        case .queued, .uploading, .delivered:
            event.stage = .snapshotQueued
        default:
            if event.stage != .snapshotCaptured { event.stage = .motionDetected }
        }
    }
}
