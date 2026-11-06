import XCTest
@testable import MacSecurityCore

final class EventManagerTests: XCTestCase {
    private func makeManager(cooldown: TimeInterval = 30, clock: TestClock, fileURL: URL? = nil) -> (EventManager, EventRepository) {
        let repository = EventRepository(fileURL: fileURL)
        return (EventManager(repository: repository, cooldownInterval: cooldown, now: clock.nowProvider), repository)
    }

    func testEventIDsAreSequentialAndFormatted() async {
        let clock = TestClock()
        let (manager, _) = makeManager(cooldown: 0, clock: clock)
        guard case .started(let first) = await manager.beginEvent(changedFraction: 0.1) else { return XCTFail() }
        await manager.finishActiveEvent(first.id)
        guard case .started(let second) = await manager.beginEvent(changedFraction: 0.1) else { return XCTFail() }
        XCTAssertEqual(first.id.rawValue, "EVT-00001")
        XCTAssertEqual(second.id.rawValue, "EVT-00002")
        XCTAssertEqual(EventID(string: "EVT-00042"), EventID(sequence: 42))
        XCTAssertNil(EventID(string: "EVT-abc"))
    }

    func testOnlyOneActiveEvent() async {
        let clock = TestClock()
        let (manager, _) = makeManager(clock: clock)
        guard case .started(let event) = await manager.beginEvent(changedFraction: 0.1) else { return XCTFail() }
        let second = await manager.beginEvent(changedFraction: 0.2)
        XCTAssertEqual(second, .rejectedEventInProgress(event.id))
    }

    func testCooldownStartsWhenEventFinishes() async {
        let clock = TestClock()
        let (manager, _) = makeManager(cooldown: 30, clock: clock)
        guard case .started(let event) = await manager.beginEvent(changedFraction: 0.1) else { return XCTFail() }
        clock.advance(30) // recording
        await manager.finishActiveEvent(event.id)
        clock.advance(10)
        guard case .rejectedCooldown(let remaining) = await manager.beginEvent(changedFraction: 0.1) else {
            return XCTFail("Expected cooldown rejection")
        }
        XCTAssertEqual(remaining, 20, accuracy: 0.001)
        clock.advance(20)
        guard case .started = await manager.beginEvent(changedFraction: 0.1) else { return XCTFail("Cooldown should be over") }
    }

    func testCooldownIntervalIsConfigurable() async {
        let clock = TestClock()
        let (manager, _) = makeManager(cooldown: 30, clock: clock)
        await manager.setCooldownInterval(5)
        guard case .started(let event) = await manager.beginEvent(changedFraction: 0.1) else { return XCTFail() }
        await manager.finishActiveEvent(event.id)
        clock.advance(5)
        guard case .started = await manager.beginEvent(changedFraction: 0.1) else { return XCTFail() }
    }

    func testLifecycleReachesCompletedWhenEverythingDelivered() async {
        let clock = TestClock()
        let (manager, _) = makeManager(clock: clock)
        guard case .started(let event) = await manager.beginEvent(changedFraction: 0.1) else { return XCTFail() }
        XCTAssertEqual(event.stage, .motionDetected)
        var updated = await manager.setStatus(.queued, for: .snapshot, of: event.id)
        XCTAssertEqual(updated?.stage, .snapshotQueued)
        updated = await manager.markRecordingStarted(event.id)
        XCTAssertEqual(updated?.stage, .recording)
        _ = await manager.markRecordingFinished(event.id, duration: 30)
        updated = await manager.setStatus(.queued, for: .video, of: event.id)
        XCTAssertEqual(updated?.stage, .videoQueued)
        _ = await manager.setStatus(.delivered, for: .alert, of: event.id)
        _ = await manager.setStatus(.delivered, for: .snapshot, of: event.id)
        updated = await manager.setStatus(.delivered, for: .video, of: event.id)
        XCTAssertEqual(updated?.stage, .completed)
        XCTAssertTrue(updated?.isDeliveryConfirmed ?? false)
        XCTAssertNotNil(updated?.completedAt)
        XCTAssertEqual(updated?.recordingDuration, 30)
    }

    func testFailureMakesEventIncomplete() async {
        let clock = TestClock()
        let (manager, _) = makeManager(clock: clock)
        guard case .started(let event) = await manager.beginEvent(changedFraction: 0.1) else { return XCTFail() }
        _ = await manager.setStatus(.delivered, for: .alert, of: event.id)
        _ = await manager.setStatus(.delivered, for: .snapshot, of: event.id)
        let updated = await manager.setStatus(.expired, for: .video, of: event.id)
        XCTAssertEqual(updated?.stage, .incomplete)
    }

    func testTerminalStatusIsNotRegressed() async {
        let clock = TestClock()
        let (manager, _) = makeManager(clock: clock)
        guard case .started(let event) = await manager.beginEvent(changedFraction: 0.1) else { return XCTFail() }
        _ = await manager.setStatus(.delivered, for: .snapshot, of: event.id)
        let updated = await manager.setStatus(.uploading, for: .snapshot, of: event.id)
        XCTAssertEqual(updated?.snapshotStatus, .delivered)
    }

    func testEventsPersistAndSequenceSurvivesRestart() async throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("events.json")
        let clock = TestClock()
        do {
            let (manager, _) = makeManager(cooldown: 0, clock: clock, fileURL: url)
            guard case .started(let event) = await manager.beginEvent(changedFraction: 0.1) else { return XCTFail() }
            await manager.finishActiveEvent(event.id)
        }
        XCTAssertEqual(SecureFiles.permissions(of: url), 0o600)
        let (manager, _) = makeManager(cooldown: 0, clock: clock, fileURL: url)
        let recent = await manager.recentEvents()
        XCTAssertEqual(recent.map(\.id.rawValue), ["EVT-00001"])
        guard case .started(let next) = await manager.beginEvent(changedFraction: 0.1) else { return XCTFail() }
        XCTAssertEqual(next.id.rawValue, "EVT-00002")
    }

    func testRecoverInterruptedEventsAfterCrash() async throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("events.json")
        let clock = TestClock()
        do {
            let (manager, _) = makeManager(clock: clock, fileURL: url)
            guard case .started(let event) = await manager.beginEvent(changedFraction: 0.1) else { return XCTFail() }
            _ = await manager.setStatus(.queued, for: .alert, of: event.id)
            _ = await manager.setStatus(.queued, for: .snapshot, of: event.id)
            _ = await manager.markRecordingStarted(event.id)
            // App "crashes" here.
        }
        let (manager, _) = makeManager(clock: clock, fileURL: url)
        let recovered = await manager.recoverInterruptedEvents()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.stage, .interrupted)
        XCTAssertEqual(recovered.first?.videoStatus, .failed("Application terminated during recording"))
        // Queued artefacts stay queued: the upload queue still delivers them.
        XCTAssertEqual(recovered.first?.snapshotStatus, .queued)
    }

    func testRepositoryTrimsOldEvents() async {
        let repository = EventRepository(fileURL: nil, maxEvents: 3)
        for _ in 0..<5 {
            let id = await repository.allocateEventID()
            await repository.upsert(SecurityEvent(id: id, detectedAt: Date(), changedAreaPercent: 1))
        }
        let ids = await repository.recent(limit: 10).map(\.id.sequence)
        XCTAssertEqual(ids, [5, 4, 3])
    }

    func testEventCooldownValueType() {
        var cooldown = EventCooldown(interval: 30)
        let start = Date()
        XCTAssertFalse(cooldown.isActive(at: start))
        cooldown.begin(at: start)
        XCTAssertTrue(cooldown.isActive(at: start.addingTimeInterval(29.9)))
        XCTAssertFalse(cooldown.isActive(at: start.addingTimeInterval(30)))
        XCTAssertEqual(cooldown.remaining(at: start.addingTimeInterval(10)), 20, accuracy: 1e-9)
        cooldown.reset()
        XCTAssertFalse(cooldown.isActive(at: start))
    }
}
