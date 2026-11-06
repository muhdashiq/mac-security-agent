import Foundation
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

public enum CameraPermissionStatus: String, Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted

    public var title: String {
        switch self {
        case .notDetermined: return "NOT REQUESTED"
        case .authorized: return "ALLOWED"
        case .denied: return "DENIED"
        case .restricted: return "RESTRICTED"
        }
    }
}

/// Abstraction over the system camera permission so the coordinator can be
/// tested without TCC.
public protocol CameraAuthorizing: Sendable {
    func currentStatus() -> CameraPermissionStatus
    /// Shows the official macOS permission prompt (only when not determined).
    func requestAccess() async -> CameraPermissionStatus
}

#if canImport(AVFoundation)
/// Uses the official TCC permission flow via `AVCaptureDevice`.
/// The microphone permission is never requested.
public struct CameraPermissionManager: CameraAuthorizing {
    /// Deep link to System Settings › Privacy & Security › Camera.
    public static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!

    public init() {}

    public func currentStatus() -> CameraPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    public func requestAccess() async -> CameraPermissionStatus {
        guard currentStatus() == .notDetermined else { return currentStatus() }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return currentStatus()
    }
}
#endif
