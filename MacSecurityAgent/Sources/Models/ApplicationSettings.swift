import Foundation

public enum VideoResolution: String, Codable, Sendable, CaseIterable, Identifiable {
    case hd720
    case qhd540
    case nhd360

    public var id: String { rawValue }

    public var width: Int {
        switch self {
        case .hd720: return 1280
        case .qhd540: return 960
        case .nhd360: return 640
        }
    }

    public var height: Int {
        switch self {
        case .hd720: return 720
        case .qhd540: return 540
        case .nhd360: return 360
        }
    }

    public var title: String { "\(width) × \(height)" }
}

/// Which Telegram notifications are sent.
public struct NotificationPreferences: Codable, Sendable, Equatable {
    public var sendTextAlert: Bool = true
    public var sendSnapshot: Bool = true
    public var sendVideo: Bool = true
    public var notifyArmingChanges: Bool = true
    public var notifyCameraProblems: Bool = true
    public var notifyDeliveryFailures: Bool = true
    public var notifyUnauthorizedAttempts: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationPreferences.defaultValue
        sendTextAlert = try c.decodeIfPresent(Bool.self, forKey: .sendTextAlert) ?? d.sendTextAlert
        sendSnapshot = try c.decodeIfPresent(Bool.self, forKey: .sendSnapshot) ?? d.sendSnapshot
        sendVideo = try c.decodeIfPresent(Bool.self, forKey: .sendVideo) ?? d.sendVideo
        notifyArmingChanges = try c.decodeIfPresent(Bool.self, forKey: .notifyArmingChanges) ?? d.notifyArmingChanges
        notifyCameraProblems = try c.decodeIfPresent(Bool.self, forKey: .notifyCameraProblems) ?? d.notifyCameraProblems
        notifyDeliveryFailures = try c.decodeIfPresent(Bool.self, forKey: .notifyDeliveryFailures) ?? d.notifyDeliveryFailures
        notifyUnauthorizedAttempts = try c.decodeIfPresent(Bool.self, forKey: .notifyUnauthorizedAttempts) ?? d.notifyUnauthorizedAttempts
    }

    private static let defaultValue = NotificationPreferences()
}

/// User-editable configuration. Secrets (the bot token) are deliberately
/// *not* part of this type; they live in the Keychain.
public struct ApplicationSettings: Codable, Sendable, Equatable {
    public static let maximumRetentionHours: Double = 24
    public static let sensitivityRange: ClosedRange<Double> = 0...1
    public static let minimumAreaRange: ClosedRange<Double> = 0.1...25
    public static let consecutiveFramesRange: ClosedRange<Int> = 1...10
    public static let cooldownRange: ClosedRange<Double> = 5...600
    public static let videoDurationRange: ClosedRange<Double> = 5...60
    public static let retentionRange: ClosedRange<Double> = 1...maximumRetentionHours

    /// 0 = least sensitive, 1 = most sensitive.
    public var motionSensitivity: Double = 0.5
    /// Minimum share of the frame (percent) that must change.
    public var minimumMotionAreaPercent: Double = 1.0
    public var consecutiveFramesRequired: Int = 3
    public var eventCooldownSeconds: Double = 30
    public var videoDurationSeconds: Double = 30
    public var videoResolution: VideoResolution = .hd720
    /// Numeric Telegram user id of the owner. Also used as the chat id of the
    /// private chat with the bot.
    public var authorizedTelegramUserID: Int64?
    public var launchAtLogin: Bool = false
    public var mediaRetentionHours: Double = 24
    public var notifications = NotificationPreferences()
    /// Safe fallback when display sleep interrupts the camera: keep the display
    /// awake while armed (lower the brightness manually).
    public var keepDisplayAwake: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ApplicationSettings()
        motionSensitivity = try c.decodeIfPresent(Double.self, forKey: .motionSensitivity) ?? d.motionSensitivity
        minimumMotionAreaPercent = try c.decodeIfPresent(Double.self, forKey: .minimumMotionAreaPercent) ?? d.minimumMotionAreaPercent
        consecutiveFramesRequired = try c.decodeIfPresent(Int.self, forKey: .consecutiveFramesRequired) ?? d.consecutiveFramesRequired
        eventCooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .eventCooldownSeconds) ?? d.eventCooldownSeconds
        videoDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .videoDurationSeconds) ?? d.videoDurationSeconds
        videoResolution = (try? c.decodeIfPresent(VideoResolution.self, forKey: .videoResolution)) ?? d.videoResolution
        authorizedTelegramUserID = try c.decodeIfPresent(Int64.self, forKey: .authorizedTelegramUserID)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        mediaRetentionHours = try c.decodeIfPresent(Double.self, forKey: .mediaRetentionHours) ?? d.mediaRetentionHours
        notifications = try c.decodeIfPresent(NotificationPreferences.self, forKey: .notifications) ?? d.notifications
        keepDisplayAwake = try c.decodeIfPresent(Bool.self, forKey: .keepDisplayAwake) ?? d.keepDisplayAwake
    }

    /// Returns a copy with every value clamped into its supported range.
    public func validated() -> ApplicationSettings {
        var copy = self
        copy.motionSensitivity = motionSensitivity.clamped(to: Self.sensitivityRange)
        copy.minimumMotionAreaPercent = minimumMotionAreaPercent.clamped(to: Self.minimumAreaRange)
        copy.consecutiveFramesRequired = consecutiveFramesRequired.clamped(to: Self.consecutiveFramesRange)
        copy.eventCooldownSeconds = eventCooldownSeconds.clamped(to: Self.cooldownRange)
        copy.videoDurationSeconds = videoDurationSeconds.clamped(to: Self.videoDurationRange)
        copy.mediaRetentionHours = mediaRetentionHours.clamped(to: Self.retentionRange)
        if let id = authorizedTelegramUserID, id <= 0 {
            copy.authorizedTelegramUserID = nil
        }
        return copy
    }

    public var mediaRetentionInterval: TimeInterval {
        mediaRetentionHours.clamped(to: Self.retentionRange) * 3600
    }

    public var motionConfiguration: MotionDetectorConfiguration {
        MotionDetectorConfiguration(
            sensitivity: motionSensitivity,
            minimumAreaPercent: minimumMotionAreaPercent,
            consecutiveFramesRequired: consecutiveFramesRequired
        )
    }

    public var videoSettings: VideoRecordingSettings {
        VideoRecordingSettings(
            width: videoResolution.width,
            height: videoResolution.height,
            frameRate: 15,
            averageBitRate: 1_200_000,
            durationSeconds: videoDurationSeconds
        )
    }

    public var cameraConfiguration: CameraConfiguration {
        CameraConfiguration(motion: motionConfiguration, video: videoSettings)
    }
}

/// H.264 / MP4 recording parameters.
public struct VideoRecordingSettings: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var averageBitRate: Int
    public var durationSeconds: Double
    public var maxKeyFrameInterval: Int

    public init(
        width: Int = 1280,
        height: Int = 720,
        frameRate: Int = 15,
        averageBitRate: Int = 1_200_000,
        durationSeconds: Double = 30,
        maxKeyFrameInterval: Int = 30
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.averageBitRate = averageBitRate
        self.durationSeconds = durationSeconds
        self.maxKeyFrameInterval = maxKeyFrameInterval
    }
}

/// Camera pipeline parameters.
public struct CameraConfiguration: Sendable, Equatable {
    public var captureWidth: Int
    public var captureHeight: Int
    /// Requested sensor frame rate (also the recording rate).
    public var captureFrameRate: Int
    /// Interval between motion analyses (≈5 FPS).
    public var analysisInterval: TimeInterval
    public var motion: MotionDetectorConfiguration
    public var video: VideoRecordingSettings

    public init(
        captureWidth: Int = 1280,
        captureHeight: Int = 720,
        captureFrameRate: Int = 15,
        analysisInterval: TimeInterval = 0.2,
        motion: MotionDetectorConfiguration = MotionDetectorConfiguration(),
        video: VideoRecordingSettings = VideoRecordingSettings()
    ) {
        self.captureWidth = captureWidth
        self.captureHeight = captureHeight
        self.captureFrameRate = captureFrameRate
        self.analysisInterval = analysisInterval
        self.motion = motion
        self.video = video
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
