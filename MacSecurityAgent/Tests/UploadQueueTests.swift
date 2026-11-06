import XCTest
@testable import MacSecurityCore

final class UploadQueueTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let storage: InMemorySecureStorage
        let store: TemporaryMediaStore
        let api: MockTelegramAPI
        let config: TelegramConfigurationStore
        let clock: TestClock
        let queue: UploadQueue
        var indexURL: URL { directory.appendingPathComponent("index.json") }
    }

    private func makeFixture(
        directory: URL? = nil,
        storage: InMemorySecureStorage = InMemorySecureStorage(),
        api: MockTelegramAPI = MockTelegramAPI(),
        clock: TestClock = TestClock(),
        retention: TimeInterval = 24 * 3600,
        configured: Bool = true
    ) throws -> Fixture {
        let directory = try directory ?? makeTemporaryDirectory()
        let store = try TemporaryMediaStore(
            rootDirectory: directory.appendingPathComponent("Queue"),
            keyProvider: MediaKeyProvider(storage: storage), now: clock.nowProvider
        )
        let config = TelegramConfigurationStore(
            session: configured ? TelegramSession(api: api, ownerUserID: ownerID, botUsername: nil) : nil
        )
        let queue = UploadQueue(
            indexURL: directory.appendingPathComponent("index.json"),
            mediaStore: store, sessionProvider: config, retention: retention,
            policy: RetryPolicy(baseDelay: 2, maximumDelay: 300, multiplier: 2, jitter: 0),
            now: clock.nowProvider, random: { 0.5 }
        )
        return Fixture(directory: directory, storage: storage, store: store, api: api, config: config, clock: clock, queue: queue)
    }

    func testDeliversTextPhotoAndVideoInOrder() async throws {
        let f = try makeFixture()
        let photo = try await f.store.store(Data("jpeg-bytes".utf8), kind: .snapshot)
        let video = try await f.store.store(Data("mp4-bytes".utf8), kind: .video)
        let id = EventID(sequence: 1)
        await f.queue.enqueue(.text("alert"), eventID: id, artifact: .alert, deduplicationKey: "EVT-00001.alert")
        await f.queue.enqueue(.photo(media: photo, caption: "snap"), eventID: id, artifact: .snapshot, deduplicationKey: "EVT-00001.snapshot")
        await f.queue.enqueue(.video(media: video, caption: "vid", durationSeconds: 30, width: 1280, height: 720), eventID: id, artifact: .video, deduplicationKey: "EVT-00001.video")

        let summary = await f.queue.processDueItems()
        XCTAssertEqual(summary.delivered, 3)
        XCTAssertEqual(f.api.sent.map(\.kind), [.message, .photo, .video])
        XCTAssertEqual(f.api.sent[1].data, Data("jpeg-bytes".utf8), "Media must be decrypted before upload")
        XCTAssertEqual(f.api.sent.map(\.chatID), [ownerID, ownerID, ownerID])
        let pending = await f.queue.pendingCount
        XCTAssertEqual(pending, 0)
        XCTAssertTrue(directoryContents(f.store.mediaDirectory).isEmpty, "Media must be deleted after confirmed delivery")
    }

    func testDuplicateKeysAreRejectedWhilePendingAndAfterDelivery() async throws {
        let f = try makeFixture()
        let first = await f.queue.enqueue(.text("a"), eventID: nil, artifact: nil, deduplicationKey: "k")
        let second = await f.queue.enqueue(.text("a"), eventID: nil, artifact: nil, deduplicationKey: "k")
        guard case .enqueued = first else { return XCTFail() }
        XCTAssertEqual(second, .duplicate)
        await f.queue.processDueItems()
        let third = await f.queue.enqueue(.text("a"), eventID: nil, artifact: nil, deduplicationKey: "k")
        XCTAssertEqual(third, .duplicate)
        XCTAssertEqual(f.api.sent.count, 1)
    }

    func testOfflineDefersDeliveryAndRecoveryRetriesImmediately() async throws {
        let f = try makeFixture()
        await f.queue.setNetworkAvailable(false)
        await f.queue.enqueue(.text("a"), eventID: nil, artifact: nil, deduplicationKey: "a")
        let offline = await f.queue.processDueItems()
        XCTAssertTrue(offline.deferredOffline)
        XCTAssertTrue(f.api.sent.isEmpty)

        await f.queue.setNetworkAvailable(true)
        let online = await f.queue.processDueItems()
        XCTAssertEqual(online.delivered, 1)
    }

    func testNetworkFailureUsesExponentialBackoff() async throws {
        let f = try makeFixture()
        f.api.failNext(.network(code: -1009), times: 3)
        await f.queue.enqueue(.text("a"), eventID: nil, artifact: nil, deduplicationKey: "a")

        var delays: [TimeInterval] = []
        for _ in 0..<3 {
            let summary = await f.queue.processDueItems()
            XCTAssertEqual(summary.retried, 1)
            let item = await f.queue.allItems()[0]
            delays.append(item.nextAttemptAt.timeIntervalSince(f.clock.now))
            // Not due yet: nothing is attempted.
            let early = await f.queue.processDueItems()
            XCTAssertEqual(early.retried + early.delivered, 0)
            f.clock.advance(delays.last!)
        }
        XCTAssertEqual(delays, [2, 4, 8])
        let final = await f.queue.processDueItems()
        XCTAssertEqual(final.delivered, 1)
    }

    func testRetryPolicyCapsAndJitters() {
        let policy = RetryPolicy(baseDelay: 2, maximumDelay: 300, multiplier: 2, jitter: 0.2)
        XCTAssertEqual(policy.delay(afterAttempt: 1, random: 0.5), 2)
        XCTAssertEqual(policy.delay(afterAttempt: 20, random: 0.5), 300)
        XCTAssertEqual(policy.delay(afterAttempt: 3, random: 0), 6.4, accuracy: 1e-9)
        XCTAssertEqual(policy.delay(afterAttempt: 3, random: 1), 9.6, accuracy: 1e-9)
    }

    func testRateLimitHonoursRetryAfter() async throws {
        let f = try makeFixture()
        f.api.failNext(.api(code: 429, description: "Too Many Requests", retryAfter: 42))
        await f.queue.enqueue(.text("a"), eventID: nil, artifact: nil, deduplicationKey: "a")
        await f.queue.processDueItems()
        let item = await f.queue.allItems()[0]
        XCTAssertEqual(item.nextAttemptAt.timeIntervalSince(f.clock.now), 42, accuracy: 0.001)
    }

    func testPermanentFailureIsReportedAndMediaDeleted() async throws {
        let f = try makeFixture()
        let events = LockedValue<[UploadQueueEvent]>([])
        await f.queue.setEventHandler { event in events.withLock { $0.append(event) } }
        let video = try await f.store.store(Data("mp4".utf8), kind: .video)
        f.api.failNext(.api(code: 413, description: "Request Entity Too Large", retryAfter: nil))
        await f.queue.enqueue(.video(media: video, caption: nil, durationSeconds: 30, width: 1280, height: 720), eventID: EventID(sequence: 7), artifact: .video, deduplicationKey: "v")
        let summary = await f.queue.processDueItems()
        XCTAssertEqual(summary.failed, 1)
        XCTAssertTrue(directoryContents(f.store.mediaDirectory).isEmpty)
        XCTAssertTrue(events.current.contains { if case .failed(let item, _) = $0 { return item.eventID == EventID(sequence: 7) }; return false })
    }

    func testConfigurationErrorKeepsItemAndReportsOnce() async throws {
        let f = try makeFixture()
        let events = LockedValue<[UploadQueueEvent]>([])
        await f.queue.setEventHandler { event in events.withLock { $0.append(event) } }
        f.api.failNext(.api(code: 403, description: "Forbidden: bot was blocked by the user", retryAfter: nil), times: 2)
        await f.queue.enqueue(.text("a"), eventID: nil, artifact: nil, deduplicationKey: "a")
        await f.queue.processDueItems()
        f.clock.advance(400)
        await f.queue.processDueItems()
        let pending = await f.queue.pendingCount
        XCTAssertEqual(pending, 1)
        let problems = events.current.filter { if case .configurationProblem = $0 { return true }; return false }
        XCTAssertEqual(problems.count, 1)
        await f.queue.configurationChanged()
        let summary = await f.queue.processDueItems()
        XCTAssertEqual(summary.delivered, 1)
    }

    func testNotConfiguredKeepsItemsPending() async throws {
        let f = try makeFixture(configured: false)
        await f.queue.enqueue(.text("a"), eventID: nil, artifact: nil, deduplicationKey: "a")
        let summary = await f.queue.processDueItems()
        XCTAssertTrue(summary.notConfigured)
        let items = await f.queue.allItems()
        XCTAssertEqual(items.first?.attempts, 0)
    }

    func testItemsExpireAfterRetentionAndAreReported() async throws {
        let f = try makeFixture(retention: 24 * 3600)
        let events = LockedValue<[UploadQueueEvent]>([])
        await f.queue.setEventHandler { event in events.withLock { $0.append(event) } }
        await f.queue.setNetworkAvailable(false)
        let photo = try await f.store.store(Data("jpeg".utf8), kind: .snapshot)
        await f.queue.enqueue(.photo(media: photo, caption: nil), eventID: EventID(sequence: 1), artifact: .snapshot, deduplicationKey: "p")
        f.clock.advance(24 * 3600 + 1)
        let summary = await f.queue.processDueItems()
        XCTAssertEqual(summary.expired, 1)
        XCTAssertTrue(directoryContents(f.store.mediaDirectory).isEmpty)
        XCTAssertTrue(events.current.contains { if case .expired = $0 { return true }; return false })
    }

    func testRetentionCannotExceed24Hours() async throws {
        let f = try makeFixture(retention: 72 * 3600)
        await f.queue.setNetworkAvailable(false)
        await f.queue.enqueue(.text("a"), eventID: nil, artifact: nil, deduplicationKey: "a")
        f.clock.advance(24 * 3600 + 1)
        let summary = await f.queue.processDueItems()
        XCTAssertEqual(summary.expired, 1)
    }

    func testPendingUploadsSurviveRestart() async throws {
        let directory = try makeTemporaryDirectory()
        let storage = InMemorySecureStorage()
        let clock = TestClock()
        do {
            let f = try makeFixture(directory: directory, storage: storage, clock: clock)
            await f.queue.setNetworkAvailable(false)
            let photo = try await f.store.store(Data("jpeg".utf8), kind: .snapshot)
            await f.queue.enqueue(.photo(media: photo, caption: "c"), eventID: EventID(sequence: 3), artifact: .snapshot, deduplicationKey: "EVT-00003.snapshot")
            XCTAssertEqual(SecureFiles.permissions(of: f.indexURL), 0o600)
        }
        // New process: same directory and keychain.
        let api = MockTelegramAPI()
        let f = try makeFixture(directory: directory, storage: storage, api: api, clock: clock)
        await f.queue.recoverAfterLaunch()
        let pending = await f.queue.pendingCount
        XCTAssertEqual(pending, 1)
        let summary = await f.queue.processDueItems()
        XCTAssertEqual(summary.delivered, 1)
        XCTAssertEqual(api.sent.first?.data, Data("jpeg".utf8))
        XCTAssertEqual(api.sent.first?.text, "c", "Items that never left the Mac are not marked as duplicates")
    }

    func testInFlightItemIsResentWithDuplicateMarkerAfterCrash() async throws {
        let directory = try makeTemporaryDirectory()
        let storage = InMemorySecureStorage()
        // Simulate a crash after the item was marked in flight: write an
        // index by hand.
        do {
            let f = try makeFixture(directory: directory, storage: storage)
            await f.queue.enqueue(.text("alert"), eventID: nil, artifact: nil, deduplicationKey: "a")
        }
        let indexURL = directory.appendingPathComponent("index.json")
        var json = try String(contentsOf: indexURL, encoding: .utf8)
        json = json.replacingOccurrences(of: "\"pending\"", with: "\"inFlight\"")
        try Data(json.utf8).write(to: indexURL)

        let api = MockTelegramAPI()
        let f = try makeFixture(directory: directory, storage: storage, api: api)
        let recovered = await f.queue.recoverAfterLaunch()
        XCTAssertEqual(recovered, 1)
        await f.queue.processDueItems()
        XCTAssertEqual(api.sent.first?.text, "\(UploadQueue.resendMarker)\nalert")
    }

    func testRecoveryPurgesOrphanedMedia() async throws {
        let f = try makeFixture()
        _ = try await f.store.store(Data("orphan".utf8), kind: .snapshot)
        let recordingURL = try await f.store.makeRecordingURL(for: EventID(sequence: 1))
        try Data("partial".utf8).write(to: recordingURL)
        await f.queue.recoverAfterLaunch()
        XCTAssertTrue(directoryContents(f.store.mediaDirectory).isEmpty)
        XCTAssertTrue(directoryContents(f.store.recordingDirectory).isEmpty)
    }

    func testUndecryptableMediaFailsPermanently() async throws {
        let f = try makeFixture()
        let photo = try await f.store.store(Data("jpeg".utf8), kind: .snapshot)
        // Corrupt the ciphertext.
        let url = await f.store.encryptedFileURL(for: photo)
        var data = try Data(contentsOf: url)
        data[data.count - 1] ^= 0xFF
        try data.write(to: url)
        await f.queue.enqueue(.photo(media: photo, caption: nil), eventID: nil, artifact: .snapshot, deduplicationKey: "p")
        let summary = await f.queue.processDueItems()
        XCTAssertEqual(summary.failed, 1)
        XCTAssertTrue(f.api.sent.isEmpty)
    }

    func testBackgroundLoopDeliversKickedItems() async throws {
        let f = try makeFixture(clock: TestClock())
        await f.queue.start(pollInterval: 0.05)
        await f.queue.enqueue(.text("a"), eventID: nil, artifact: nil, deduplicationKey: "a")
        await eventually { f.api.sent.count == 1 }
        await f.queue.stop()
    }
}
