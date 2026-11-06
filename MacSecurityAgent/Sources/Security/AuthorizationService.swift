import Foundation

public enum ActivationOrigin: String, Sendable {
    case menuBar
    case settingsWindow
}

/// Proof that a person at the Mac asked to arm monitoring.
///
/// It can only be created by `AuthorizationService.makeLocalActivationRequest`,
/// which is main-actor isolated and is only called from local UI actions.
/// Network code (the Telegram poller, the upload queue) runs off the main
/// actor and has no way to construct one, and `TelegramCommand` has no arming
/// command at all, so a remote message can never switch the camera on.
public struct LocalActivationRequest: Sendable, Equatable {
    public let nonce: UUID
    public let origin: ActivationOrigin
    public let createdAt: Date

    fileprivate init(origin: ActivationOrigin, createdAt: Date) {
        self.nonce = UUID()
        self.origin = origin
        self.createdAt = createdAt
    }
}

@MainActor
public final class AuthorizationService {
    /// A request must be used promptly and only once.
    public static let requestLifetime: TimeInterval = 30

    private let now: @Sendable () -> Date
    private var outstanding: Set<UUID> = []

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func makeLocalActivationRequest(origin: ActivationOrigin) -> LocalActivationRequest {
        let request = LocalActivationRequest(origin: origin, createdAt: now())
        outstanding.insert(request.nonce)
        return request
    }

    /// Validates and consumes a request (single use, short lifetime).
    public func consume(_ request: LocalActivationRequest) -> Bool {
        guard outstanding.remove(request.nonce) != nil else { return false }
        let age = now().timeIntervalSince(request.createdAt)
        return age >= 0 && age <= Self.requestLifetime
    }

    /// Telegram command authorisation (delegates to `TelegramAuthenticator`).
    public nonisolated func authorizeTelegramUpdate(
        _ update: TelegramUpdate, ownerUserID: Int64?, botUsername: String?, now: Date = Date()
    ) -> TelegramAuthenticator.Decision {
        TelegramAuthenticator(authorizedUserID: ownerUserID, botUsername: botUsername).evaluate(update, now: now)
    }
}
