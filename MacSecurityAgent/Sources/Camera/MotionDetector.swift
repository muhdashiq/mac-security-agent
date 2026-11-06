import Foundation

/// An 8-bit grayscale image (row-major, no padding).
public struct GrayscaleFrame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0, "Frame dimensions must be positive")
        precondition(pixels.count == width * height, "Pixel count does not match dimensions")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height))
    }

    public var meanLuminance: Double {
        var total = 0
        pixels.withUnsafeBufferPointer { buffer in
            for value in buffer { total &+= Int(value) }
        }
        return Double(total) / Double(pixels.count)
    }

    /// Area-averaging (box filter) downscale. Averaging also suppresses sensor
    /// noise, which is why motion analysis runs on a 320 × 180 image.
    public func downscaled(toWidth targetWidth: Int, height targetHeight: Int) -> GrayscaleFrame {
        if targetWidth == width && targetHeight == height { return self }
        precondition(targetWidth > 0 && targetHeight > 0)
        var output = [UInt8](repeating: 0, count: targetWidth * targetHeight)
        pixels.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                for ty in 0..<targetHeight {
                    let y0 = ty * height / targetHeight
                    let y1 = max(y0 + 1, (ty + 1) * height / targetHeight)
                    for tx in 0..<targetWidth {
                        let x0 = tx * width / targetWidth
                        let x1 = max(x0 + 1, (tx + 1) * width / targetWidth)
                        var sum = 0
                        for y in y0..<y1 {
                            let row = y * width
                            for x in x0..<x1 { sum &+= Int(src[row + x]) }
                        }
                        let count = (y1 - y0) * (x1 - x0)
                        dst[ty * targetWidth + tx] = UInt8(truncatingIfNeeded: (sum + count / 2) / count)
                    }
                }
            }
        }
        return GrayscaleFrame(width: targetWidth, height: targetHeight, pixels: output)
    }
}

/// Tunable parameters of `MotionDetector`.
public struct MotionDetectorConfiguration: Sendable, Equatable {
    public var analysisWidth: Int
    public var analysisHeight: Int
    /// A pixel counts as changed when its (brightness-compensated) absolute
    /// difference exceeds this value.
    public var pixelDifferenceThreshold: Int
    /// Fraction (0...1) of pixels that must change for a frame to qualify.
    public var minimumChangedFraction: Double
    /// Number of consecutive qualifying frames required to trigger.
    public var consecutiveFramesRequired: Int
    /// A frame-to-frame change of mean luminance above this fraction of the
    /// full scale is treated as a global lighting change (light switched
    /// on/off, auto-exposure jump), not as motion.
    public var lightingChangeThreshold: Double
    /// Frames ignored after a lighting change while auto exposure settles.
    public var lightingSettleFrames: Int
    /// Subtract the global brightness shift before comparing pixels.
    public var compensatesGlobalBrightness: Bool

    public init(
        analysisWidth: Int = 320,
        analysisHeight: Int = 180,
        pixelDifferenceThreshold: Int = 31,
        minimumChangedFraction: Double = 0.01,
        consecutiveFramesRequired: Int = 3,
        lightingChangeThreshold: Double = 0.18,
        lightingSettleFrames: Int = 3,
        compensatesGlobalBrightness: Bool = true
    ) {
        self.analysisWidth = analysisWidth
        self.analysisHeight = analysisHeight
        self.pixelDifferenceThreshold = pixelDifferenceThreshold
        self.minimumChangedFraction = minimumChangedFraction
        self.consecutiveFramesRequired = max(1, consecutiveFramesRequired)
        self.lightingChangeThreshold = lightingChangeThreshold
        self.lightingSettleFrames = max(0, lightingSettleFrames)
        self.compensatesGlobalBrightness = compensatesGlobalBrightness
    }

    /// Maps the user-facing settings onto detector parameters.
    ///
    /// - Parameters:
    ///   - sensitivity: 0 (least sensitive) ... 1 (most sensitive). Controls
    ///     the per-pixel difference threshold (50 ... 12 grey levels).
    ///   - minimumAreaPercent: share of the frame that must change.
    ///   - consecutiveFramesRequired: frames in a row that must qualify.
    public init(sensitivity: Double, minimumAreaPercent: Double, consecutiveFramesRequired: Int) {
        let s = min(max(sensitivity, 0), 1)
        self.init(
            pixelDifferenceThreshold: Int((50 - s * 38).rounded()),
            minimumChangedFraction: min(max(minimumAreaPercent, 0.01), 100) / 100,
            consecutiveFramesRequired: consecutiveFramesRequired
        )
    }
}

/// Result of analysing one frame.
public struct MotionAnalysis: Sendable, Equatable {
    public var changedFraction: Double
    public var meanLuminance: Double
    public var meanLuminanceDelta: Double
    public var isBaseline: Bool
    public var isLightingChange: Bool
    public var isQualifying: Bool
    public var consecutiveQualifyingFrames: Int
    public var triggered: Bool

    public var changedPercent: Double { changedFraction * 100 }
}

/// Frame-difference motion detector.
///
/// Algorithm (per analysed frame, ≈5 FPS):
/// 1. Downscale the grayscale frame to the analysis resolution.
/// 2. If the mean luminance jumped by more than `lightingChangeThreshold`,
///    treat it as a lighting change: re-baseline and ignore a few frames.
/// 3. Otherwise subtract the global brightness shift (so slow or small
///    exposure changes do not count) and count pixels whose absolute
///    difference to the previous frame exceeds the pixel threshold.
/// 4. A frame qualifies when the changed share exceeds the minimum area.
/// 5. After `consecutiveFramesRequired` qualifying frames in a row the
///    detector triggers once and starts counting again.
///
/// The type is a value type with no shared state: the camera pipeline owns one
/// instance on its serial queue, and tests can drive it directly.
public struct MotionDetector: Sendable {
    public private(set) var configuration: MotionDetectorConfiguration
    private var previousFrame: GrayscaleFrame?
    private var previousMean: Double = 0
    private var consecutiveQualifying = 0
    private var settleFramesRemaining = 0

    public init(configuration: MotionDetectorConfiguration = MotionDetectorConfiguration()) {
        self.configuration = configuration
    }

    /// Changes thresholds without discarding the baseline frame.
    public mutating func update(configuration: MotionDetectorConfiguration) {
        let resolutionChanged = configuration.analysisWidth != self.configuration.analysisWidth
            || configuration.analysisHeight != self.configuration.analysisHeight
        self.configuration = configuration
        if resolutionChanged { reset() }
        consecutiveQualifying = min(consecutiveQualifying, configuration.consecutiveFramesRequired - 1)
    }

    public mutating func reset() {
        previousFrame = nil
        previousMean = 0
        consecutiveQualifying = 0
        settleFramesRemaining = 0
    }

    public mutating func analyze(_ input: GrayscaleFrame) -> MotionAnalysis {
        let frame = input.downscaled(toWidth: configuration.analysisWidth, height: configuration.analysisHeight)
        let mean = frame.meanLuminance

        guard let previous = previousFrame else {
            previousFrame = frame
            previousMean = mean
            return MotionAnalysis(
                changedFraction: 0, meanLuminance: mean, meanLuminanceDelta: 0, isBaseline: true,
                isLightingChange: false, isQualifying: false, consecutiveQualifyingFrames: 0, triggered: false
            )
        }

        let delta = mean - previousMean
        defer {
            previousFrame = frame
            previousMean = mean
        }

        if abs(delta) / 255 >= configuration.lightingChangeThreshold {
            consecutiveQualifying = 0
            settleFramesRemaining = configuration.lightingSettleFrames
            return MotionAnalysis(
                changedFraction: 0, meanLuminance: mean, meanLuminanceDelta: delta, isBaseline: false,
                isLightingChange: true, isQualifying: false, consecutiveQualifyingFrames: 0, triggered: false
            )
        }

        if settleFramesRemaining > 0 {
            settleFramesRemaining -= 1
            consecutiveQualifying = 0
            return MotionAnalysis(
                changedFraction: 0, meanLuminance: mean, meanLuminanceDelta: delta, isBaseline: false,
                isLightingChange: true, isQualifying: false, consecutiveQualifyingFrames: 0, triggered: false
            )
        }

        let offset = configuration.compensatesGlobalBrightness ? Int(delta.rounded()) : 0
        let fraction = Self.changedFraction(
            current: frame.pixels,
            previous: previous.pixels,
            offset: offset,
            threshold: configuration.pixelDifferenceThreshold
        )

        let qualifying = fraction >= configuration.minimumChangedFraction
        consecutiveQualifying = qualifying ? consecutiveQualifying + 1 : 0
        let triggered = consecutiveQualifying >= configuration.consecutiveFramesRequired
        let reportedCount = consecutiveQualifying
        if triggered { consecutiveQualifying = 0 }

        return MotionAnalysis(
            changedFraction: fraction, meanLuminance: mean, meanLuminanceDelta: delta, isBaseline: false,
            isLightingChange: false, isQualifying: qualifying,
            consecutiveQualifyingFrames: reportedCount, triggered: triggered
        )
    }

    /// Share of pixels where `|current - previous - offset| > threshold`.
    static func changedFraction(current: [UInt8], previous: [UInt8], offset: Int, threshold: Int) -> Double {
        precondition(current.count == previous.count)
        var changed = 0
        current.withUnsafeBufferPointer { cur in
            previous.withUnsafeBufferPointer { prev in
                for index in 0..<cur.count {
                    let difference = Int(cur[index]) - Int(prev[index]) - offset
                    if difference > threshold || difference < -threshold { changed += 1 }
                }
            }
        }
        return Double(changed) / Double(current.count)
    }
}

/// Accepts at most one frame per `interval` based on presentation timestamps.
/// Used to analyse ≈5 FPS and to record 15 FPS from a faster camera feed.
public struct FrameThrottler: Sendable {
    public var interval: TimeInterval
    /// Allows slightly early frames so that, e.g., a 30 FPS feed throttled to
    /// 15 FPS keeps every second frame despite timestamp jitter.
    public var tolerance: TimeInterval
    private var lastAccepted: TimeInterval?

    public init(interval: TimeInterval, tolerance: TimeInterval? = nil) {
        self.interval = interval
        self.tolerance = tolerance ?? interval * 0.1
    }

    public mutating func shouldAccept(timestamp: TimeInterval) -> Bool {
        if let last = lastAccepted, timestamp >= last, timestamp - last < interval - tolerance {
            return false
        }
        lastAccepted = timestamp
        return true
    }

    public mutating func reset() {
        lastAccepted = nil
    }
}
