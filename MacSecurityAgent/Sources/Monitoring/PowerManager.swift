import Foundation
#if canImport(IOKit)
import IOKit.ps
import IOKit.pwr_mgt
#endif

public enum PowerSourceState: Sendable, Equatable {
    case ac
    case battery(percent: Int?)
    case unknown

    public var title: String {
        switch self {
        case .ac: return "Power adapter"
        case .battery(let percent?): return "Battery (\(percent)%)"
        case .battery(nil): return "Battery"
        case .unknown: return "Unknown"
        }
    }
}

public enum PowerManagerError: Error, Sendable, Equatable, LocalizedError {
    case assertionFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .assertionFailed(let code): return "IOPMAssertionCreateWithName failed (\(code))"
        }
    }
}

/// Power management used while monitoring is armed.
@MainActor
public protocol PowerManaging: AnyObject {
    var isPreventingSystemSleep: Bool { get }
    var isPreventingDisplaySleep: Bool { get }
    /// Prevents idle *system* sleep (the display may still sleep).
    func beginMonitoring(keepDisplayAwake: Bool) throws
    /// Fallback when display sleep interrupts the camera.
    func setKeepDisplayAwake(_ keepAwake: Bool) throws
    /// Wakes the display (declares user activity).
    func wakeDisplay()
    /// Releases every assertion. Idempotent.
    func endMonitoring()
    func currentPowerSource() -> PowerSourceState
}

#if canImport(IOKit)

/// Uses the public IOKit power-assertion API.
///
/// * `PreventUserIdleSystemSleep` keeps the Mac awake while allowing the
///   display to sleep, which is the configuration the owner asked for.
/// * `PreventUserIdleDisplaySleep` is only taken as a fallback (setting
///   "Keep display awake", or automatically when the display-sleep probe finds
///   that the camera stops delivering frames with the display off).
///
/// Lid-closed (clamshell) operation is not supported: macOS sleeps the system
/// on lid close regardless of these assertions unless an external display and
/// power are connected, and the built-in camera is covered anyway.
@MainActor
public final class PowerManager: PowerManaging {
    private static let systemSleepAssertion = "PreventUserIdleSystemSleep" as CFString
    private static let displaySleepAssertion = "PreventUserIdleDisplaySleep" as CFString
    private static let reason = "MacSecurityAgent home monitoring is armed" as CFString

    private var systemAssertion: IOPMAssertionID?
    private var displayAssertion: IOPMAssertionID?
    private var userActivityAssertion: IOPMAssertionID = 0
    private let logger = AppLogger(category: "Power")

    public init() {}

    public var isPreventingSystemSleep: Bool { systemAssertion != nil }
    public var isPreventingDisplaySleep: Bool { displayAssertion != nil }

    public func beginMonitoring(keepDisplayAwake: Bool) throws {
        if systemAssertion == nil {
            systemAssertion = try Self.createAssertion(type: Self.systemSleepAssertion)
            logger.info("Idle system sleep prevented")
        }
        try setKeepDisplayAwake(keepDisplayAwake)
    }

    public func setKeepDisplayAwake(_ keepAwake: Bool) throws {
        if keepAwake, displayAssertion == nil {
            displayAssertion = try Self.createAssertion(type: Self.displaySleepAssertion)
            logger.info("Display sleep prevented (fallback)")
        } else if !keepAwake, let id = displayAssertion {
            IOPMAssertionRelease(id)
            displayAssertion = nil
        }
    }

    public func wakeDisplay() {
        IOPMAssertionDeclareUserActivity(Self.reason, kIOPMUserActiveLocal, &userActivityAssertion)
    }

    public func endMonitoring() {
        if let id = systemAssertion {
            IOPMAssertionRelease(id)
            systemAssertion = nil
        }
        if let id = displayAssertion {
            IOPMAssertionRelease(id)
            displayAssertion = nil
        }
        if userActivityAssertion != 0 {
            IOPMAssertionRelease(userActivityAssertion)
            userActivityAssertion = 0
        }
        logger.info("Power assertions released")
    }

    public func currentPowerSource() -> PowerSourceState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .unknown }
        guard let providing = IOPSGetProvidingPowerSourceType(info).map({ $0.takeUnretainedValue() as String }) else {
            return .unknown
        }
        if providing == "AC Power" { return .ac }
        guard providing == "Battery Power" else { return .unknown }
        var percent: Int?
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      let current = description["Current Capacity"] as? Int,
                      let maximum = description["Max Capacity"] as? Int, maximum > 0
                else { continue }
                percent = current * 100 / maximum
            }
        }
        return .battery(percent: percent)
    }

    /// Returns the assertion types this process currently holds (diagnostics
    /// and tests).
    public static func assertionTypesHeldByCurrentProcess() -> [String] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dictionary = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }
        let pid = NSNumber(value: ProcessInfo.processInfo.processIdentifier)
        return (dictionary[pid] ?? []).compactMap { $0["AssertType"] as? String }
    }

    private static func createAssertion(type: CFString) throws -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id)
        guard result == kIOReturnSuccess else { throw PowerManagerError.assertionFailed(result) }
        return id
    }
}
#endif
