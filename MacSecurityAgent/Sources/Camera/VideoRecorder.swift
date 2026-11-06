import Foundation
#if canImport(AVFoundation)
@preconcurrency import AVFoundation

public struct RecordingSummary: Sendable, Equatable {
    public let url: URL
    public let duration: TimeInterval
    public let frameCount: Int
}

public enum VideoRecorderError: Error, LocalizedError, Sendable {
    case cannotCreateWriter(String)
    case unsupportedSettings
    case cannotAddInput
    case startFailed(String)
    case writeFailed(String)
    case noFrames

    public var errorDescription: String? {
        switch self {
        case .cannotCreateWriter(let detail): return "Cannot create video writer: \(detail)"
        case .unsupportedSettings: return "The H.264 settings are not supported on this Mac."
        case .cannotAddInput: return "Cannot add the video input to the writer."
        case .startFailed(let detail): return "The video writer did not start: \(detail)"
        case .writeFailed(let detail): return "Writing the video failed: \(detail)"
        case .noFrames: return "No frames were recorded."
        }
    }
}

/// Writes a silent H.264 MP4 (no audio track is ever created).
///
/// The recorder is *not* thread-safe; it is owned by the camera queue.
/// Timing: the session starts at the first frame's presentation time and ends
/// exactly `durationSeconds` later, so a full recording is exactly 30.0 s.
/// Frames are throttled to `frameRate` (15 FPS).
public final class VideoRecorder {
    public enum AppendResult: Equatable, Sendable {
        case appended
        case skipped
        case reachedDuration
        case failed(String)
    }

    public let outputURL: URL
    public let settings: VideoRecordingSettings
    public private(set) var frameCount = 0

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let realTime: Bool
    private var throttler: FrameThrottler
    private var startTime: CMTime?
    private var lastAppendedTime: CMTime?
    private var reachedLimit = false

    public init(outputURL: URL, settings: VideoRecordingSettings, realTime: Bool = true) throws {
        self.outputURL = outputURL
        self.settings = settings
        self.realTime = realTime
        self.throttler = FrameThrottler(interval: 1.0 / Double(max(settings.frameRate, 1)))

        try? FileManager.default.removeItem(at: outputURL)
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw VideoRecorderError.cannotCreateWriter(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.averageBitRate,
            AVVideoExpectedSourceFrameRateKey: settings.frameRate,
            AVVideoMaxKeyFrameIntervalKey: settings.maxKeyFrameInterval,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: false,
        ]
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoCompressionPropertiesKey: compression,
        ]
        guard writer.canApply(outputSettings: outputSettings, forMediaType: .video) else {
            throw VideoRecorderError.unsupportedSettings
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = realTime
        guard writer.canAdd(input) else { throw VideoRecorderError.cannotAddInput }
        writer.add(input)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)

        guard writer.startWriting() else {
            throw VideoRecorderError.startFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    public var maximumDuration: CMTime {
        CMTime(seconds: settings.durationSeconds, preferredTimescale: 600)
    }

    public func append(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> AppendResult {
        if reachedLimit { return .reachedDuration }
        guard writer.status == .writing else {
            return .failed(writer.error?.localizedDescription ?? "Writer is not writing")
        }
        if startTime == nil {
            writer.startSession(atSourceTime: presentationTime)
            startTime = presentationTime
        }
        guard let startTime else { return .failed("No start time") }

        let elapsed = CMTimeSubtract(presentationTime, startTime)
        if CMTimeCompare(elapsed, maximumDuration) >= 0 {
            reachedLimit = true
            return .reachedDuration
        }
        guard throttler.shouldAccept(timestamp: CMTimeGetSeconds(presentationTime)) else { return .skipped }

        if !input.isReadyForMoreMediaData {
            if realTime { return .skipped }
            // Offline encoding (tests / synthetic input): wait for the encoder.
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard input.isReadyForMoreMediaData else { return .failed("Encoder did not become ready") }
        }

        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            return .failed(writer.error?.localizedDescription ?? "Append failed")
        }
        frameCount += 1
        lastAppendedTime = presentationTime
        return .appended
    }

    public func finish(completion: @escaping @Sendable (Result<RecordingSummary, Error>) -> Void) {
        guard let startTime, frameCount > 0, writer.status == .writing else {
            cancel()
            completion(.failure(VideoRecorderError.noFrames))
            return
        }
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(settings.frameRate, 1)))
        let endTime = reachedLimit
            ? CMTimeAdd(startTime, maximumDuration)
            : CMTimeAdd(lastAppendedTime ?? startTime, frameDuration)
        let duration = CMTimeGetSeconds(CMTimeSubtract(endTime, startTime))

        input.markAsFinished()
        writer.endSession(atSourceTime: endTime)

        let box = UncheckedSendableBox(writer)
        let url = outputURL
        let frames = frameCount
        writer.finishWriting {
            let writer = box.value
            if writer.status == .completed {
                completion(.success(RecordingSummary(url: url, duration: duration, frameCount: frames)))
            } else {
                try? FileManager.default.removeItem(at: url)
                completion(.failure(VideoRecorderError.writeFailed(writer.error?.localizedDescription ?? "unknown")))
            }
        }
    }

    public func cancel() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
        try? FileManager.default.removeItem(at: outputURL)
    }
}
#endif
