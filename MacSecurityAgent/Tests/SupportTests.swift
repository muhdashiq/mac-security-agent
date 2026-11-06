import XCTest
@testable import MacSecurityCore

final class SupportTests: XCTestCase {
    func testLogSanitizerRedactsSecrets() {
        let token = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawA"
        let samples = [
            "GET https://api.telegram.org/bot\(token)/sendMessage failed",
            "token=\(token)",
            "the token is \(token).",
            "Authorization: Bearer abc.def.ghi",
            "password=hunter2&x=1",
        ]
        for sample in samples {
            let sanitized = LogSanitizer.sanitize(sample)
            XCTAssertFalse(sanitized.contains("AAHdq"), sanitized)
            XCTAssertFalse(sanitized.contains("hunter2"), sanitized)
            XCTAssertFalse(sanitized.contains("abc.def.ghi"), sanitized)
        }
    }

    func testLogSanitizerStripsControlCharactersAndTruncates() {
        XCTAssertEqual(LogSanitizer.sanitize("a\nb\rc"), "a b c")
        let long = String(repeating: "x", count: 2000)
        XCTAssertLessThan(LogSanitizer.sanitize(long).count, 600)
    }

    func testStateTransitions() {
        XCTAssertTrue(MonitoringPhase.disarmed.canTransition(to: .arming))
        XCTAssertFalse(MonitoringPhase.disarmed.canTransition(to: .recording))
        XCTAssertFalse(MonitoringPhase.disarmed.canTransition(to: .armed))
        XCTAssertTrue(MonitoringPhase.armed.canTransition(to: .motionDetected))
        XCTAssertFalse(MonitoringPhase.armed.canTransition(to: .recording))
        XCTAssertTrue(MonitoringPhase.motionDetected.canTransition(to: .recording))
        XCTAssertTrue(MonitoringPhase.recording.canTransition(to: .armed))
        XCTAssertFalse(MonitoringPhase.stopping.canTransition(to: .armed))
        XCTAssertFalse(MonitoringPhase.stopping.canTransition(to: .recording))
        XCTAssertTrue(MonitoringPhase.error(.cameraStalled).canTransition(to: .arming))
    }

    func testDisplayStateDerivation() {
        XCTAssertEqual(MonitoringState.derive(phase: .armed, cameraStatus: .active, isNetworkAvailable: false, pendingUploads: 0), .offline)
        XCTAssertEqual(MonitoringState.derive(phase: .armed, cameraStatus: .active, isNetworkAvailable: true, pendingUploads: 2), .uploading)
        XCTAssertEqual(MonitoringState.derive(phase: .armed, cameraStatus: .stalled, isNetworkAvailable: true, pendingUploads: 0), .error)
        XCTAssertEqual(MonitoringState.derive(phase: .recording, cameraStatus: .active, isNetworkAvailable: false, pendingUploads: 3), .recording)
        XCTAssertEqual(MonitoringState.derive(phase: .stopping, cameraStatus: .active, isNetworkAvailable: true, pendingUploads: 0), .disarmed)
        XCTAssertEqual(Set(MonitoringState.allCases.map(\.title)).count, 8)
    }

    func testSettingsDefaultsMatchSpecification() {
        let settings = ApplicationSettings()
        XCTAssertEqual(settings.consecutiveFramesRequired, 3)
        XCTAssertEqual(settings.eventCooldownSeconds, 30)
        XCTAssertEqual(settings.videoDurationSeconds, 30)
        XCTAssertEqual(settings.videoResolution.width, 1280)
        XCTAssertEqual(settings.videoResolution.height, 720)
        XCTAssertEqual(settings.mediaRetentionHours, 24)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertNil(settings.authorizedTelegramUserID)
    }

    func testSettingsAreClampedAndDecodeLeniently() throws {
        var settings = ApplicationSettings()
        settings.mediaRetentionHours = 96
        settings.motionSensitivity = 4
        settings.consecutiveFramesRequired = 0
        settings.authorizedTelegramUserID = -5
        let validated = settings.validated()
        XCTAssertEqual(validated.mediaRetentionHours, 24)
        XCTAssertEqual(validated.motionSensitivity, 1)
        XCTAssertEqual(validated.consecutiveFramesRequired, 1)
        XCTAssertNil(validated.authorizedTelegramUserID)

        let partial = try JSONDecoder().decode(ApplicationSettings.self, from: Data(#"{"eventCooldownSeconds": 60}"#.utf8))
        XCTAssertEqual(partial.eventCooldownSeconds, 60)
        XCTAssertEqual(partial.videoDurationSeconds, 30)
    }

    func testSettingsStoreRoundTripContainsNoSecrets() throws {
        let suite = "msa-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var settings = ApplicationSettings()
        settings.authorizedTelegramUserID = 42
        settings.eventCooldownSeconds = 45
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
        let raw = String(decoding: defaults.data(forKey: "settings.v1") ?? Data(), as: UTF8.self)
        XCTAssertFalse(raw.lowercased().contains("token"))
    }

    func testFrameHealthMonitor() {
        let clock = TestClock()
        let monitor = FrameHealthMonitor(clock: clock.monotonicProvider)
        XCTAssertEqual(monitor.evaluate(), .inactive)
        monitor.markStarted()
        XCTAssertEqual(monitor.evaluate(), .waitingForFirstFrame(elapsed: 0))
        clock.advance(11)
        XCTAssertEqual(monitor.evaluate(firstFrameTimeout: 10), .stalled(secondsSinceLastFrame: 11))
        monitor.recordFrame()
        XCTAssertEqual(monitor.evaluate(), .healthy)
        clock.advance(6)
        XCTAssertEqual(monitor.evaluate(stallThreshold: 5), .stalled(secondsSinceLastFrame: 6))
        XCTAssertEqual(monitor.frameCount, 1)
        monitor.markStopped()
        XCTAssertEqual(monitor.evaluate(), .inactive)
    }

    func testSecureDeleteAndPrivateWrite() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("secret.bin")
        try SecureFiles.writePrivateFile(Data(repeating: 1, count: 100_000), to: url)
        XCTAssertEqual(SecureFiles.permissions(of: url), 0o600)
        SecureFiles.secureDelete(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
