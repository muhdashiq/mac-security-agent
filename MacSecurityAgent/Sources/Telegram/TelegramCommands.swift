import Foundation

/// Commands understood by the bot. There is intentionally no command that
/// arms the camera: monitoring can only be activated locally.
public enum TelegramCommand: Sendable, Equatable {
    case status
    case events
    case help
    case start
    /// The owner asked to arm/disarm remotely; answered with an explanation.
    case remoteControlRequest(String)
    case unrecognized(String)

    public enum ParseError: Error, Sendable, Equatable {
        case empty
        case tooLong
        case notACommand
        case invalidCharacters
        case wrongBot
    }

    static let remoteControlNames: Set<String> = [
        "arm", "disarm", "start_monitoring", "stop_monitoring", "monitor", "enable", "disable", "record", "snapshot",
    ]

    /// Parses `/name` or `/name@BotName`. Arguments are not accepted.
    public static func parse(_ raw: String, botUsername: String?, maximumLength: Int = 64) -> Result<TelegramCommand, ParseError> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.count <= maximumLength else { return .failure(.tooLong) }
        guard text.hasPrefix("/") else { return .failure(.notACommand) }

        var token = String(text.dropFirst())
        if token.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            return .failure(.invalidCharacters)
        }
        if let at = token.firstIndex(of: "@") {
            let mention = String(token[token.index(after: at)...])
            token = String(token[..<at])
            if let botUsername, mention.lowercased() != botUsername.lowercased() {
                return .failure(.wrongBot)
            }
        }
        let name = token.lowercased()
        guard (1...32).contains(name.count),
              name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" })
        else { return .failure(.invalidCharacters) }

        switch name {
        case "status": return .success(.status)
        case "events": return .success(.events)
        case "help": return .success(.help)
        case "start": return .success(.start)
        default:
            if remoteControlNames.contains(name) { return .success(.remoteControlRequest(name)) }
            return .success(.unrecognized(name))
        }
    }
}

/// Snapshot of the agent state used to answer `/status`.
public struct StatusReport: Sendable, Equatable {
    public var monitoring: MonitoringState
    public var camera: CameraStatus
    public var networkAvailable: Bool
    public var telegram: TelegramStatus
    public var lastEvent: SecurityEvent?
    public var pendingUploads: Int
    public var armedSince: Date?
    public var powerSource: PowerSourceState
    public var displaySleep: DisplaySleepCompatibility

    public init(
        monitoring: MonitoringState, camera: CameraStatus, networkAvailable: Bool, telegram: TelegramStatus,
        lastEvent: SecurityEvent?, pendingUploads: Int, armedSince: Date?,
        powerSource: PowerSourceState = .unknown, displaySleep: DisplaySleepCompatibility = .notTested
    ) {
        self.monitoring = monitoring
        self.camera = camera
        self.networkAvailable = networkAvailable
        self.telegram = telegram
        self.lastEvent = lastEvent
        self.pendingUploads = pendingUploads
        self.armedSince = armedSince
        self.powerSource = powerSource
        self.displaySleep = displaySleep
    }
}

public protocol StatusReporting: Sendable {
    func statusReport() async -> StatusReport
    func recentEvents(limit: Int) async -> [SecurityEvent]
}

/// Builds replies for authorised commands. Read-only: nothing here changes
/// the monitoring state.
public struct TelegramCommandHandler: Sendable {
    private let reporter: any StatusReporting
    private let formatter: TelegramMessageFormatter

    public init(reporter: any StatusReporting, formatter: TelegramMessageFormatter = TelegramMessageFormatter()) {
        self.reporter = reporter
        self.formatter = formatter
    }

    public func response(to command: TelegramCommand) async -> String {
        switch command {
        case .status:
            return formatter.status(await reporter.statusReport())
        case .events:
            return formatter.eventHistory(await reporter.recentEvents(limit: 10))
        case .help, .start:
            return formatter.help()
        case .remoteControlRequest:
            return formatter.remoteControlRefused()
        case .unrecognized:
            return "Unknown command.\n\n" + formatter.help()
        }
    }
}

/// All user-visible Telegram texts (plain text, no parse mode, so no
/// formatting injection is possible).
public struct TelegramMessageFormatter: Sendable {
    public var timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    public func motionAlert(event: SecurityEvent, recordingStarted: Bool, snapshotEnabled: Bool) -> String {
        var lines = [
            "MAC SECURITY ALERT",
            "Motion detected.",
            "Event ID: \(event.id)",
            "Time: \(time(event.detectedAt))",
            "Camera: Active",
            "Video recording: \(recordingStarted ? "Started" : "Not recording")",
        ]
        if snapshotEnabled { lines.append("Snapshot will be delivered first.") }
        if recordingStarted { lines.append("Video will follow after recording completes.") }
        return lines.joined(separator: "\n")
    }

    public func snapshotCaption(event: SecurityEvent) -> String {
        "Snapshot · \(event.id) · \(dateTime(event.detectedAt)) · \(String(format: "%.1f", event.changedAreaPercent))% of frame changed"
    }

    public func videoCaption(event: SecurityEvent, duration: TimeInterval) -> String {
        "Video · \(event.id) · \(dateTime(event.detectedAt)) · \(Int(duration.rounded())) s"
    }

    public func armed(at date: Date) -> String {
        "Monitoring ARMED at \(time(date)). Camera active, idle sleep prevented."
    }

    public func disarmed(at date: Date, emergency: Bool) -> String {
        emergency
            ? "EMERGENCY STOP at \(time(date)). Camera released, monitoring DISARMED."
            : "Monitoring DISARMED at \(time(date)). Camera released."
    }

    public func cameraProblem(_ detail: String, at date: Date) -> String {
        "CAMERA PROBLEM at \(time(date)): \(detail)\nMonitoring is NOT effective until this is resolved."
    }

    public func cameraRecovered(at date: Date) -> String {
        "Camera frames are arriving again (\(time(date)))."
    }

    public func systemSleeping(at date: Date) -> String {
        "The Mac is going to sleep (\(time(date))). Monitoring is paused until it wakes."
    }

    public func systemWoke(at date: Date) -> String {
        "The Mac woke up (\(time(date))). Restarting the camera."
    }

    public func displaySleepInterruptsCamera() -> String {
        "Display sleep stopped camera frames on this Mac. The display was woken and will be kept awake while armed (lower the brightness to save power)."
    }

    public func deliveryFailed(eventID: EventID?, artifact: EventArtifact, reason: String) -> String {
        let subject = eventID.map { "\(artifact.rawValue) of \($0)" } ?? artifact.rawValue
        return "Delivery failed for \(subject): \(reason). The temporary media was deleted."
    }

    public func deliveryExpired(eventID: EventID?, artifact: EventArtifact) -> String {
        let subject = eventID.map { "\(artifact.rawValue) of \($0)" } ?? artifact.rawValue
        return "The \(subject) could not be delivered within the retention period and was deleted."
    }

    public func unauthorizedAttempt(userID: Int64?) -> String {
        "Security notice: a command from an unauthorised Telegram user (id \(userID.map(String.init) ?? "unknown")) was rejected."
    }

    public func help() -> String {
        """
        Mac Security Agent commands:
        /status – monitoring, camera, network and last event
        /events – recent event history
        /help – this list

        Monitoring can only be started at the Mac itself; the bot cannot activate the camera.
        """
    }

    public func remoteControlRefused() -> String {
        "Remote control is not supported. For privacy, monitoring can only be started or stopped at the Mac (menu bar). Use /status to check the current state."
    }

    public func status(_ report: StatusReport) -> String {
        var lines = [
            "Mac Security Agent status",
            "Monitoring: \(report.monitoring.title)",
            "Camera: \(report.camera.title)",
            "Network: \(report.networkAvailable ? "ONLINE" : "OFFLINE")",
            "Telegram: \(report.telegram.title)",
        ]
        if let since = report.armedSince { lines.append("Armed since: \(dateTime(since))") }
        if let event = report.lastEvent {
            lines.append("Last event: \(event.id) at \(dateTime(event.detectedAt)) (\(event.stage.title))")
        } else {
            lines.append("Last event: none")
        }
        lines.append("Pending uploads: \(report.pendingUploads)")
        lines.append("Power: \(report.powerSource.title)")
        return lines.joined(separator: "\n")
    }

    public func eventHistory(_ events: [SecurityEvent]) -> String {
        guard !events.isEmpty else { return "No events recorded." }
        var lines = ["Recent events (newest first):"]
        for event in events {
            lines.append(
                "\(event.id) · \(dateTime(event.detectedAt)) · \(event.stage.title) · snapshot: \(short(event.snapshotStatus)), video: \(short(event.videoStatus))"
            )
        }
        return lines.joined(separator: "\n")
    }

    private func short(_ status: DeliveryStatus) -> String {
        switch status {
        case .pending: return "pending"
        case .queued: return "queued"
        case .uploading: return "uploading"
        case .delivered: return "delivered"
        case .failed: return "failed"
        case .expired: return "expired"
        case .skipped: return "skipped"
        }
    }

    public func time(_ date: Date) -> String {
        format(date, "HH:mm:ss")
    }

    public func dateTime(_ date: Date) -> String {
        format(date, "yyyy-MM-dd HH:mm:ss")
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
