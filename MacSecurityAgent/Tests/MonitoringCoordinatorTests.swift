import XCTest
@testable import MacSecurityCore

/// End-to-end scenarios of the monitoring flow with a fake camera and a mock
/// Telegram API (real encrypted media store, upload queue and repository).
@MainActor
final class MonitoringCoordinatorTests: XCTestCase, @unchecked Sendable {
    // Scenario 1
    func testLaunchNeverActivatesCamera() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.launch()
        XCTAssertEqual(h.coordinator.phase, .disarmed)
        XCTAssertEqual(h.camera.state.current.startCount, 0)
        XCTAssertEqual(h.permissions.requestCount, 0, "No permission prompt at launch")
        XCTAssertFalse(h.power.isPreventingSystemSleep)
        XCTAssertEqual(h.coordinator.displayState, .disarmed)
    }

    // Scenario 2 (+19 power assertion taken)
    func testArmFromMenuStartsCameraAndPreventsIdleSleep() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.launch()
        await h.arm()
        XCTAssertEqual(h.coordinator.phase, .armed)
        XCTAssertTrue(h.camera.isRunning)
        XCTAssertTrue(h.power.isPreventingSystemSleep)
        XCTAssertFalse(h.power.isPreventingDisplaySleep, "Display may sleep by default")
        XCTAssertNotNil(h.coordinator.armedSince)
        let config = try XCTUnwrap(h.camera.state.current.lastConfiguration)
        XCTAssertEqual(config.captureWidth, 1280)
        XCTAssertEqual(config.captureHeight, 720)
        XCTAssertEqual(config.analysisInterval, 0.2)
        XCTAssertEqual(config.motion.analysisWidth, 320)
        XCTAssertEqual(config.motion.analysisHeight, 180)
        XCTAssertEqual(config.motion.consecutiveFramesRequired, 3)
        XCTAssertEqual(config.video.frameRate, 15)
        XCTAssertEqual(config.video.averageBitRate, 1_200_000)
        XCTAssertEqual(config.video.durationSeconds, 30)
        await h.waitForTriggerGate()
        h.coordinator.checkCameraHealth()
        XCTAssertEqual(h.coordinator.cameraStatus, .active)
    }

    func testArmingRequiresFreshLocalRequest() async throws {
        let h = try CoordinatorHarness()
        let request = h.authorization.makeLocalActivationRequest(origin: .menuBar)
        await h.coordinator.arm(request)
        await h.coordinator.disarm()
        await h.coordinator.arm(request) // replay
        XCTAssertEqual(h.coordinator.phase, .disarmed)
        XCTAssertEqual(h.camera.state.current.startCount, 1)
    }

    func testDoubleArmIsIgnored() async throws {
        let h = try CoordinatorHarness()
        await h.arm()
        await h.arm()
        XCTAssertEqual(h.camera.state.current.startCount, 1)
        XCTAssertEqual(h.power.beginCount, 1)
    }

    // Scenario 3
    func testCameraPermissionDenied() async throws {
        let h = try CoordinatorHarness(permission: .denied)
        await h.arm()
        XCTAssertEqual(h.coordinator.phase, .error(.cameraPermissionDenied))
        XCTAssertEqual(h.camera.state.current.startCount, 0)
        XCTAssertFalse(h.power.isPreventingSystemSleep)
        XCTAssertEqual(h.coordinator.displayState, .error)
        XCTAssertNotNil(h.coordinator.lastErrorMessage)
    }

    func testPermissionIsRequestedOnFirstArm() async throws {
        let h = try CoordinatorHarness(permission: .notDetermined)
        await h.arm()
        XCTAssertEqual(h.permissions.requestCount, 1)
        XCTAssertEqual(h.coordinator.phase, .armed)
    }

    func testCanRetryAfterError() async throws {
        let h = try CoordinatorHarness()
        h.camera.state.withLock { $0.startError = .noCamera }
        await h.arm()
        XCTAssertTrue(h.coordinator.phase.isError)
        h.camera.state.withLock { $0.startError = nil }
        await h.arm()
        XCTAssertEqual(h.coordinator.phase, .armed)
    }

    // Scenario 4
    func testCameraUnavailableAtStart() async throws {
        let h = try CoordinatorHarness()
        h.camera.state.withLock { $0.startError = .noCamera }
        await h.arm()
        XCTAssertEqual(h.coordinator.phase, .error(.cameraUnavailable("No built-in camera was found.")))
        XCTAssertFalse(h.power.isPreventingSystemSleep, "Assertion must be released on failure")
        if case .unavailable = h.coordinator.cameraStatus {} else { XCTFail("Camera should be unavailable") }
    }

    func testCameraDisconnectWhileArmed() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.launch()
        await h.arm()
        h.camera.simulateFailure(.deviceDisconnected)
        await eventually { h.coordinator.phase.isError }
        XCTAssertFalse(h.camera.isRunning)
        XCTAssertFalse(h.power.isPreventingSystemSleep)
        await eventually { h.api.sent.contains { $0.text?.contains("CAMERA PROBLEM") ?? false } }
    }

    // Scenarios 5, 6, 9, 10 + lifecycle + cleanup
    func testMotionEventFullLifecycle() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.launch()
        await h.arm()
        await h.waitForTriggerGate()

        XCTAssertTrue(h.camera.simulateMotion(at: h.clock.now))
        await eventually { h.coordinator.phase == .recording }
        XCTAssertEqual(h.camera.state.current.recordingsStarted, 1)

        // Alert and snapshot are delivered while recording.
        await eventually { h.api.sent.count == 2 }
        XCTAssertEqual(h.api.sent.map(\.kind), [.message, .photo])
        XCTAssertTrue(h.api.sent[0].text?.hasPrefix("MAC SECURITY ALERT\nMotion detected.\nEvent ID: EVT-00001") ?? false)
        XCTAssertEqual(h.api.sent[1].data, Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]))

        h.camera.simulateRecordingCompleted(duration: 30)
        await eventually { h.api.sent.count == 3 }
        XCTAssertEqual(h.api.sent[2].kind, .video)
        XCTAssertEqual(h.api.sent[2].data, FakeCamera.fakeVideoBytes)
        XCTAssertTrue(h.api.sent[2].text?.contains("30 s") ?? false)

        await eventually { h.coordinator.lastEvent?.stage == .completed }
        let event = try XCTUnwrap(h.coordinator.lastEvent)
        XCTAssertEqual(event.alertStatus, .delivered)
        XCTAssertEqual(event.snapshotStatus, .delivered)
        XCTAssertEqual(event.videoStatus, .delivered)
        XCTAssertEqual(event.recordingDuration, 30)
        XCTAssertEqual(h.coordinator.phase, .armed)
        XCTAssertTrue(h.encryptedMediaFiles.isEmpty, "Temporary media deleted after delivery")
        XCTAssertTrue(h.plaintextRecordings.isEmpty, "Plaintext recording deleted after encryption")
        await eventually { h.coordinator.pendingUploadCount == 0 }
    }

    // Scenario 14
    func testDuplicateEventsAreSuppressedDuringRecordingAndCooldown() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.launch()
        await h.arm()
        await h.waitForTriggerGate()
        XCTAssertTrue(h.camera.simulateMotion(at: h.clock.now))
        await eventually { h.coordinator.phase == .recording }

        // The pipeline gate is closed: continuous motion produces no trigger…
        XCTAssertFalse(h.camera.simulateMotion(at: h.clock.now))
        // …and even a trigger that slips through is rejected by the manager.
        h.camera.simulateMotion(at: h.clock.now, respectGate: false)

        h.clock.advance(30)
        h.camera.simulateRecordingCompleted()
        await eventually { h.coordinator.phase == .armed }

        // Within the cooldown: rejected.
        h.clock.advance(10)
        h.camera.simulateMotion(at: h.clock.now, respectGate: false)
        await eventually { h.api.sent.count == 3 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let events = await h.eventManager.recentEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(h.api.sent.filter { $0.kind == .message }.count, 1, "One alert only")

        // After the cooldown a new event is allowed.
        h.clock.advance(21)
        h.camera.simulateMotion(at: h.clock.now, respectGate: false)
        await eventually { await h.eventManager.recentEvents().count == 2 }
    }

    // Scenarios 11, 12, 13
    func testNetworkLossDuringRecordingQueuesAndDeliversOnRecovery() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.launch()
        await h.arm()
        await h.waitForTriggerGate()
        h.camera.simulateMotion(at: h.clock.now)
        await eventually { h.coordinator.phase == .recording }
        await h.coordinator.networkAvailabilityChanged(false)
        // A request already in flight may still complete; everything started
        // after the loss is queued.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let sentBefore = h.api.sent.count
        h.camera.simulateRecordingCompleted()
        await eventually { h.coordinator.phase == .armed && h.coordinator.pendingUploadCount >= 1 }
        XCTAssertEqual(h.coordinator.displayState, .offline)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(h.api.sent.count, sentBefore, "Nothing is sent while offline")
        XCTAssertEqual(h.coordinator.phase, .armed, "Local monitoring continues offline")

        await h.coordinator.networkAvailabilityChanged(true)
        await eventually { h.api.sent.count == 3 }
        await eventually { h.coordinator.lastEvent?.stage == .completed }
        XCTAssertTrue(h.encryptedMediaFiles.isEmpty)
    }

    func testTelegramUploadFailureIsRetried() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.launch()
        h.api.failNext(.network(code: -1001), times: 2)
        await h.arm()
        await h.waitForTriggerGate()
        h.camera.simulateMotion(at: h.clock.now)
        await eventually { h.coordinator.phase == .recording }
        h.camera.simulateRecordingCompleted()
        await eventually(timeout: 5) { h.api.sent.count == 3 }
    }

    // Scenario 16
    func testRestartWithPendingUploadsDeliversThem() async throws {
        let directory = try makeTemporaryDirectory()
        let storage = InMemorySecureStorage()
        do {
            let first = try CoordinatorHarness(directory: directory, secureStorage: storage)
            await first.coordinator.launch()
            await first.coordinator.networkAvailabilityChanged(false)
            await first.arm()
            await first.waitForTriggerGate()
            first.camera.simulateMotion(at: first.clock.now)
            await eventually { first.coordinator.phase == .recording }
            first.camera.simulateRecordingCompleted()
            await eventually { first.coordinator.pendingUploadCount == 3 }
            await first.coordinator.prepareForTermination()
            XCTAssertTrue(first.api.sent.isEmpty)
        }
        let second = try CoordinatorHarness(directory: directory, secureStorage: storage)
        await second.coordinator.launch()
        XCTAssertEqual(second.coordinator.phase, .disarmed, "Restart does not re-arm")
        XCTAssertEqual(second.camera.state.current.startCount, 0)
        await eventually { second.api.sent.count == 3 }
        XCTAssertEqual(second.api.sent.map(\.kind), [.message, .photo, .video])
        await eventually { second.coordinator.lastEvent?.stage == .completed }
    }

    // Scenarios 17, 18, 19
    func testStopReleasesCameraAndPowerAssertions() async throws {
        let h = try CoordinatorHarness()
        await h.arm()
        await h.coordinator.disarm()
        XCTAssertEqual(h.coordinator.phase, .disarmed)
        let capturing = await h.camera.isCapturing()
        XCTAssertFalse(capturing)
        XCTAssertEqual(h.camera.state.current.stopCount, 1)
        XCTAssertFalse(h.power.isPreventingSystemSleep)
        XCTAssertFalse(h.power.isPreventingDisplaySleep)
        XCTAssertEqual(h.coordinator.cameraStatus, .inactive)
        XCTAssertNil(h.coordinator.armedSince)
    }

    func testStopDuringRecordingStillDeliversPartialVideo() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.launch()
        await h.arm()
        await h.waitForTriggerGate()
        h.camera.simulateMotion(at: h.clock.now)
        await eventually { h.coordinator.phase == .recording }
        await h.coordinator.disarm()
        XCTAssertFalse(h.camera.isRunning)
        await eventually { h.api.sent.contains { $0.kind == .video } }
        XCTAssertTrue(h.plaintextRecordings.isEmpty)
    }

    func testEmergencyStopDiscardsRecordingAndReleasesEverything() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.launch()
        await h.arm()
        await h.waitForTriggerGate()
        h.camera.simulateMotion(at: h.clock.now)
        await eventually { h.coordinator.phase == .recording }
        await h.coordinator.emergencyStop()
        XCTAssertEqual(h.coordinator.phase, .disarmed)
        XCTAssertFalse(h.camera.isRunning)
        XCTAssertFalse(h.power.isPreventingSystemSleep)
        XCTAssertTrue(h.plaintextRecordings.isEmpty)
        let event = await h.eventManager.recentEvents().first
        XCTAssertEqual(event?.videoStatus, .skipped("Discarded by emergency stop"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(h.api.sent.contains { $0.kind == .video })
    }

    func testStopWhileArmingCancelsCameraStart() async throws {
        let h = try CoordinatorHarness()
        h.camera.state.withLock { $0.startDelay = 0.2 }
        let arming = Task { await h.arm() }
        await eventually { h.coordinator.phase == .arming }
        await h.coordinator.disarm()
        await arming.value
        XCTAssertEqual(h.coordinator.phase, .disarmed)
        let capturing = await h.camera.isCapturing()
        XCTAssertFalse(capturing)
        XCTAssertFalse(h.power.isPreventingSystemSleep)
    }

    // "Do not claim monitoring is active if frames stop"
    func testFrameStallIsReportedAndRecovers() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.launch()
        await h.arm()
        h.coordinator.checkCameraHealth()
        XCTAssertEqual(h.coordinator.cameraStatus, .active)
        h.clock.advance(6)
        h.coordinator.checkCameraHealth()
        XCTAssertEqual(h.coordinator.cameraStatus, .stalled)
        XCTAssertEqual(h.coordinator.displayState, .error)
        await eventually { h.api.sent.contains { $0.text?.contains("No camera frames") ?? false } }
        h.camera.frameHealth.recordFrame()
        h.coordinator.checkCameraHealth()
        XCTAssertEqual(h.coordinator.cameraStatus, .active)
        XCTAssertEqual(h.coordinator.displayState, .armed)
    }

    // Scenario 20 (logic; hardware verification is manual, see docs)
    func testDisplaySleepProbeVerifiesCompatibility() async throws {
        let h = try CoordinatorHarness()
        await h.arm()
        h.coordinator.displaySleepProbeDelay = 0
        h.coordinator.displayDidSleep()
        h.camera.frameHealth.recordFrame()
        await eventually {
            if case .verified = h.coordinator.displaySleepCompatibility { return true }
            return false
        }
        XCTAssertFalse(h.power.isPreventingDisplaySleep)
    }

    func testDisplaySleepFallbackKeepsDisplayAwakeWhenFramesStop() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.launch()
        await h.arm()
        h.coordinator.displaySleepProbeDelay = 0
        h.coordinator.displayDidSleep()
        await eventually {
            if case .interruptsCamera = h.coordinator.displaySleepCompatibility { return true }
            return false
        }
        XCTAssertTrue(h.power.isPreventingDisplaySleep)
        XCTAssertEqual(h.power.wakeCount, 1)
        await eventually { h.api.sent.contains { $0.text?.contains("Display sleep stopped camera frames") ?? false } }
    }

    // Scenario 15 at the coordinator level: a remote command cannot arm.
    func testRemoteCommandsCannotArmMonitoring() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.launch()
        let poller = TelegramUpdatePoller(
            sessionProvider: h.telegram,
            offsetStore: InMemoryOffsetStore(offset: 1),
            handler: TelegramCommandHandler(reporter: CoordinatorStatusReporter(coordinator: h.coordinator)),
            callbacks: .init(statusChanged: { _ in }, unauthorizedAttempt: { id in await h.coordinator.reportUnauthorizedAttempt(userID: id) }),
            now: { Date() }
        )
        h.api.script(updates: [
            makeUpdate(id: 1, text: "/arm", date: Date()),
            makeUpdate(id: 2, text: "/start_monitoring", date: Date()),
            makeUpdate(id: 3, text: "/status", from: 31337, date: Date()),
            makeUpdate(id: 4, text: "/status", date: Date()),
        ])
        await poller.pollOnce()
        XCTAssertEqual(h.coordinator.phase, .disarmed)
        XCTAssertEqual(h.camera.state.current.startCount, 0)
        let replies = h.api.sent.compactMap(\.text)
        XCTAssertEqual(replies.filter { $0.contains("Remote control is not supported") }.count, 2)
        XCTAssertTrue(replies.contains { $0.contains("Monitoring: DISARMED") })
        await eventually { h.api.sent.contains { $0.text?.contains("unauthorised Telegram user (id 31337)") ?? false } }
    }

    func testUnauthorizedNoticesAreRateLimited() async throws {
        let h = try CoordinatorHarness()
        await h.coordinator.launch()
        await h.coordinator.reportUnauthorizedAttempt(userID: 5)
        await h.coordinator.reportUnauthorizedAttempt(userID: 5)
        await eventually { h.api.sent.count == 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(h.api.sent.count, 1)
    }

    func testSettingsChangesApplyLive() async throws {
        let h = try CoordinatorHarness()
        await h.arm()
        var settings = h.coordinator.settings
        settings.motionSensitivity = 1.0
        settings.keepDisplayAwake = true
        await h.coordinator.apply(settings: settings)
        XCTAssertEqual(h.camera.state.current.lastConfiguration?.motion.pixelDifferenceThreshold, 12)
        XCTAssertTrue(h.power.isPreventingDisplaySleep)
    }

    func testDisabledVideoSkipsRecording() async throws {
        var settings = CoordinatorHarness.defaultSettings
        settings.notifications.sendVideo = false
        let h = try CoordinatorHarness(settings: settings)
        await h.coordinator.launch()
        await h.arm()
        await h.waitForTriggerGate()
        h.camera.simulateMotion(at: h.clock.now)
        await eventually { h.coordinator.lastEvent?.stage == .completed }
        XCTAssertEqual(h.camera.state.current.recordingsStarted, 0)
        XCTAssertEqual(h.coordinator.lastEvent?.videoStatus, .skipped("Disabled in settings"))
        XCTAssertTrue(h.api.sent[0].text?.contains("Video recording: Not recording") ?? false)
    }
}
