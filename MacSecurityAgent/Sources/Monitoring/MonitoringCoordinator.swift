import Foundation
import Observation

/// Dependencies of the coordinator (injected so the whole flow can be tested
/// with fakes).
public struct MonitoringDependencies {
    public var camera: any CameraPipelineControlling
    public var permissions: any CameraAuthorizing
    public var power: any PowerManaging
    public var eventManager: EventManager
    public var uploadQueue: UploadQueue
    public var mediaStore: any MediaStoring
    public var authorization: AuthorizationService
    public var formatter: TelegramMessageFormatter
    public var now: @Sendable () -> Date
    /// Sleep used for warm-up / cooldown timers (tests replace it).
    public var sleep: @Sendable (TimeInterval) async -> Void

    public init(
        camera: any CameraPipelineControlling,
        permissions: any CameraAuthorizing,
        power: any PowerManaging,
        eventManager: EventManager,
        uploadQueue: UploadQueue,
        mediaStore: any MediaStoring,
        authorization: AuthorizationService,
        formatter: TelegramMessageFormatter = TelegramMessageFormatter(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.camera = camera
        self.permissions = permissions
        self.power = power
        self.eventManager = eventManager
        self.uploadQueue = uploadQueue
        self.mediaStore = mediaStore
        self.authorization = authorization
        self.formatter = formatter
        self.now = now
        self.sleep = sleep
    }
}

/// Orchestrates camera, motion events, recording, uploads and power.
///
/// All state lives on the main actor, which serialises every operation. Long
/// running work (camera start, encryption, uploads) is awaited, and a
/// `generation` counter invalidates continuations of an operation that was
/// superseded (for example Stop pressed while the camera was still starting).
@MainActor
@Observable
public final class MonitoringCoordinator {
    // MARK: Observable state
    public private(set) var phase: MonitoringPhase = .disarmed
    public private(set) var cameraStatus: CameraStatus = .inactive
    public private(set) var cameraDeviceName: String?
    public private(set) var telegramStatus: TelegramStatus = .notConfigured
    public private(set) var isNetworkAvailable = true
    public private(set) var pendingUploadCount = 0
    public private(set) var lastEvent: SecurityEvent?
    public private(set) var recentEvents: [SecurityEvent] = []
    public private(set) var lastErrorMessage: String?
    public private(set) var armedSince: Date?
    public private(set) var displaySleepCompatibility: DisplaySleepCompatibility = .notTested
    public private(set) var settings: ApplicationSettings

    public var displayState: MonitoringState {
        MonitoringState.derive(
            phase: phase, cameraStatus: cameraStatus,
            isNetworkAvailable: isNetworkAvailable, pendingUploads: pendingUploadCount
        )
    }

    public var canArm: Bool {
        phase == .disarmed || phase.isError
    }

    public var canDisarm: Bool {
        !canArm || phase.isError
    }

    // MARK: Configuration
    /// Seconds after arming before triggers are accepted (auto-exposure and
    /// white balance settle; lets the owner leave the room).
    public var armingWarmup: TimeInterval = 3
    /// Camera health thresholds.
    public var stallThreshold: TimeInterval = 5
    public var displaySleepProbeDelay: TimeInterval = 15
    public var unauthorizedNoticeInterval: TimeInterval = 600

    // MARK: Private state
    private let deps: MonitoringDependencies
    private let logger = AppLogger(category: "Coordinator")
    private var generation = 0
    private var activeEventID: EventID?
    private var activeRecordingURL: URL?
    private var eventStreamTask: Task<Void, Never>?
    private var gateTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var displayProbeTask: Task<Void, Never>?
    private var displayIsAsleep = false
    private var stallReported = false
    private var lastCameraRestart: Date?
    private var unauthorizedNotices: [Int64: Date] = [:]
    private var launched = false
    private var refreshSequence = 0

    public init(dependencies: MonitoringDependencies, settings: ApplicationSettings) {
        self.deps = dependencies
        self.settings = settings.validated()
    }

    // MARK: Lifecycle

    /// Called once at application launch. Recovers pending uploads and
    /// interrupted events. **Never** starts the camera.
    public func launch() async {
        guard !launched else { return }
        launched = true
        await deps.uploadQueue.setRetention(settings.mediaRetentionInterval)
        await deps.uploadQueue.setEventHandler { [weak self] event in
            await self?.handle(event)
        }
        _ = await deps.eventManager.recoverInterruptedEvents()
        await deps.uploadQueue.recoverAfterLaunch()
        await deps.uploadQueue.start()
        pendingUploadCount = await deps.uploadQueue.pendingCount
        await refreshEvents()
    }

    /// Starts the once-per-second camera health check.
    public func startHealthMonitoring(interval: TimeInterval = 1) {
        healthTask?.cancel()
        let sleep = deps.sleep
        healthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await sleep(interval)
                guard let self else { return }
                self.checkCameraHealth()
            }
        }
    }

    // MARK: Arming

    /// Arms monitoring. Requires a `LocalActivationRequest`, i.e. a local UI
    /// action; there is no remote path to this method.
    public func arm(_ request: LocalActivationRequest) async {
        guard deps.authorization.consume(request) else {
            lastErrorMessage = MonitoringFailure.activationRejected.userMessage
            logger.warning("Rejected arming request")
            return
        }
        guard canArm, transition(to: .arming) else { return }
        generation += 1
        let token = generation
        lastErrorMessage = nil
        cameraStatus = .starting

        var permission = deps.permissions.currentStatus()
        if permission == .notDetermined {
            permission = await deps.permissions.requestAccess()
        }
        guard token == generation else { return }
        guard permission == .authorized else {
            cameraStatus = .inactive
            fail(.cameraPermissionDenied)
            return
        }

        do {
            try deps.power.beginMonitoring(keepDisplayAwake: settings.keepDisplayAwake)
        } catch {
            cameraStatus = .inactive
            fail(.powerAssertionFailed(error.localizedDescription))
            return
        }

        do {
            let stream = try await deps.camera.start(configuration: settings.cameraConfiguration)
            guard token == generation else {
                // Stop was pressed while the camera was starting.
                await deps.camera.stop()
                return
            }
            consume(stream)
            guard transition(to: .armed) else { return }
            armedSince = deps.now()
            stallReported = false
            logger.info("Monitoring armed")
            if settings.notifications.notifyArmingChanges {
                await enqueueNotice(deps.formatter.armed(at: deps.now()), key: "arm-\(UUID().uuidString)")
            }
            scheduleTriggerGate(after: armingWarmup)
        } catch {
            deps.power.endMonitoring()
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            cameraStatus = .unavailable(message)
            fail(.cameraUnavailable(message))
        }
    }

    /// Normal stop: finishes (and still delivers) an in-progress recording.
    public func disarm() async {
        await stop(emergency: false)
    }

    /// Emergency stop: immediately releases the camera and discards an
    /// in-progress recording. Already queued uploads are still delivered.
    public func emergencyStop() async {
        await stop(emergency: true)
    }

    /// Called from `applicationShouldTerminate`. Finalises a recording so it
    /// can be delivered after the next launch.
    public func prepareForTermination() async {
        if phase != .disarmed {
            await stop(emergency: false, notify: false)
        }
        await deps.uploadQueue.stop()
        healthTask?.cancel()
    }

    private func stop(emergency: Bool, notify: Bool = true) async {
        guard phase != .disarmed, phase != .stopping else { return }
        let wasArmed = phase.isCameraPhase || phase == .arming
        generation += 1
        let previous = phase
        guard transition(to: .stopping) else { return }
        gateTask?.cancel()
        displayProbeTask?.cancel()
        await deps.camera.setMotionTriggersEnabled(false)

        if previous == .recording || activeRecordingURL != nil {
            if let outcome = await deps.camera.finishRecording(discard: emergency) {
                await process(outcome)
            }
        }
        if activeEventID != nil {
            await deps.eventManager.interruptActiveEvent(reason: emergency ? "Emergency stop" : "Monitoring stopped")
            activeEventID = nil
        }

        await deps.camera.stop()
        deps.power.endMonitoring()
        cameraStatus = .inactive
        armedSince = nil
        stallReported = false
        _ = transition(to: .disarmed)
        logger.info(emergency ? "Emergency stop" : "Monitoring disarmed")
        if notify, wasArmed, settings.notifications.notifyArmingChanges {
            await enqueueNotice(deps.formatter.disarmed(at: deps.now(), emergency: emergency), key: "disarm-\(UUID().uuidString)")
        }
        await refreshEvents()
    }

    // MARK: Settings

    public func apply(settings newSettings: ApplicationSettings) async {
        let validated = newSettings.validated()
        let old = settings
        settings = validated
        await deps.eventManager.setCooldownInterval(validated.eventCooldownSeconds)
        await deps.uploadQueue.setRetention(validated.mediaRetentionInterval)
        if old.motionConfiguration != validated.motionConfiguration, phase.isCameraPhase {
            await deps.camera.updateMotionConfiguration(validated.motionConfiguration)
        }
        if old.keepDisplayAwake != validated.keepDisplayAwake, phase.isCameraPhase {
            try? deps.power.setKeepDisplayAwake(validated.keepDisplayAwake)
        }
        if old.authorizedTelegramUserID != validated.authorizedTelegramUserID {
            await deps.uploadQueue.configurationChanged()
        }
        // Resolution / duration changes apply the next time monitoring is armed.
    }

    // MARK: Connectivity

    public func networkAvailabilityChanged(_ available: Bool) async {
        isNetworkAvailable = available
        await deps.uploadQueue.setNetworkAvailable(available)
    }

    public func telegramStatusChanged(_ status: TelegramStatus) {
        telegramStatus = status
    }

    public func telegramConfigurationChanged() async {
        await deps.uploadQueue.configurationChanged()
    }

    public func reportUnauthorizedAttempt(userID: Int64?) async {
        guard settings.notifications.notifyUnauthorizedAttempts else { return }
        let key = userID ?? 0
        let date = deps.now()
        if let last = unauthorizedNotices[key], date.timeIntervalSince(last) < unauthorizedNoticeInterval { return }
        unauthorizedNotices[key] = date
        await enqueueNotice(deps.formatter.unauthorizedAttempt(userID: userID), key: "unauthorized-\(key)-\(Int(date.timeIntervalSince1970))")
    }

    // MARK: Camera events

    private func consume(_ stream: AsyncStream<CameraPipelineEvent>) {
        eventStreamTask = Task { @MainActor [weak self] in
            for await event in stream {
                await self?.handle(event)
            }
        }
    }

    public func handle(_ event: CameraPipelineEvent) async {
        switch event {
        case .started(let name):
            cameraDeviceName = name
        case .motionTriggered(let trigger):
            await handleMotion(trigger)
        case .recordingFinished(let outcome):
            await process(outcome)
        case .failed(let failure):
            await handleCameraFailure(failure)
        }
    }

    private func handleMotion(_ trigger: MotionTrigger) async {
        guard phase == .armed else { return }
        let result = await deps.eventManager.beginEvent(
            changedFraction: trigger.analysis.changedFraction, detectedAt: trigger.capturedAt
        )
        switch result {
        case .rejectedCooldown(let remaining):
            scheduleTriggerGate(after: remaining)
            return
        case .rejectedEventInProgress:
            return
        case .started(var event):
            guard phase == .armed, transition(to: .motionDetected) else {
                await deps.eventManager.interruptActiveEvent(reason: "Monitoring stopped")
                return
            }
            activeEventID = event.id
            lastEvent = event
            let prefs = settings.notifications
            let willRecord = prefs.sendVideo

            // 1. Text alert (smallest payload, arrives first).
            if prefs.sendTextAlert {
                let text = deps.formatter.motionAlert(
                    event: event, recordingStarted: willRecord, snapshotEnabled: prefs.sendSnapshot && trigger.snapshotJPEG != nil
                )
                await deps.uploadQueue.enqueue(.text(text), eventID: event.id, artifact: .alert, deduplicationKey: "\(event.id).alert")
                await deps.eventManager.setStatus(.queued, for: .alert, of: event.id)
            } else {
                await deps.eventManager.setStatus(.skipped("Disabled in settings"), for: .alert, of: event.id)
            }

            // 2. Snapshot: encrypted, queued and sent immediately.
            if prefs.sendSnapshot, let jpeg = trigger.snapshotJPEG {
                do {
                    let media = try await deps.mediaStore.store(jpeg, kind: .snapshot)
                    await deps.eventManager.update(event.id) { $0.stage = .snapshotCaptured }
                    await deps.uploadQueue.enqueue(
                        .photo(media: media, caption: deps.formatter.snapshotCaption(event: event)),
                        eventID: event.id, artifact: .snapshot, deduplicationKey: "\(event.id).snapshot"
                    )
                    await deps.eventManager.setStatus(.queued, for: .snapshot, of: event.id)
                } catch {
                    await deps.eventManager.setStatus(.failed("Could not store snapshot"), for: .snapshot, of: event.id)
                }
            } else {
                let reason = prefs.sendSnapshot ? "Snapshot unavailable" : "Disabled in settings"
                await deps.eventManager.setStatus(prefs.sendSnapshot ? .failed(reason) : .skipped(reason), for: .snapshot, of: event.id)
            }
            deps.uploadQueue.kick()

            // 3. Recording.
            guard phase == .motionDetected else { return }
            guard willRecord else {
                await deps.eventManager.setStatus(.skipped("Disabled in settings"), for: .video, of: event.id)
                await finishEvent(event.id)
                return
            }
            do {
                let url = try await deps.mediaStore.makeRecordingURL(for: event.id)
                guard phase == .motionDetected else { return }
                try await deps.camera.startRecording(eventID: event.id, to: url)
                activeRecordingURL = url
                if let updated = await deps.eventManager.markRecordingStarted(event.id) { event = updated }
                lastEvent = event
                _ = transition(to: .recording)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await deps.eventManager.setStatus(.failed(message), for: .video, of: event.id)
                await finishEvent(event.id)
            }
            await refreshEvents()
        }
    }

    /// Encrypts the finished recording into the queue and closes the event.
    private func process(_ outcome: RecordingOutcome) async {
        let id = outcome.eventID
        activeRecordingURL = nil
        switch outcome {
        case .finished(_, let url, let duration, _):
            do {
                let media = try await deps.mediaStore.importRecording(at: url)
                let event = await deps.eventManager.markRecordingFinished(id, duration: duration)
                let caption = event.map { deps.formatter.videoCaption(event: $0, duration: duration) }
                let video = settings.videoSettings
                await deps.uploadQueue.enqueue(
                    .video(media: media, caption: caption, durationSeconds: Int(duration.rounded()), width: video.width, height: video.height),
                    eventID: id, artifact: .video, deduplicationKey: "\(id).video"
                )
                await deps.eventManager.setStatus(.queued, for: .video, of: id)
            } catch {
                await deps.mediaStore.discardRecording(at: url)
                await deps.eventManager.setStatus(.failed("Could not store recording"), for: .video, of: id)
            }
        case .failed(_, let message):
            await deps.eventManager.setStatus(.failed(message), for: .video, of: id)
        case .discarded:
            await deps.eventManager.setStatus(.skipped("Discarded by emergency stop"), for: .video, of: id)
        }
        await finishEvent(id)
    }

    private func finishEvent(_ id: EventID) async {
        await deps.eventManager.finishActiveEvent(id)
        if activeEventID == id { activeEventID = nil }
        if phase == .recording || phase == .motionDetected {
            _ = transition(to: .armed)
            scheduleTriggerGate(after: settings.eventCooldownSeconds)
        }
        await refreshEvents()
    }

    private func handleCameraFailure(_ failure: CameraFailure) async {
        guard phase.isCameraPhase || phase == .arming else { return }
        logger.error(failure.message)
        let generationAtFailure = generation
        if phase == .recording, let outcome = await deps.camera.finishRecording(discard: false) {
            await process(outcome)
        }
        guard generationAtFailure == generation else { return }
        await deps.camera.stop()
        deps.power.endMonitoring()
        cameraStatus = .unavailable(failure.message)
        armedSince = nil
        fail(.cameraUnavailable(failure.message))
        if settings.notifications.notifyCameraProblems {
            await enqueueNotice(deps.formatter.cameraProblem(failure.message, at: deps.now()), key: "camera-\(UUID().uuidString)")
        }
    }

    // MARK: Health / power

    /// Never reports the camera as active when frames stopped arriving.
    public func checkCameraHealth() {
        guard phase.isCameraPhase else { return }
        switch deps.camera.frameHealth.evaluate(stallThreshold: stallThreshold) {
        case .healthy:
            if cameraStatus != .active {
                let wasStalled = cameraStatus == .stalled
                cameraStatus = .active
                if wasStalled {
                    stallReported = false
                    lastErrorMessage = nil
                    if settings.notifications.notifyCameraProblems {
                        Task { await enqueueNotice(deps.formatter.cameraRecovered(at: deps.now()), key: "recovered-\(UUID().uuidString)") }
                    }
                }
            }
        case .waitingForFirstFrame, .inactive:
            break
        case .stalled:
            guard cameraStatus != .stalled else {
                restartStalledCameraIfNeeded()
                return
            }
            cameraStatus = .stalled
            lastErrorMessage = MonitoringFailure.cameraStalled.userMessage
            if !stallReported {
                stallReported = true
                if settings.notifications.notifyCameraProblems {
                    Task {
                        await enqueueNotice(
                            deps.formatter.cameraProblem("No camera frames for \(Int(stallThreshold)) s.", at: deps.now()),
                            key: "stall-\(UUID().uuidString)"
                        )
                    }
                }
            }
        }
    }

    private func restartStalledCameraIfNeeded() {
        let date = deps.now()
        if let last = lastCameraRestart, date.timeIntervalSince(last) < 120 { return }
        guard phase == .armed, !displayIsAsleep else { return }
        lastCameraRestart = date
        Task { await restartCamera() }
    }

    /// Restarts the capture session (after system wake or a stall).
    public func restartCamera() async {
        guard phase == .armed else { return }
        generation += 1
        let token = generation
        await deps.camera.stop()
        cameraStatus = .starting
        do {
            let stream = try await deps.camera.start(configuration: settings.cameraConfiguration)
            guard token == generation, phase == .armed else {
                await deps.camera.stop()
                return
            }
            consume(stream)
            scheduleTriggerGate(after: armingWarmup)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await handleCameraFailure(.runtimeError(message))
        }
    }

    public func displayDidSleep() {
        displayIsAsleep = true
        guard phase.isCameraPhase else { return }
        displayProbeTask?.cancel()
        let framesAtSleep = deps.camera.frameHealth.frameCount
        let delay = displaySleepProbeDelay
        let sleep = deps.sleep
        displaySleepCompatibility = .testing
        displayProbeTask = Task { @MainActor [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            self.evaluateDisplaySleepProbe(framesAtSleep: framesAtSleep)
        }
    }

    func evaluateDisplaySleepProbe(framesAtSleep: Int) {
        guard displayIsAsleep, phase.isCameraPhase else { return }
        if deps.camera.frameHealth.frameCount > framesAtSleep {
            displaySleepCompatibility = .verified(deps.now())
            logger.info("Display sleep compatibility verified: camera frames continue")
        } else {
            displaySleepCompatibility = .interruptsCamera(deps.now())
            logger.warning("Display sleep interrupted camera frames; keeping display awake")
            deps.power.wakeDisplay()
            try? deps.power.setKeepDisplayAwake(true)
            if settings.notifications.notifyCameraProblems {
                Task { await enqueueNotice(deps.formatter.displaySleepInterruptsCamera(), key: "display-\(UUID().uuidString)") }
            }
        }
    }

    public func displayDidWake() {
        displayIsAsleep = false
        if displaySleepCompatibility == .testing {
            displaySleepCompatibility = .notTested
        }
        displayProbeTask?.cancel()
    }

    public func systemWillSleep() {
        guard phase.isCameraPhase else { return }
        cameraStatus = .inactive
        if settings.notifications.notifyCameraProblems {
            Task { await enqueueNotice(deps.formatter.systemSleeping(at: deps.now()), key: "sleep-\(UUID().uuidString)") }
        }
    }

    public func systemDidWake() async {
        guard phase.isCameraPhase else { return }
        if phase == .recording, let outcome = await deps.camera.finishRecording(discard: false) {
            await process(outcome)
        }
        if settings.notifications.notifyCameraProblems {
            await enqueueNotice(deps.formatter.systemWoke(at: deps.now()), key: "wake-\(UUID().uuidString)")
        }
        await restartCamera()
    }

    // MARK: Upload events

    public func handle(_ event: UploadQueueEvent) async {
        switch event {
        case .pendingCountChanged(let count):
            pendingUploadCount = count
        case .uploading(let item):
            if let id = item.eventID, let artifact = item.artifact {
                await deps.eventManager.setStatus(.uploading, for: artifact, of: id)
            }
        case .delivered(let item, _):
            telegramStatus = .connected
            if let id = item.eventID, let artifact = item.artifact {
                await deps.eventManager.setStatus(.delivered, for: artifact, of: id)
                await refreshEvents()
            }
        case .retryScheduled(let item, _, _):
            if let id = item.eventID, let artifact = item.artifact {
                await deps.eventManager.setStatus(.queued, for: artifact, of: id)
            }
        case .failed(let item, let reason):
            lastErrorMessage = "Upload failed: \(reason)"
            if let id = item.eventID, let artifact = item.artifact {
                await deps.eventManager.setStatus(.failed(reason), for: artifact, of: id)
                if artifact != .alert, settings.notifications.notifyDeliveryFailures {
                    await enqueueNotice(
                        deps.formatter.deliveryFailed(eventID: id, artifact: artifact, reason: reason),
                        key: "\(id).\(artifact.rawValue).failure"
                    )
                }
                await refreshEvents()
            }
        case .expired(let item):
            lastErrorMessage = "An upload expired after the retention period."
            if let id = item.eventID, let artifact = item.artifact {
                await deps.eventManager.setStatus(.expired, for: artifact, of: id)
                if artifact != .alert, settings.notifications.notifyDeliveryFailures {
                    await enqueueNotice(
                        deps.formatter.deliveryExpired(eventID: id, artifact: artifact),
                        key: "\(id).\(artifact.rawValue).expired"
                    )
                }
                await refreshEvents()
            }
        case .configurationProblem(let message):
            telegramStatus = .error(message)
            lastErrorMessage = "Telegram: \(message)"
        }
    }

    // MARK: Status for /status

    public func statusReport(powerSource: PowerSourceState? = nil) -> StatusReport {
        StatusReport(
            monitoring: displayState,
            camera: cameraStatus,
            networkAvailable: isNetworkAvailable,
            telegram: telegramStatus,
            lastEvent: lastEvent,
            pendingUploads: pendingUploadCount,
            armedSince: armedSince,
            powerSource: powerSource ?? deps.power.currentPowerSource(),
            displaySleep: displaySleepCompatibility
        )
    }

    public func clearEventHistory() async {
        await deps.eventManager.clearHistory()
        await refreshEvents()
    }

    public func refreshEvents() async {
        // Refreshes can overlap (upload callbacks, camera events); only the
        // most recently started one may publish its result.
        refreshSequence += 1
        let sequence = refreshSequence
        let events = await deps.eventManager.recentEvents(limit: 50)
        guard sequence == refreshSequence else { return }
        recentEvents = events
        lastEvent = events.first
    }

    // MARK: Helpers

    @discardableResult
    private func transition(to next: MonitoringPhase) -> Bool {
        guard phase.canTransition(to: next) else {
            logger.warning("Refused transition \(String(describing: phase)) → \(String(describing: next))")
            return false
        }
        phase = next
        return true
    }

    private func fail(_ failure: MonitoringFailure) {
        lastErrorMessage = failure.userMessage
        if !transition(to: .error(failure)) {
            phase = .error(failure)
        }
    }

    /// Re-opens the motion trigger gate after `delay` if still armed.
    private func scheduleTriggerGate(after delay: TimeInterval) {
        gateTask?.cancel()
        let token = generation
        let sleep = deps.sleep
        let camera = deps.camera
        gateTask = Task { @MainActor [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self, token == self.generation, self.phase == .armed else { return }
            await camera.setMotionTriggersEnabled(true)
        }
    }

    private func enqueueNotice(_ text: String, key: String) async {
        await deps.uploadQueue.enqueue(.text(text), eventID: nil, artifact: nil, deduplicationKey: key)
    }
}

/// Adapts the main-actor coordinator for the Telegram command handler.
public struct CoordinatorStatusReporter: StatusReporting {
    private let coordinator: MonitoringCoordinator

    public init(coordinator: MonitoringCoordinator) {
        self.coordinator = coordinator
    }

    public func statusReport() async -> StatusReport {
        await coordinator.statusReport()
    }

    public func recentEvents(limit: Int) async -> [SecurityEvent] {
        await Array(coordinator.recentEvents.prefix(limit))
    }
}
