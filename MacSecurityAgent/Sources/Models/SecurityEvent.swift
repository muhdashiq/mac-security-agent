import Foundation

/// Sequential, human-readable event identifier (`EVT-00001`).
public struct EventID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let sequence: Int

    public init(sequence: Int) {
        self.sequence = sequence
    }

    public init?(string: String) {
        guard string.hasPrefix("EVT-"), let value = Int(string.dropFirst(4)), value > 0 else { return nil }
        self.sequence = value
    }

    public var rawValue: String {
        let digits = String(sequence)
        let padding = String(repeating: "0", count: max(0, 5 - digits.count))
        return "EVT-\(padding)\(digits)"
    }

    public var description: String { rawValue }

    public static func < (lhs: EventID, rhs: EventID) -> Bool {
        lhs.sequence < rhs.sequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let id = EventID(string: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid event id")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Delivery state of one artefact (alert text, snapshot or video) of an event.
public enum DeliveryStatus: Codable, Sendable, Equatable {
    case pending
    case queued
    case uploading
    case delivered
    case failed(String)
    case expired
    case skipped(String)

    /// `true` once nothing more will happen for this artefact.
    public var isTerminal: Bool {
        switch self {
        case .delivered, .failed, .expired, .skipped: return true
        case .pending, .queued, .uploading: return false
        }
    }

    public var isSuccessfulOrSkipped: Bool {
        switch self {
        case .delivered, .skipped: return true
        default: return false
        }
    }

    public var title: String {
        switch self {
        case .pending: return "Pending"
        case .queued: return "Queued"
        case .uploading: return "Uploading"
        case .delivered: return "Delivered"
        case .failed(let reason): return "Failed (\(reason))"
        case .expired: return "Expired"
        case .skipped(let reason): return "Skipped (\(reason))"
        }
    }
}

/// Lifecycle stage of an event; mirrors the documented event lifecycle.
public enum EventLifecycleStage: String, Codable, Sendable {
    case motionDetected
    case snapshotCaptured
    case snapshotQueued
    case recording
    case videoQueued
    /// Every artefact was delivered (or intentionally skipped) and the
    /// temporary media was deleted.
    case completed
    /// At least one artefact failed permanently or expired.
    case incomplete
    /// The application terminated or monitoring was stopped mid-event.
    case interrupted

    public var title: String {
        switch self {
        case .motionDetected: return "Motion detected"
        case .snapshotCaptured: return "Snapshot captured"
        case .snapshotQueued: return "Snapshot queued"
        case .recording: return "Recording"
        case .videoQueued: return "Video queued"
        case .completed: return "Delivered"
        case .incomplete: return "Incomplete"
        case .interrupted: return "Interrupted"
        }
    }
}

/// Which artefact of an event an upload carries.
public enum EventArtifact: String, Codable, Sendable {
    case alert
    case snapshot
    case video
}

/// Metadata about a motion event. Contains no media; media lives encrypted in
/// `TemporaryMediaStore` until it has been delivered to Telegram.
public struct SecurityEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: EventID
    public let detectedAt: Date
    public var changedAreaPercent: Double
    public var stage: EventLifecycleStage
    public var alertStatus: DeliveryStatus
    public var snapshotStatus: DeliveryStatus
    public var videoStatus: DeliveryStatus
    public var recordingStartedAt: Date?
    public var recordingDuration: TimeInterval?
    public var completedAt: Date?

    public init(id: EventID, detectedAt: Date, changedAreaPercent: Double) {
        self.id = id
        self.detectedAt = detectedAt
        self.changedAreaPercent = changedAreaPercent
        self.stage = .motionDetected
        self.alertStatus = .pending
        self.snapshotStatus = .pending
        self.videoStatus = .pending
    }

    public func status(of artifact: EventArtifact) -> DeliveryStatus {
        switch artifact {
        case .alert: return alertStatus
        case .snapshot: return snapshotStatus
        case .video: return videoStatus
        }
    }

    public mutating func setStatus(_ status: DeliveryStatus, for artifact: EventArtifact) {
        switch artifact {
        case .alert: alertStatus = status
        case .snapshot: snapshotStatus = status
        case .video: videoStatus = status
        }
    }

    public var allArtifactsTerminal: Bool {
        alertStatus.isTerminal && snapshotStatus.isTerminal && videoStatus.isTerminal
    }

    public var isDeliveryConfirmed: Bool {
        alertStatus.isSuccessfulOrSkipped && snapshotStatus.isSuccessfulOrSkipped && videoStatus.isSuccessfulOrSkipped
    }
}
