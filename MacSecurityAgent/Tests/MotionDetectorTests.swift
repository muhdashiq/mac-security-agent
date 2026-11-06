import XCTest
@testable import MacSecurityCore

final class MotionDetectorTests: XCTestCase {
    private let width = 320
    private let height = 180

    private func frame(fill: UInt8 = 100, block: (x: Int, y: Int, size: Int, value: UInt8)? = nil, noise: Int = 0, seed: UInt64 = 1) -> GrayscaleFrame {
        var pixels = [UInt8](repeating: fill, count: width * height)
        if noise > 0 {
            var generator = SeededGenerator(seed: seed)
            for index in pixels.indices {
                let delta = Int.random(in: -noise...noise, using: &generator)
                pixels[index] = UInt8(clamping: Int(fill) + delta)
            }
        }
        if let block {
            for y in block.y..<min(height, block.y + block.size) {
                for x in block.x..<min(width, block.x + block.size) {
                    pixels[y * width + x] = block.value
                }
            }
        }
        return GrayscaleFrame(width: width, height: height, pixels: pixels)
    }

    private var defaultConfiguration: MotionDetectorConfiguration {
        MotionDetectorConfiguration(sensitivity: 0.5, minimumAreaPercent: 1.0, consecutiveFramesRequired: 3)
    }

    func testFirstFrameIsBaseline() {
        var detector = MotionDetector(configuration: defaultConfiguration)
        let analysis = detector.analyze(frame())
        XCTAssertTrue(analysis.isBaseline)
        XCTAssertFalse(analysis.triggered)
    }

    func testIdenticalFramesNeverTrigger() {
        var detector = MotionDetector(configuration: defaultConfiguration)
        for _ in 0..<20 {
            XCTAssertFalse(detector.analyze(frame()).triggered)
        }
    }

    func testMovingObjectTriggersAfterThreeConsecutiveFrames() {
        var detector = MotionDetector(configuration: defaultConfiguration)
        _ = detector.analyze(frame())
        // A 40×40 block (2.8 % of the frame) moving across the scene.
        let first = detector.analyze(frame(block: (10, 50, 40, 230)))
        let second = detector.analyze(frame(block: (60, 50, 40, 230)))
        let third = detector.analyze(frame(block: (110, 50, 40, 230)))
        XCTAssertTrue(first.isQualifying)
        XCTAssertFalse(first.triggered)
        XCTAssertEqual(second.consecutiveQualifyingFrames, 2)
        XCTAssertFalse(second.triggered)
        XCTAssertTrue(third.triggered)
        XCTAssertEqual(third.consecutiveQualifyingFrames, 3)
        XCTAssertGreaterThan(third.changedPercent, 1.0)
    }

    func testCounterResetsWhenMotionStops() {
        var detector = MotionDetector(configuration: defaultConfiguration)
        _ = detector.analyze(frame())
        _ = detector.analyze(frame(block: (10, 50, 40, 230)))
        _ = detector.analyze(frame(block: (60, 50, 40, 230)))
        // Object leaves; then two still frames.
        _ = detector.analyze(frame(block: (60, 50, 40, 230)))
        let still = detector.analyze(frame(block: (60, 50, 40, 230)))
        XCTAssertFalse(still.isQualifying)
        XCTAssertEqual(still.consecutiveQualifyingFrames, 0)
        XCTAssertFalse(detector.analyze(frame(block: (110, 50, 40, 230))).triggered)
    }

    func testTriggerFiresOnceThenRequiresNewSequence() {
        var detector = MotionDetector(configuration: defaultConfiguration)
        _ = detector.analyze(frame())
        var triggers = 0
        for step in 0..<6 {
            if detector.analyze(frame(block: (10 + step * 40, 50, 40, 230))).triggered { triggers += 1 }
        }
        XCTAssertEqual(triggers, 2, "Six qualifying frames with N=3 should trigger exactly twice")
    }

    func testSmallChangesBelowMinimumAreaAreIgnored() {
        var detector = MotionDetector(configuration: defaultConfiguration)
        _ = detector.analyze(frame())
        // 10×10 block = 0.17 % < 1 %.
        for step in 0..<6 {
            let analysis = detector.analyze(frame(block: (10 + step * 20, 50, 10, 230)))
            XCTAssertFalse(analysis.isQualifying)
            XCTAssertFalse(analysis.triggered)
        }
    }

    func testMinimumAreaIsConfigurable() {
        var config = defaultConfiguration
        config.minimumChangedFraction = 0.001
        var detector = MotionDetector(configuration: config)
        _ = detector.analyze(frame())
        var triggered = false
        for step in 0..<3 {
            triggered = detector.analyze(frame(block: (10 + step * 20, 50, 10, 230))).triggered
        }
        XCTAssertTrue(triggered)
    }

    func testSensitivityControlsFaintChanges() {
        // A faint object: 25 grey levels above the background.
        let faint: UInt8 = 125
        var low = MotionDetector(configuration: MotionDetectorConfiguration(sensitivity: 0.0, minimumAreaPercent: 1, consecutiveFramesRequired: 3))
        var high = MotionDetector(configuration: MotionDetectorConfiguration(sensitivity: 1.0, minimumAreaPercent: 1, consecutiveFramesRequired: 3))
        _ = low.analyze(frame())
        _ = high.analyze(frame())
        var lowTriggered = false
        var highTriggered = false
        for step in 0..<3 {
            let f = frame(block: (10 + step * 50, 50, 45, faint))
            lowTriggered = lowTriggered || low.analyze(f).triggered
            highTriggered = highTriggered || high.analyze(f).triggered
        }
        XCTAssertFalse(lowTriggered, "Low sensitivity must ignore faint changes")
        XCTAssertTrue(highTriggered, "High sensitivity must detect faint changes")
    }

    func testSensitivityMapping() {
        XCTAssertEqual(MotionDetectorConfiguration(sensitivity: 0, minimumAreaPercent: 1, consecutiveFramesRequired: 3).pixelDifferenceThreshold, 50)
        XCTAssertEqual(MotionDetectorConfiguration(sensitivity: 1, minimumAreaPercent: 1, consecutiveFramesRequired: 3).pixelDifferenceThreshold, 12)
        XCTAssertEqual(MotionDetectorConfiguration(sensitivity: 0.5, minimumAreaPercent: 2, consecutiveFramesRequired: 4).minimumChangedFraction, 0.02, accuracy: 1e-9)
    }

    func testSmallGlobalBrightnessShiftIsCompensated() {
        var detector = MotionDetector(configuration: defaultConfiguration)
        _ = detector.analyze(frame(fill: 100))
        // Auto-exposure hunting: ±36–40 grey levels over the whole frame —
        // below the lighting-change threshold (46) but above the pixel
        // threshold (31), so without compensation every pixel would change.
        for value in [140, 104, 140, 104, 140] {
            let analysis = detector.analyze(frame(fill: UInt8(value)))
            XCTAssertFalse(analysis.isLightingChange)
            XCTAssertFalse(analysis.isQualifying)
            XCTAssertFalse(analysis.triggered)
        }
    }

    func testSuddenLightingChangeDoesNotTrigger() {
        var detector = MotionDetector(configuration: defaultConfiguration)
        _ = detector.analyze(frame(fill: 40))
        // Light switched on: mean jumps from 40 to 180.
        let jump = detector.analyze(frame(fill: 180))
        XCTAssertTrue(jump.isLightingChange)
        XCTAssertFalse(jump.triggered)
        // Settling frames with slight exposure hunting.
        var triggered = false
        for value in [175, 182, 178, 180, 180, 180] {
            triggered = triggered || detector.analyze(frame(fill: UInt8(value), noise: 3)).triggered
        }
        XCTAssertFalse(triggered)
    }

    func testMotionStillDetectedAfterLightingChangeSettles() {
        var detector = MotionDetector(configuration: defaultConfiguration)
        _ = detector.analyze(frame(fill: 40))
        _ = detector.analyze(frame(fill: 180))
        for _ in 0..<3 { _ = detector.analyze(frame(fill: 180)) }
        var triggered = false
        for step in 0..<3 {
            triggered = detector.analyze(frame(fill: 180, block: (10 + step * 50, 50, 45, 20))).triggered
        }
        XCTAssertTrue(triggered)
    }

    func testSensorNoiseDoesNotTrigger() {
        var detector = MotionDetector(configuration: defaultConfiguration)
        var triggered = false
        for seed in 1...30 {
            triggered = triggered || detector.analyze(frame(fill: 100, noise: 8, seed: UInt64(seed))).triggered
        }
        XCTAssertFalse(triggered)
    }

    func testFramesAreDownscaledToAnalysisResolution() {
        var detector = MotionDetector(configuration: defaultConfiguration)
        let large = GrayscaleFrame(width: 1280, height: 720, fill: 90)
        let analysis = detector.analyze(large)
        XCTAssertTrue(analysis.isBaseline)
        XCTAssertEqual(analysis.meanLuminance, 90, accuracy: 0.001)
    }

    func testDownscaleAveragesBlocks() {
        // 4×2 image → 2×1: left half 0/200, right half 100/100.
        let source = GrayscaleFrame(width: 4, height: 2, pixels: [0, 200, 100, 100, 200, 0, 100, 100])
        let scaled = source.downscaled(toWidth: 2, height: 1)
        XCTAssertEqual(scaled.pixels, [100, 100])
    }

    func testResetDiscardsBaseline() {
        var detector = MotionDetector(configuration: defaultConfiguration)
        _ = detector.analyze(frame())
        detector.reset()
        XCTAssertTrue(detector.analyze(frame(block: (0, 0, 100, 255))).isBaseline)
    }

    func testUpdatingConfigurationKeepsBaseline() {
        var detector = MotionDetector(configuration: defaultConfiguration)
        _ = detector.analyze(frame())
        var config = defaultConfiguration
        config.consecutiveFramesRequired = 1
        detector.update(configuration: config)
        XCTAssertTrue(detector.analyze(frame(block: (10, 50, 40, 230))).triggered)
    }

    func testFrameThrottlerAcceptsFiveFramesPerSecondFromThirty() {
        var throttler = FrameThrottler(interval: 0.2)
        var accepted = 0
        for index in 0..<30 {
            if throttler.shouldAccept(timestamp: Double(index) / 30.0) { accepted += 1 }
        }
        XCTAssertEqual(accepted, 5)
    }

    func testFrameThrottlerKeepsEverySecondFrameForFifteenFPS() {
        var throttler = FrameThrottler(interval: 1.0 / 15.0)
        var accepted = 0
        for index in 0..<60 {
            // 30 FPS with ±1 ms jitter
            let jitter = (index % 2 == 0 ? 0.001 : -0.001)
            if throttler.shouldAccept(timestamp: Double(index) / 30.0 + jitter) { accepted += 1 }
        }
        XCTAssertEqual(accepted, 30)
    }
}

/// Deterministic RNG for reproducible noise.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
