#if canImport(AVFoundation) && canImport(Security) && canImport(CoreImage)
import AVFoundation
import XCTest
@testable import MacSecurityCore

/// Opt-in tests that touch real hardware / the real Keychain. They are
/// skipped unless the corresponding environment variable is set, because
/// they show permission prompts:
///
///     MSA_CAMERA_TESTS=1   swift test --filter HardwareIntegrationTests
///     MSA_KEYCHAIN_TESTS=1 swift test --filter HardwareIntegrationTests
final class HardwareIntegrationTests: XCTestCase {
    private func requireEnvironment(_ name: String) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment[name] == "1", "Set \(name)=1 to run")
    }

    /// Scenarios 2, 17, 18 on real hardware: frames arrive, then the camera
    /// is released.
    func testBuiltInCameraDeliversFramesAndIsReleased() async throws {
        try requireEnvironment("MSA_CAMERA_TESTS")
        let permission = await CameraPermissionManager().requestAccess()
        try XCTSkipUnless(permission == .authorized, "Camera permission not granted to the test runner")

        let camera = CameraService()
        let stream = try await camera.start(configuration: CameraConfiguration())
        let started = Task { () -> String? in
            for await event in stream {
                if case .started(let name) = event { return name }
            }
            return nil
        }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertGreaterThan(camera.frameHealth.frameCount, 10, "Expected ≈15 FPS")
        XCTAssertEqual(camera.frameHealth.evaluate(), .healthy)
        let capturing = await camera.isCapturing()
        XCTAssertTrue(capturing)

        await camera.stop()
        let stillCapturing = await camera.isCapturing()
        XCTAssertFalse(stillCapturing)
        XCTAssertEqual(camera.frameHealth.evaluate(), .inactive)
        let name = await started.value
        XCTAssertNotNil(name)
    }

    /// Records a real 5-second clip from the built-in camera.
    func testRealCameraRecording() async throws {
        try requireEnvironment("MSA_CAMERA_TESTS")
        try XCTSkipUnless(CameraPermissionManager().currentStatus() == .authorized)
        let camera = CameraService()
        var configuration = CameraConfiguration()
        configuration.video.durationSeconds = 5
        let stream = try await camera.start(configuration: configuration)
        let url = try makeTemporaryDirectory().appendingPathComponent("real.mp4")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await camera.startRecording(eventID: EventID(sequence: 1), to: url)

        var outcome: RecordingOutcome?
        for await event in stream {
            if case .recordingFinished(let result) = event {
                outcome = result
                break
            }
        }
        await camera.stop()
        guard case .finished(_, let fileURL, let duration, let frames)? = outcome else {
            return XCTFail("Recording did not finish: \(String(describing: outcome))")
        }
        XCTAssertEqual(duration, 5, accuracy: 0.001)
        XCTAssertGreaterThan(frames, 60)
        let audio = try await AVURLAsset(url: fileURL).loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
    }

    func testKeychainRoundTrip() throws {
        try requireEnvironment("MSA_KEYCHAIN_TESTS")
        let keychain = KeychainManager(service: "com.macsecurityagent.tests.\(UUID().uuidString)")
        defer { try? keychain.deleteData(forKey: "k") }
        XCTAssertNil(try keychain.readData(forKey: "k"))
        try keychain.writeData(Data("one".utf8), forKey: "k")
        try keychain.writeData(Data("two".utf8), forKey: "k")
        XCTAssertEqual(try keychain.readData(forKey: "k"), Data("two".utf8))
        try keychain.deleteData(forKey: "k")
        XCTAssertNil(try keychain.readData(forKey: "k"))
    }
}
#endif
