import Foundation

/// Long-polls `getUpdates` (outbound HTTPS only — no inbound port, no
/// webhook) and answers authorised commands.
public actor TelegramUpdatePoller {
    public struct Callbacks: Sendable {
        public var statusChanged: @Sendable (TelegramStatus) async -> Void
        public var unauthorizedAttempt: @Sendable (Int64?) async -> Void

        public init(
            statusChanged: @escaping @Sendable (TelegramStatus) async -> Void,
            unauthorizedAttempt: @escaping @Sendable (Int64?) async -> Void
        ) {
            self.statusChanged = statusChanged
            self.unauthorizedAttempt = unauthorizedAttempt
        }
    }

    private let sessionProvider: any TelegramSessionProviding
    private let offsetStore: any UpdateOffsetStoring
    private let handler: TelegramCommandHandler
    private let callbacks: Callbacks
    private let now: @Sendable () -> Date
    private let longPollTimeout: Int
    private let logger = AppLogger(category: "TelegramPoller")

    private var task: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var lastStatus: TelegramStatus?
    private var backlogSkipped = false

    public init(
        sessionProvider: any TelegramSessionProviding,
        offsetStore: any UpdateOffsetStoring,
        handler: TelegramCommandHandler,
        callbacks: Callbacks,
        longPollTimeout: Int = 25,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessionProvider = sessionProvider
        self.offsetStore = offsetStore
        self.handler = handler
        self.callbacks = callbacks
        self.longPollTimeout = longPollTimeout
        self.now = now
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.pollOnce()
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Restart after the configuration changed (new token / owner).
    public func reset() {
        backlogSkipped = false
        consecutiveFailures = 0
        lastStatus = nil
    }

    /// One `getUpdates` round trip. Returns the delay before the next poll.
    @discardableResult
    public func pollOnce() async -> TimeInterval {
        guard let session = sessionProvider.currentSession() else {
            await report(.notConfigured)
            return 5
        }
        do {
            if !backlogSkipped {
                try await skipBacklog(session)
            }
            let updates = try await session.api.getUpdates(
                offset: offsetStore.loadOffset(), timeoutSeconds: longPollTimeout, limit: 20
            )
            consecutiveFailures = 0
            await report(.connected)
            for update in updates {
                offsetStore.saveOffset(update.updateId + 1)
                await handle(update, session: session)
            }
            return 0
        } catch let error as TelegramError {
            consecutiveFailures += 1
            switch error.disposition {
            case .configuration:
                await report(.error(error.safeDescription))
                return 60
            case .retryable(let after):
                await report(error.isOffline ? .offline : .error(error.safeDescription))
                return max(after ?? 0, backoff())
            case .permanent:
                await report(.error(error.safeDescription))
                return 60
            }
        } catch {
            consecutiveFailures += 1
            await report(.offline)
            return backoff()
        }
    }

    /// Ignores commands that were sent while the agent was not running (on
    /// first start there is no stored offset). Stale messages are rejected
    /// by the authenticator anyway.
    private func skipBacklog(_ session: TelegramSession) async throws {
        if offsetStore.loadOffset() == nil {
            let latest = try await session.api.getUpdates(offset: -1, timeoutSeconds: 0, limit: 1)
            if let last = latest.last {
                offsetStore.saveOffset(last.updateId + 1)
            }
        }
        backlogSkipped = true
    }

    func handle(_ update: TelegramUpdate, session: TelegramSession) async {
        let authenticator = TelegramAuthenticator(authorizedUserID: session.ownerUserID, botUsername: session.botUsername)
        switch authenticator.evaluate(update, now: now()) {
        case .authorized(let command):
            let reply = await handler.response(to: command)
            do {
                _ = try await session.api.sendMessage(chatID: session.ownerUserID, text: reply)
            } catch let error as TelegramError {
                logger.warning("Reply failed: \(error.safeDescription)")
            } catch {
                logger.warning("Reply failed")
            }
        case .rejected(.unknownSender(let userID)):
            // Do not answer strangers; tell the owner instead (rate limited
            // by the coordinator).
            logger.warning("Rejected command from unauthorised user \(userID.map(String.init) ?? "unknown")")
            await callbacks.unauthorizedAttempt(userID)
        case .rejected(.malformedCommand):
            // Only reachable for the verified owner (sender/chat checks run
            // first): answer with the command list.
            _ = try? await session.api.sendMessage(chatID: session.ownerUserID, text: await handler.response(to: .help))
        case .rejected(let reason):
            logger.info("Ignored update: \(String(describing: reason))")
        }
    }

    private func backoff() -> TimeInterval {
        min(60, pow(2, Double(min(consecutiveFailures, 6))))
    }

    private func report(_ status: TelegramStatus) async {
        guard status != lastStatus else { return }
        lastStatus = status
        await callbacks.statusChanged(status)
    }
}
