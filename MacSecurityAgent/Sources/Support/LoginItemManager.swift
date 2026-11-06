#if canImport(ServiceManagement)
import Foundation
import ServiceManagement

/// "Open at login" via `SMAppService` (macOS 13+). Launching at login never
/// arms monitoring; it only starts the menu-bar agent.
@MainActor
public final class LoginItemManager {
    public enum Status: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable(String)
    }

    public init() {}

    public var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable("App bundle not found by launchd (move the app to /Applications).")
        @unknown default: return .disabled
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
#endif
