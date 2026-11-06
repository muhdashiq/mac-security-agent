import Foundation

/// Why monitoring is in the error phase.
public enum MonitoringFailure: Sendable, Equatable {
    case cameraPermissionDenied
    case cameraUnavailable(String)
    case cameraStalled
    case powerAssertionFailed(String)
    case storageUnavailable(String)
    case activationRejected

    public var userMessage: String {
        switch self {
        case .cameraPermissionDenied:
            return "Camera access was denied. Allow MacSecurityAgent in System Settings › Privacy & Security › Camera."
        case .cameraUnavailable(let detail):
            return "The camera is unavailable: \(detail)"
        case .cameraStalled:
            return "Camera frames stopped arriving. Monitoring is not effective."
        case .powerAssertionFailed(let detail):
            return "Could not prevent system sleep: \(detail)"
        case .storageUnavailable(let detail):
            return "Secure temporary storage is unavailable: \(detail)"
        case .activationRejected:
            return "Monitoring can only be started locally from the menu bar."
        }
    }
}

/// The internal state machine of the monitoring coordinator.
///
/// `MonitoringState` (below) is the user-facing projection of this phase plus
/// connectivity information.
public enum MonitoringPhase: Sendable, Equatable {
    case disarmed
    case arming
    case armed
    case motionDetected
    case recording
    case stopping
    case error(MonitoringFailure)

    /// Phases in which the camera is (supposed to be) running.
    public var isCameraPhase: Bool {
        switch self {
        case .armed, .motionDetected, .recording: return true
        default: return false
        }
    }

    public var isError: Bool {
        if case .error = self { return true }
        return false
    }

    /// Whether `next` is a legal successor of `self`. The coordinator refuses
    /// any other transition, which prevents conflicting operations such as
    /// starting a recording while stopping, or arming twice.
    public func canTransition(to next: MonitoringPhase) -> Bool {
        switch (self, next) {
        case (.disarmed, .arming):
            return true
        case (.arming, .armed), (.arming, .error), (.arming, .stopping):
            return true
        case (.armed, .motionDetected), (.armed, .stopping), (.armed, .error):
            return true
        case (.motionDetected, .recording), (.motionDetected, .armed),
             (.motionDetected, .stopping), (.motionDetected, .error):
            return true
        case (.recording, .armed), (.recording, .stopping), (.recording, .error):
            return true
        case (.stopping, .disarmed):
            return true
        case (.error, .arming), (.error, .stopping), (.error, .disarmed), (.error, .error):
            return true
        default:
            return false
        }
    }
}

/// User-facing monitoring state (shown in the menu bar and in `/status`).
public enum MonitoringState: String, Sendable, CaseIterable, Codable {
    case disarmed
    case arming
    case armed
    case motionDetected
    case recording
    case uploading
    case offline
    case error

    public static func derive(
        phase: MonitoringPhase,
        cameraStatus: CameraStatus,
        isNetworkAvailable: Bool,
        pendingUploads: Int
    ) -> MonitoringState {
        switch phase {
        case .error:
            return .error
        case .disarmed, .stopping:
            return .disarmed
        case .arming:
            return .arming
        case .motionDetected:
            return .motionDetected
        case .recording:
            return .recording
        case .armed:
            if cameraStatus == .stalled { return .error }
            if case .unavailable = cameraStatus { return .error }
            if !isNetworkAvailable { return .offline }
            if pendingUploads > 0 { return .uploading }
            return .armed
        }
    }

    public var title: String {
        switch self {
        case .disarmed: return "DISARMED"
        case .arming: return "ARMING"
        case .armed: return "ARMED"
        case .motionDetected: return "MOTION DETECTED"
        case .recording: return "RECORDING"
        case .uploading: return "ARMED · UPLOADING"
        case .offline: return "ARMED · OFFLINE"
        case .error: return "ERROR"
        }
    }

    public var symbolName: String {
        switch self {
        case .disarmed: return "shield.slash"
        case .arming: return "shield.lefthalf.filled"
        case .armed: return "shield.fill"
        case .motionDetected: return "exclamationmark.shield.fill"
        case .recording: return "record.circle.fill"
        case .uploading: return "arrow.up.circle.fill"
        case .offline: return "wifi.exclamationmark"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

public enum CameraStatus: Sendable, Equatable {
    case inactive
    case starting
    case active
    case stalled
    case unavailable(String)

    public var title: String {
        switch self {
        case .inactive: return "INACTIVE"
        case .starting: return "STARTING"
        case .active: return "ACTIVE"
        case .stalled: return "NO FRAMES"
        case .unavailable: return "UNAVAILABLE"
        }
    }
}

public enum TelegramStatus: Sendable, Equatable {
    case notConfigured
    case connecting
    case connected
    case offline
    case error(String)

    public var title: String {
        switch self {
        case .notConfigured: return "NOT CONFIGURED"
        case .connecting: return "CONNECTING"
        case .connected: return "CONNECTED"
        case .offline: return "OFFLINE"
        case .error: return "ERROR"
        }
    }
}

/// Result of checking whether the camera keeps delivering frames while the
/// display is asleep.
public enum DisplaySleepCompatibility: Sendable, Equatable {
    case notTested
    case testing
    case verified(Date)
    case interruptsCamera(Date)

    public var title: String {
        switch self {
        case .notTested: return "Not yet tested"
        case .testing: return "Testing…"
        case .verified: return "Verified – camera keeps running"
        case .interruptsCamera: return "Display sleep interrupts camera – display kept awake"
        }
    }
}
