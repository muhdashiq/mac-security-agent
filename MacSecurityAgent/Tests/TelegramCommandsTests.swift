import XCTest
@testable import MacSecurityCore

private struct StaticReporter: StatusReporting {
    var report: StatusReport
    var events: [SecurityEvent]
    func statusReport() async -> StatusReport { report }
    func recentEvents(limit: Int) async -> [SecurityEvent] { Array(events.prefix(limit)) }
}

final class TelegramCommandsTests: XCTestCase {
    private let utc = TelegramMessageFormatter(timeZone: TimeZone(identifier: "UTC")!)

    private func sampleEvent() -> SecurityEvent {
        // 2027-01-15 14:32:18 UTC
        var event = SecurityEvent(id: EventID(sequence: 1), detectedAt: Date(timeIntervalSince1970: 1_800_022_338), changedAreaPercent: 4.2)
        event.stage = .completed
        event.snapshotStatus = .delivered
        event.videoStatus = .delivered
        return event
    }

    func testMotionAlertMatchesSpecification() {
        let text = utc.motionAlert(event: sampleEvent(), recordingStarted: true, snapshotEnabled: true)
        XCTAssertEqual(text, """
        MAC SECURITY ALERT
        Motion detected.
        Event ID: EVT-00001
        Time: \(utc.time(sampleEvent().detectedAt))
        Camera: Active
        Video recording: Started
        Snapshot will be delivered first.
        Video will follow after recording completes.
        """)
    }

    func testStatusResponseContainsRequiredFields() async {
        let report = StatusReport(
            monitoring: .armed, camera: .active, networkAvailable: true, telegram: .connected,
            lastEvent: sampleEvent(), pendingUploads: 2, armedSince: nil, powerSource: .ac
        )
        let handler = TelegramCommandHandler(reporter: StaticReporter(report: report, events: []), formatter: utc)
        let text = await handler.response(to: .status)
        XCTAssertTrue(text.contains("Monitoring: ARMED"))
        XCTAssertTrue(text.contains("Camera: ACTIVE"))
        XCTAssertTrue(text.contains("Network: ONLINE"))
        XCTAssertTrue(text.contains("Last event: EVT-00001 at"))
        XCTAssertTrue(text.contains("Pending uploads: 2"))
    }

    func testEventsResponseListsHistory() async {
        let handler = TelegramCommandHandler(
            reporter: StaticReporter(report: StatusReport(monitoring: .disarmed, camera: .inactive, networkAvailable: true, telegram: .connected, lastEvent: nil, pendingUploads: 0, armedSince: nil), events: [sampleEvent()]),
            formatter: utc
        )
        let text = await handler.response(to: .events)
        XCTAssertTrue(text.contains("EVT-00001"))
        XCTAssertTrue(text.contains("snapshot: delivered, video: delivered"))
        let empty = TelegramCommandHandler(reporter: StaticReporter(report: StatusReport(monitoring: .disarmed, camera: .inactive, networkAvailable: true, telegram: .connected, lastEvent: nil, pendingUploads: 0, armedSince: nil), events: []))
        let emptyText = await empty.response(to: .events)
        XCTAssertEqual(emptyText, "No events recorded.")
    }

    func testHelpAndRemoteControlResponses() async {
        let handler = TelegramCommandHandler(reporter: StaticReporter(report: StatusReport(monitoring: .disarmed, camera: .inactive, networkAvailable: true, telegram: .connected, lastEvent: nil, pendingUploads: 0, armedSince: nil), events: []))
        let help = await handler.response(to: .help)
        XCTAssertTrue(help.contains("/status"))
        XCTAssertTrue(help.contains("/events"))
        XCTAssertTrue(help.contains("/help"))
        let refused = await handler.response(to: .remoteControlRequest("arm"))
        XCTAssertTrue(refused.contains("not supported"))
    }

    // MARK: Poller

    private func makePoller(api: MockTelegramAPI, offsets: InMemoryOffsetStore, statuses: LockedValue<[TelegramStatus]>, unauthorized: LockedValue<[Int64?]>, now: Date) -> TelegramUpdatePoller {
        let config = TelegramConfigurationStore(session: TelegramSession(api: api, ownerUserID: ownerID, botUsername: nil))
        let report = StatusReport(monitoring: .armed, camera: .active, networkAvailable: true, telegram: .connected, lastEvent: nil, pendingUploads: 0, armedSince: nil)
        return TelegramUpdatePoller(
            sessionProvider: config,
            offsetStore: offsets,
            handler: TelegramCommandHandler(reporter: StaticReporter(report: report, events: [])),
            callbacks: .init(
                statusChanged: { status in statuses.withLock { $0.append(status) } },
                unauthorizedAttempt: { id in unauthorized.withLock { $0.append(id) } }
            ),
            now: { now }
        )
    }

    func testPollerSkipsBacklogOnFirstStartAndAnswersOwner() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let api = MockTelegramAPI()
        let offsets = InMemoryOffsetStore()
        let statuses = LockedValue<[TelegramStatus]>([])
        let unauthorized = LockedValue<[Int64?]>([])
        let poller = makePoller(api: api, offsets: offsets, statuses: statuses, unauthorized: unauthorized, now: now)

        api.script(updates: [makeUpdate(id: 50, text: "/status", date: now.addingTimeInterval(-3600))]) // backlog probe
        api.script(updates: [makeUpdate(id: 51, text: "/status", date: now)])
        await poller.pollOnce()

        XCTAssertEqual(api.getUpdatesOffsets, [-1, 51])
        XCTAssertEqual(offsets.loadOffset(), 52)
        XCTAssertEqual(api.sent.count, 1, "Only the fresh command is answered")
        XCTAssertTrue(api.sent[0].text?.contains("Monitoring: ARMED") ?? false)
        XCTAssertEqual(api.sent[0].chatID, ownerID)
        XCTAssertEqual(statuses.current, [.connected])
    }

    func testPollerRejectsUnauthorizedUsersWithoutReplying() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let api = MockTelegramAPI()
        let offsets = InMemoryOffsetStore(offset: 10)
        let unauthorized = LockedValue<[Int64?]>([])
        let poller = makePoller(api: api, offsets: offsets, statuses: LockedValue([]), unauthorized: unauthorized, now: now)
        api.script(updates: [makeUpdate(id: 10, text: "/status", from: 666, date: now)])
        await poller.pollOnce()
        XCTAssertTrue(api.sent.isEmpty, "Strangers get no answer")
        XCTAssertEqual(unauthorized.current, [666])
        XCTAssertEqual(offsets.loadOffset(), 11)
    }

    func testPollerReportsOfflineAndBacksOff() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let api = MockTelegramAPI()
        api.setGetUpdatesError(.network(code: -1009))
        let statuses = LockedValue<[TelegramStatus]>([])
        let poller = makePoller(api: api, offsets: InMemoryOffsetStore(offset: 1), statuses: statuses, unauthorized: LockedValue([]), now: now)
        let first = await poller.pollOnce()
        let second = await poller.pollOnce()
        XCTAssertEqual(statuses.current, [.offline])
        XCTAssertGreaterThan(second, first)
    }

    func testOwnerFreeTextGetsHelp() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let api = MockTelegramAPI()
        let poller = makePoller(api: api, offsets: InMemoryOffsetStore(offset: 1), statuses: LockedValue([]), unauthorized: LockedValue([]), now: now)
        api.script(updates: [makeUpdate(id: 1, text: "hello?", date: now)])
        await poller.pollOnce()
        XCTAssertTrue(api.sent.first?.text?.contains("/status") ?? false)
    }
}
