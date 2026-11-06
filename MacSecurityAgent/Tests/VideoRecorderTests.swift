#if canImport(AVFoundation) && canImport(CoreImage) && canImport(ImageIO)
import AVFoundation
import CoreVideo
import ImageIO
import XCTest
@testable import MacSecurityCore

/// macOS-only: validates the real AVFoundation recording path with synthetic
/// frames (no camera needed).
final class VideoRecorderTests: XCTestCase {
    static func makePixelBuffer(
        width: Int, height: Int,
        format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        value: UInt8
    ) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed")
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if CVPixelBufferIsPlanar(pixelBuffer) {
            for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
                let bytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
                memset(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane), Int32(plane == 0 ? value : 128), bytes)
            }
        } else {
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(value), CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private func finish(_ recorder: VideoRecorder) async throws -> RecordingSummary {
        let expectation = expectation(description: "finishWriting")
        let result = LockedValue<Result<RecordingSummary, Error>?>(nil)
        recorder.finish { outcome in
            result.set(outcome)
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 60)
        return try XCTUnwrap(result.current).get()
    }

    /// Scenarios 7 and 8: exactly 30 s, H.264, 1280×720, 15 FPS, no audio.
    func testThirtySecondRecordingIsExactH264WithoutAudio() async throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("event.mp4")
        let recorder = try VideoRecorder(outputURL: url, settings: VideoRecordingSettings(), realTime: false)

        var reachedDuration = false
        // Feed 31 s of 30 FPS input; the recorder must keep 15 FPS and stop at 30 s.
        for index in 0..<(31 * 30) {
            let pixelBuffer = Self.makePixelBuffer(width: 1280, height: 720, value: UInt8(truncatingIfNeeded: index * 3))
            let result = recorder.append(pixelBuffer: pixelBuffer, presentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
            if result == .reachedDuration { reachedDuration = true; break }
            if case .failed(let message) = result { return XCTFail(message) }
        }
        XCTAssertTrue(reachedDuration)
        XCTAssertEqual(recorder.frameCount, 450, "30 s × 15 FPS")

        let summary = try await finish(recorder)
        XCTAssertEqual(summary.duration, 30, accuracy: 0.0001)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 30, accuracy: 1.0 / 15.0)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty, "Recordings must never contain audio")
        let allTracks = try await asset.load(.tracks)
        XCTAssertEqual(allTracks.count, 1)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(videoTracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 720)
        let frameRate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(Double(frameRate), 15, accuracy: 0.5)
        let formats = try await track.load(.formatDescriptions)
        XCTAssertEqual(formats.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_H264)
        let dataRate = try await track.load(.estimatedDataRate)
        XCTAssertLessThan(dataRate, 2_000_000, "Target ≈1.2 Mbps")

        let header = try Data(contentsOf: url).prefix(8)
        XCTAssertEqual(String(decoding: header.suffix(4), as: UTF8.self), "ftyp", "MP4 container")
    }

    func testEarlyFinishProducesPartialRecording() async throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("partial.mp4")
        let recorder = try VideoRecorder(outputURL: url, settings: VideoRecordingSettings(width: 640, height: 360), realTime: false)
        for index in 0..<75 { // 5 s at 15 FPS
            let pixelBuffer = Self.makePixelBuffer(width: 1280, height: 720, value: UInt8(index))
            _ = recorder.append(pixelBuffer: pixelBuffer, presentationTime: CMTime(value: CMTimeValue(index), timescale: 15))
        }
        let summary = try await finish(recorder)
        XCTAssertEqual(summary.duration, 5, accuracy: 0.001)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 640, "Resolution setting is applied")
    }

    func testFinishWithoutFramesFailsAndDeletesFile() async throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("empty.mp4")
        let recorder = try VideoRecorder(outputURL: url, settings: VideoRecordingSettings(), realTime: false)
        do {
            _ = try await finish(recorder)
            XCTFail("Expected failure")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Scenario 6: snapshot capture.
    func testSnapshotIsJPEG() throws {
        let pixelBuffer = Self.makePixelBuffer(width: 1280, height: 720, value: 120)
        let jpeg = try XCTUnwrap(SnapshotCapture().jpegData(from: pixelBuffer, maxWidth: 1280))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1280)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 720)
    }

    func testSnapshotIsScaledToMaxWidth() throws {
        let pixelBuffer = Self.makePixelBuffer(width: 1280, height: 720, value: 120)
        let jpeg = try XCTUnwrap(SnapshotCapture().jpegData(from: pixelBuffer, maxWidth: 640))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 640)
    }

    func testLumaPlaneIsDownscaledForMotionAnalysis() throws {
        let pixelBuffer = Self.makePixelBuffer(width: 1280, height: 720, value: 77)
        let frame = try XCTUnwrap(PixelBufferConverter.grayscaleFrame(from: pixelBuffer, width: 320, height: 180))
        XCTAssertEqual(frame.width, 320)
        XCTAssertEqual(frame.height, 180)
        XCTAssertEqual(frame.meanLuminance, 77, accuracy: 1)
    }

    func testBGRAIsConvertedToLuma() throws {
        let pixelBuffer = Self.makePixelBuffer(width: 640, height: 360, format: kCVPixelFormatType_32BGRA, value: 200)
        let frame = try XCTUnwrap(PixelBufferConverter.grayscaleFrame(from: pixelBuffer, width: 320, height: 180))
        XCTAssertEqual(frame.meanLuminance, 200, accuracy: 1)
    }
}
#endif
