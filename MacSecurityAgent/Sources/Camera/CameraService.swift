import Foundation
#if canImport(AVFoundation) && canImport(CoreImage)
@preconcurrency import AVFoundation
#endif

/// A confirmed motion trigger emitted by the camera pipeline.
public struct MotionTrigger: Sendable {
    public var analysis: MotionAnalysis
    /// JPEG of the frame that completed the trigger, if it could be encoded.
    public var snapshotJPEG: Data?
    public var capturedAt: Date

    public init(analysis: MotionAnalysis, snapshotJPEG: Data?, capturedAt: Date) {
        self.analysis = analysis
        self.snapshotJPEG = snapshotJPEG
        self.capturedAt = capturedAt
    }
}

/// Exactly one outcome is produced for each started recording.
public enum RecordingOutcome: Sendable, Equatable {
    case finished(eventID: EventID, fileURL: URL, duration: TimeInterval, frameCount: Int)
    case failed(eventID: EventID, message: String)
    case discarded(eventID: EventID)

    public var eventID: EventID {
        switch self {
        case .finished(let id, _, _, _), .failed(let id, _), .discarded(let id): return id
        }
    }
}

public enum CameraFailure: Sendable, Equatable {
    case deviceDisconnected
    case runtimeError(String)

    public var message: String {
        switch self {
        case .deviceDisconnected: return "The camera was disconnected."
        case .runtimeError(let detail): return "Camera error: \(detail)"
        }
    }
}

public enum CameraPipelineEvent: Sendable {
    case started(deviceName: String)
    case motionTriggered(MotionTrigger)
    /// Emitted when a recording ends on its own (duration reached / writer
    /// failure). Outcomes of `finishRecording` are returned directly instead.
    case recordingFinished(RecordingOutcome)
    case failed(CameraFailure)
}

public enum CameraError: Error, Sendable, Equatable, LocalizedError {
    case noCamera
    case configurationFailed(String)
    case notRunning
    case alreadyRecording
    case recorderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noCamera: return "No built-in camera was found."
        case .configurationFailed(let detail): return "Camera configuration failed: \(detail)"
        case .notRunning: return "The camera is not running."
        case .alreadyRecording: return "A recording is already in progress."
        case .recorderFailed(let detail): return "Could not start recording: \(detail)"
        }
    }
}

/// The capture pipeline used by `MonitoringCoordinator`.
///
/// Implementations deliver events through the stream returned by `start`.
/// Motion triggers are gated: after a trigger the gate closes automatically
/// and the coordinator re-opens it (after recording + cooldown), so a
/// continuous movement cannot flood the coordinator with duplicate triggers.
public protocol CameraPipelineControlling: AnyObject, Sendable {
    var frameHealth: FrameHealthMonitor { get }
    func start(configuration: CameraConfiguration) async throws -> AsyncStream<CameraPipelineEvent>
    /// Stops capture and releases the camera device. Idempotent.
    func stop() async
    func setMotionTriggersEnabled(_ enabled: Bool) async
    func updateMotionConfiguration(_ configuration: MotionDetectorConfiguration) async
    func startRecording(eventID: EventID, to url: URL) async throws
    /// Ends the current recording early. Returns `nil` if no recording was
    /// active (for example because it already finished on its own).
    func finishRecording(discard: Bool) async -> RecordingOutcome?
    func isCapturing() async -> Bool
}

#if canImport(AVFoundation) && canImport(CoreImage)

/// AVFoundation implementation of the capture pipeline.
///
/// Threading: every piece of mutable state is confined to `queue`, which is
/// also the sample-buffer delegate queue. Frames are analysed and appended to
/// the recorder synchronously on that queue, so there is no race between
/// motion analysis, recording and shutdown. Public async methods hop onto the
/// queue and resume when the work is done.
///
/// Privacy: only a video input is ever added (no audio device, no microphone
/// permission). The macOS camera indicator is controlled by the system and
/// lights up whenever the session runs. `stop()` removes inputs/outputs and
/// drops the session, which releases the device.
public final class CameraService: NSObject, CameraPipelineControlling, @unchecked Sendable {
    public let frameHealth: FrameHealthMonitor

    private let queue = DispatchQueue(label: "com.macsecurityagent.camera", qos: .userInitiated)
    private let logger = AppLogger(category: "Camera")
    private let snapshotCapture = SnapshotCapture()

    // MARK: Queue-confined state
    private var session: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var continuation: AsyncStream<CameraPipelineEvent>.Continuation?
    private var configuration = CameraConfiguration()
    private var detector = MotionDetector()
    private var analysisThrottler = FrameThrottler(interval: 0.2)
    private var triggersEnabled = false
    private var recorder: VideoRecorder?
    private var recordingEventID: EventID?
    private var observers: [NSObjectProtocol] = []

    public init(frameHealth: FrameHealthMonitor = FrameHealthMonitor()) {
        self.frameHealth = frameHealth
        super.init()
    }

    // MARK: CameraPipelineControlling

    public func start(configuration: CameraConfiguration) async throws -> AsyncStream<CameraPipelineEvent> {
        let (stream, continuation) = AsyncStream<CameraPipelineEvent>.makeStream(bufferingPolicy: .unbounded)
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.startOnQueue(configuration: configuration, continuation: continuation)
                    resume.resume()
                } catch {
                    continuation.finish()
                    resume.resume(throwing: error)
                }
            }
        }
        return stream
    }

    public func stop() async {
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            queue.async {
                self.stopOnQueue()
                resume.resume()
            }
        }
    }

    public func setMotionTriggersEnabled(_ enabled: Bool) async {
        queue.async {
            self.triggersEnabled = enabled
        }
    }

    public func updateMotionConfiguration(_ configuration: MotionDetectorConfiguration) async {
        queue.async {
            self.configuration.motion = configuration
            self.detector.update(configuration: configuration)
        }
    }

    public func startRecording(eventID: EventID, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.session != nil else {
                    resume.resume(throwing: CameraError.notRunning)
                    return
                }
                guard self.recorder == nil else {
                    resume.resume(throwing: CameraError.alreadyRecording)
                    return
                }
                do {
                    self.recorder = try VideoRecorder(outputURL: url, settings: self.configuration.video, realTime: true)
                    self.recordingEventID = eventID
                    self.logger.info("Recording started for \(eventID)")
                    resume.resume()
                } catch {
                    resume.resume(throwing: CameraError.recorderFailed(error.localizedDescription))
                }
            }
        }
    }

    public func finishRecording(discard: Bool) async -> RecordingOutcome? {
        await withCheckedContinuation { (resume: CheckedContinuation<RecordingOutcome?, Never>) in
            queue.async {
                guard self.recorder != nil else {
                    resume.resume(returning: nil)
                    return
                }
                self.completeRecording(discard: discard) { outcome in
                    resume.resume(returning: outcome)
                }
            }
        }
    }

    public func isCapturing() async -> Bool {
        await withCheckedContinuation { (resume: CheckedContinuation<Bool, Never>) in
            queue.async {
                resume.resume(returning: self.session?.isRunning ?? false)
            }
        }
    }

    // MARK: Queue-confined implementation

    private func startOnQueue(
        configuration: CameraConfiguration,
        continuation: AsyncStream<CameraPipelineEvent>.Continuation
    ) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        if session != nil { stopOnQueue() }

        guard let device = Self.builtInCamera() else { throw CameraError.noCamera }

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            session.commitConfiguration()
            throw CameraError.configurationFailed(error.localizedDescription)
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.configurationFailed("Cannot add camera input")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        // Bi-planar full-range YUV: the luma plane is directly usable as the
        // grayscale image for motion analysis, and H.264 encodes it natively.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraError.configurationFailed("Cannot add video output")
        }
        session.addOutput(output)
        session.commitConfiguration()

        Self.configureFrameRate(of: device, framesPerSecond: configuration.captureFrameRate)

        self.session = session
        self.videoOutput = output
        self.configuration = configuration
        self.detector = MotionDetector(configuration: configuration.motion)
        self.analysisThrottler = FrameThrottler(interval: configuration.analysisInterval)
        self.triggersEnabled = false
        self.continuation = continuation
        installObservers(session: session, device: device)
        frameHealth.markStarted()

        session.startRunning()
        guard session.isRunning else {
            stopOnQueue()
            throw CameraError.configurationFailed("The capture session did not start")
        }
        logger.info("Camera started: \(device.localizedName)")
        continuation.yield(.started(deviceName: device.localizedName))
    }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        triggersEnabled = false
        if recorder != nil {
            // The coordinator normally finishes recordings before stopping.
            // Anything left at this point is discarded so that no plaintext
            // file outlives the camera session.
            completeRecording(discard: true, completion: nil)
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        if let session {
            session.stopRunning()
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.commitConfiguration()
            logger.info("Camera stopped and released")
        }
        session = nil
        videoOutput = nil
        detector.reset()
        analysisThrottler.reset()
        frameHealth.markStopped()
        continuation?.finish()
        continuation = nil
    }

    private func installObservers(session: AVCaptureSession, device: AVCaptureDevice) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.report(.deviceDisconnected) }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                ?? "Unknown capture error"
            guard let self else { return }
            self.queue.async { self.report(.runtimeError(detail)) }
        })
    }

    private func report(_ failure: CameraFailure) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard session != nil else { return }
        logger.error(failure.message)
        continuation?.yield(.failed(failure))
    }

    fileprivate func process(_ sampleBuffer: CMSampleBuffer) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard session != nil, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameHealth.recordFrame()
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if let recorder {
            switch recorder.append(pixelBuffer: pixelBuffer, presentationTime: presentationTime) {
            case .reachedDuration:
                completeRecording(discard: false, completion: nil)
            case .failed(let message):
                logger.error("Recording append failed: \(message)")
                completeRecording(discard: false, completion: nil)
            case .appended, .skipped:
                break
            }
        }

        guard analysisThrottler.shouldAccept(timestamp: CMTimeGetSeconds(presentationTime)) else { return }
        guard let frame = PixelBufferConverter.grayscaleFrame(
            from: pixelBuffer,
            width: configuration.motion.analysisWidth,
            height: configuration.motion.analysisHeight
        ) else { return }

        let analysis = detector.analyze(frame)
        guard analysis.triggered, triggersEnabled, recorder == nil else { return }
        // Close the gate: the coordinator re-opens it after the event and the
        // cooldown, which prevents duplicate events for continuous movement.
        triggersEnabled = false
        let jpeg = snapshotCapture.jpegData(from: pixelBuffer, maxWidth: configuration.video.width)
        continuation?.yield(.motionTriggered(MotionTrigger(analysis: analysis, snapshotJPEG: jpeg, capturedAt: Date())))
    }

    private func completeRecording(discard: Bool, completion: (@Sendable (RecordingOutcome) -> Void)?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let recorder, let eventID = recordingEventID else { return }
        self.recorder = nil
        self.recordingEventID = nil
        let continuation = self.continuation

        if discard {
            recorder.cancel()
            let outcome = RecordingOutcome.discarded(eventID: eventID)
            if let completion { completion(outcome) } else { continuation?.yield(.recordingFinished(outcome)) }
            return
        }

        recorder.finish { result in
            let outcome: RecordingOutcome
            switch result {
            case .success(let summary):
                outcome = .finished(
                    eventID: eventID, fileURL: summary.url,
                    duration: summary.duration, frameCount: summary.frameCount
                )
            case .failure(let error):
                outcome = .failed(eventID: eventID, message: error.localizedDescription)
            }
            if let completion { completion(outcome) } else { continuation?.yield(.recordingFinished(outcome)) }
        }
    }

    // MARK: Device helpers

    /// Only the built-in camera is used (no Continuity Camera / external
    /// devices), matching the documented hardware configuration.
    static func builtInCamera() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.first
    }

    private static func configureFrameRate(of device: AVCaptureDevice, framesPerSecond: Int) {
        let fps = Double(framesPerSecond)
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= fps && fps <= $0.maxFrameRate
        }
        guard supported else { return }
        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            // Not fatal: the recorder throttles to 15 FPS on its own.
        }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        process(sampleBuffer)
    }
}

#endif
