import Foundation
import XCTest
@testable import MacSecurityCore

// MARK: - Clock

final class TestClock: @unchecked Sendable {
    private let date: LockedValue<Date>
    private let uptime: LockedValue<TimeInterval>

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        date = LockedValue(start)
        uptime = LockedValue(1000)
    }

    var now: Date { date.current }
    var monotonic: TimeInterval { uptime.current }

    func advance(_ seconds: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(seconds) }
        uptime.withLock { $0 += seconds }
    }

    var nowProvider: @Sendable () -> Date { { [self] in self.now } }
    var monotonicProvider: @Sendable () -> TimeInterval { { [self] in self.monotonic } }
}

// MARK: - Files

func makeTemporaryDirectory(_ name: String = #function) throws -> URL {
    let safe = name.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("msa-tests-\(safe)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func directoryContents(_ url: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
}

/// Polls `condition` until it holds or the timeout expires.
@MainActor
func eventually(
    timeout: TimeInterval = 3,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    let satisfied = await condition()
    XCTAssertTrue(satisfied, "Condition not met within \(timeout) s", file: file, line: line)
}

// MARK: - Telegram

final class MockTelegramAPI: TelegramAPI, @unchecked Sendable {
    struct Sent: Equatable {
        enum Kind: String { case message, photo, video }
        let kind: Kind
        let chatID: Int64
        let text: String?
        let byteCount: Int
        let data: Data?
    }

    private struct State {
        var sent: [Sent] = []
        var failures: [TelegramError] = []
        var scriptedUpdates: [[TelegramUpdate]] = []
        var getUpdatesOffsets: [Int64?] = []
        var nextMessageID = 1
        var getUpdatesError: TelegramError?
    }

    private let state = LockedValue(State())

    var sent: [Sent] { state.current.sent }
    var getUpdatesOffsets: [Int64?] { state.current.getUpdatesOffsets }

    func failNext(_ error: TelegramError, times: Int = 1) {
        state.withLock { $0.failures.append(contentsOf: Array(repeating: error, count: times)) }
    }

    func setGetUpdatesError(_ error: TelegramError?) {
        state.withLock { $0.getUpdatesError = error }
    }

    func script(updates: [TelegramUpdate]) {
        state.withLock { $0.scriptedUpdates.append(updates) }
    }

    private func record(_ kind: Sent.Kind, chatID: Int64, text: String?, data: Data?) throws -> TelegramMessage {
        try state.withLock { state -> TelegramMessage in
            if !state.failures.isEmpty {
                throw state.failures.removeFirst()
            }
            state.sent.append(Sent(kind: kind, chatID: chatID, text: text, byteCount: data?.count ?? 0, data: data))
            defer { state.nextMessageID += 1 }
            return TelegramMessage(
                messageId: state.nextMessageID, from: nil,
                chat: TelegramChat(id: chatID, type: "private"), date: 0, text: text
            )
        }
    }

    func sendMessage(chatID: Int64, text: String) async throws -> TelegramMessage {
        try record(.message, chatID: chatID, text: text, data: nil)
    }

    func sendPhoto(chatID: Int64, jpegData: Data, caption: String?) async throws -> TelegramMessage {
        try record(.photo, chatID: chatID, text: caption, data: jpegData)
    }

    func sendVideo(
        chatID: Int64, mp4Data: Data, caption: String?, durationSeconds: Int?, width: Int?, height: Int?
    ) async throws -> TelegramMessage {
        try record(.video, chatID: chatID, text: caption, data: mp4Data)
    }

    func getMe() async throws -> TelegramUser {
        TelegramUser(id: 42, isBot: true, firstName: "Agent", username: "TestAgentBot")
    }

    func getUpdates(offset: Int64?, timeoutSeconds: Int, limit: Int) async throws -> [TelegramUpdate] {
        try state.withLock { state -> [TelegramUpdate] in
            state.getUpdatesOffsets.append(offset)
            if let error = state.getUpdatesError { throw error }
            if state.scriptedUpdates.isEmpty { return [] }
            return state.scriptedUpdates.removeFirst()
        }
    }
}

final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let requests = LockedValue<[HTTPRequest]>([])
    private let responses = LockedValue<[Result<HTTPResponse, TelegramError>]>([])

    var received: [HTTPRequest] { requests.current }

    func enqueue(status: Int = 200, json: String) {
        responses.withLock { $0.append(.success(HTTPResponse(statusCode: status, body: Data(json.utf8)))) }
    }

    func enqueue(error: TelegramError) {
        responses.withLock { $0.append(.failure(error)) }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.withLock { $0.append(request) }
        let next = responses.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        switch next {
        case .success(let response): return response
        case .failure(let error): throw error
        case nil: return HTTPResponse(statusCode: 500, body: Data())
        }
    }
}

let ownerID: Int64 = 123_456_789

func makeUpdate(
    id: Int64,
    text: String,
    from userID: Int64 = ownerID,
    chatID: Int64? = nil,
    chatType: String = "private",
    isBot: Bool = false,
    date: Date
) -> TelegramUpdate {
    TelegramUpdate(
        updateId: id,
        message: TelegramMessage(
            messageId: Int(id),
            from: TelegramUser(id: userID, isBot: isBot, firstName: "Someone"),
            chat: TelegramChat(id: chatID ?? userID, type: chatType),
            date: Int(date.timeIntervalSince1970),
            text: text
        )
    )
}

// MARK: - Camera / permissions / power

final class FakePermissions: CameraAuthorizing, @unchecked Sendable {
    private let status: LockedValue<CameraPermissionStatus>
    private let grantOnRequest: Bool
    private let requests = LockedValue(0)

    init(_ status: CameraPermissionStatus, grantOnRequest: Bool = true) {
        self.status = LockedValue(status)
        self.grantOnRequest = grantOnRequest
    }

    var requestCount: Int { requests.current }

    func currentStatus() -> CameraPermissionStatus { status.current }

    func requestAccess() async -> CameraPermissionStatus {
        requests.withLock { $0 += 1 }
        if status.current == .notDetermined {
            status.set(grantOnRequest ? .authorized : .denied)
        }
        return status.current
    }
}

final class FakeCamera: CameraPipelineControlling, @unchecked Sendable {
    struct State {
        var running = false
        var startCount = 0
        var stopCount = 0
        var triggersEnabled = false
        var recordingEventID: EventID?
        var recordingURL: URL?
        var recordingsStarted = 0
        var startError: CameraError?
        var startDelay: TimeInterval = 0
        var continuation: AsyncStream<CameraPipelineEvent>.Continuation?
        var lastConfiguration: CameraConfiguration?
    }

    let frameHealth: FrameHealthMonitor
    let state = LockedValue(State())
    static let fakeVideoBytes = Data(repeating: 0xAB, count: 4096)

    init(clock: TestClock) {
        frameHealth = FrameHealthMonitor(clock: clock.monotonicProvider)
    }

    var isRunning: Bool { state.current.running }
    var triggersEnabled: Bool { state.current.triggersEnabled }
    var isRecording: Bool { state.current.recordingEventID != nil }

    func start(configuration: CameraConfiguration) async throws -> AsyncStream<CameraPipelineEvent> {
        let delay = state.current.startDelay
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let error = state.current.startError { throw error }
        let (stream, continuation) = AsyncStream<CameraPipelineEvent>.makeStream()
        state.withLock {
            $0.running = true
            $0.startCount += 1
            $0.continuation = continuation
            $0.triggersEnabled = false
            $0.lastConfiguration = configuration
        }
        frameHealth.markStarted()
        frameHealth.recordFrame()
        continuation.yield(.started(deviceName: "FaceTime HD Camera (fake)"))
        return stream
    }

    func stop() async {
        let continuation = state.withLock { state -> AsyncStream<CameraPipelineEvent>.Continuation? in
            state.running = false
            state.stopCount += 1
            state.triggersEnabled = false
            if let url = state.recordingURL { try? FileManager.default.removeItem(at: url) }
            state.recordingEventID = nil
            state.recordingURL = nil
            defer { state.continuation = nil }
            return state.continuation
        }
        frameHealth.markStopped()
        continuation?.finish()
    }

    func setMotionTriggersEnabled(_ enabled: Bool) async {
        state.withLock { $0.triggersEnabled = enabled }
    }

    func updateMotionConfiguration(_ configuration: MotionDetectorConfiguration) async {
        state.withLock { $0.lastConfiguration?.motion = configuration }
    }

    func startRecording(eventID: EventID, to url: URL) async throws {
        try state.withLock { state in
            guard state.running else { throw CameraError.notRunning }
            guard state.recordingEventID == nil else { throw CameraError.alreadyRecording }
            state.recordingEventID = eventID
            state.recordingURL = url
            state.recordingsStarted += 1
        }
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    func finishRecording(discard: Bool) async -> RecordingOutcome? {
        takeRecording(discard: discard, duration: 12)
    }

    func isCapturing() async -> Bool { state.current.running }

    // MARK: Test drivers

    /// Simulates a motion trigger; respects the trigger gate like the real
    /// pipeline does.
    @discardableResult
    func simulateMotion(jpeg: Data? = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]), at date: Date, respectGate: Bool = true) -> Bool {
        let continuation = state.withLock { state -> AsyncStream<CameraPipelineEvent>.Continuation? in
            guard state.running else { return nil }
            if respectGate {
                guard state.triggersEnabled, state.recordingEventID == nil else { return nil }
                state.triggersEnabled = false
            }
            return state.continuation
        }
        guard let continuation else { return false }
        let analysis = MotionAnalysis(
            changedFraction: 0.05, meanLuminance: 100, meanLuminanceDelta: 0, isBaseline: false,
            isLightingChange: false, isQualifying: true, consecutiveQualifyingFrames: 3, triggered: true
        )
        continuation.yield(.motionTriggered(MotionTrigger(analysis: analysis, snapshotJPEG: jpeg, capturedAt: date)))
        return true
    }

    /// Simulates the recorder reaching its configured duration.
    func simulateRecordingCompleted(duration: TimeInterval = 30) {
        guard let outcome = takeRecording(discard: false, duration: duration) else { return }
        state.current.continuation?.yield(.recordingFinished(outcome))
    }

    func simulateFailure(_ failure: CameraFailure) {
        state.current.continuation?.yield(.failed(failure))
    }

    private func takeRecording(discard: Bool, duration: TimeInterval) -> RecordingOutcome? {
        state.withLock { state -> RecordingOutcome? in
            guard let id = state.recordingEventID, let url = state.recordingURL else { return nil }
            state.recordingEventID = nil
            state.recordingURL = nil
            if discard {
                try? FileManager.default.removeItem(at: url)
                return .discarded(eventID: id)
            }
            try? FakeCamera.fakeVideoBytes.write(to: url)
            return .finished(eventID: id, fileURL: url, duration: duration, frameCount: Int(duration * 15))
        }
    }
}

@MainActor
final class FakePower: PowerManaging {
    var isPreventingSystemSleep = false
    var isPreventingDisplaySleep = false
    var beginCount = 0
    var endCount = 0
    var wakeCount = 0
    var failOnBegin = false

    func beginMonitoring(keepDisplayAwake: Bool) throws {
        if failOnBegin { throw PowerManagerError.assertionFailed(-1) }
        beginCount += 1
        isPreventingSystemSleep = true
        isPreventingDisplaySleep = keepDisplayAwake
    }

    func setKeepDisplayAwake(_ keepAwake: Bool) throws {
        isPreventingDisplaySleep = keepAwake
    }

    func wakeDisplay() { wakeCount += 1 }

    func endMonitoring() {
        endCount += 1
        isPreventingSystemSleep = false
        isPreventingDisplaySleep = false
    }

    func currentPowerSource() -> PowerSourceState { .ac }
}

// MARK: - Coordinator harness

@MainActor
final class CoordinatorHarness {
    let clock = TestClock()
    let directory: URL
    let camera: FakeCamera
    let permissions: FakePermissions
    let power = FakePower()
    let api = MockTelegramAPI()
    let telegram: TelegramConfigurationStore
    let mediaStore: TemporaryMediaStore
    let queue: UploadQueue
    let repository: EventRepository
    let eventManager: EventManager
    let authorization: AuthorizationService
    let coordinator: MonitoringCoordinator
    let secureStorage: InMemorySecureStorage

    init(
        settings: ApplicationSettings = CoordinatorHarness.defaultSettings,
        permission: CameraPermissionStatus = .authorized,
        directory: URL? = nil,
        secureStorage: InMemorySecureStorage = InMemorySecureStorage()
    ) throws {
        self.directory = try directory ?? makeTemporaryDirectory("coordinator")
        self.secureStorage = secureStorage
        camera = FakeCamera(clock: clock)
        permissions = FakePermissions(permission)
        telegram = TelegramConfigurationStore(session: TelegramSession(api: api, ownerUserID: ownerID, botUsername: "TestAgentBot"))
        mediaStore = try TemporaryMediaStore(
            rootDirectory: self.directory.appendingPathComponent("Queue"),
            keyProvider: MediaKeyProvider(storage: secureStorage),
            now: clock.nowProvider
        )
        queue = UploadQueue(
            indexURL: self.directory.appendingPathComponent("Queue/index.json"),
            mediaStore: mediaStore,
            sessionProvider: telegram,
            policy: RetryPolicy(baseDelay: 0.01, maximumDelay: 0.05, multiplier: 2, jitter: 0),
            now: { Date() },
            random: { 0.5 }
        )
        repository = EventRepository(fileURL: self.directory.appendingPathComponent("events.json"))
        eventManager = EventManager(repository: repository, cooldownInterval: settings.eventCooldownSeconds, now: clock.nowProvider)
        authorization = AuthorizationService(now: clock.nowProvider)
        let dependencies = MonitoringDependencies(
            camera: camera, permissions: permissions, power: power, eventManager: eventManager,
            uploadQueue: queue, mediaStore: mediaStore, authorization: authorization,
            formatter: TelegramMessageFormatter(timeZone: TimeZone(identifier: "UTC")!),
            now: clock.nowProvider,
            sleep: { _ in await Task.yield() }
        )
        coordinator = MonitoringCoordinator(dependencies: dependencies, settings: settings)
        coordinator.armingWarmup = 0
    }

    static var defaultSettings: ApplicationSettings {
        var settings = ApplicationSettings()
        settings.authorizedTelegramUserID = ownerID
        settings.notifications.notifyArmingChanges = false
        return settings
    }

    func arm() async {
        await coordinator.arm(authorization.makeLocalActivationRequest(origin: .menuBar))
    }

    func waitForTriggerGate() async {
        await eventually { self.camera.triggersEnabled }
    }

    var encryptedMediaFiles: [URL] { directoryContents(mediaStore.mediaDirectory) }
    var plaintextRecordings: [URL] { directoryContents(mediaStore.recordingDirectory) }
}
