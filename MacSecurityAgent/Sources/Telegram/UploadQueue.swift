import Foundation

/// What an upload delivers.
public enum UploadPayload: Codable, Sendable, Equatable {
    case text(String)
    case photo(media: StoredMedia, caption: String?)
    case video(media: StoredMedia, caption: String?, durationSeconds: Int?, width: Int?, height: Int?)

    public var media: StoredMedia? {
        switch self {
        case .text: return nil
        case .photo(let media, _), .video(let media, _, _, _, _): return media
        }
    }
}

public enum UploadState: String, Codable, Sendable {
    case pending
    /// Persisted *before* the request is sent. An item found in this state at
    /// launch may or may not have reached Telegram; it is re-sent once with a
    /// "possible duplicate" marker (at-least-once delivery).
    case inFlight
}

public struct UploadItem: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// Idempotency key, e.g. `EVT-00001.snapshot`. An item with a key that is
    /// queued or was already delivered is never enqueued again.
    public let deduplicationKey: String
    public let eventID: EventID?
    public let artifact: EventArtifact?
    public let payload: UploadPayload
    public let createdAt: Date
    public var attempts: Int
    public var nextAttemptAt: Date
    public var state: UploadState
    public var lastError: String?
    public var resumedAfterInterruption: Bool
}

public enum UploadQueueEvent: Sendable, Equatable {
    case uploading(UploadItem)
    case delivered(UploadItem, messageID: Int)
    case retryScheduled(UploadItem, delay: TimeInterval, reason: String)
    case failed(UploadItem, reason: String)
    case expired(UploadItem)
    case configurationProblem(String)
    case pendingCountChanged(Int)
}

/// Exponential backoff with jitter.
public struct RetryPolicy: Sendable, Equatable {
    public var baseDelay: TimeInterval
    public var maximumDelay: TimeInterval
    public var multiplier: Double
    /// ±fraction of random jitter applied to the computed delay.
    public var jitter: Double

    public static let standard = RetryPolicy(baseDelay: 2, maximumDelay: 300, multiplier: 2, jitter: 0.2)

    public init(baseDelay: TimeInterval, maximumDelay: TimeInterval, multiplier: Double, jitter: Double) {
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.multiplier = multiplier
        self.jitter = jitter
    }

    /// Delay before attempt `attempt + 1`, given `attempt` failed attempts.
    /// `random` is in 0...1 (0.5 = no jitter).
    public func delay(afterAttempt attempt: Int, random: Double) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let raw = min(maximumDelay, baseDelay * pow(multiplier, exponent))
        let jittered = raw + raw * jitter * (min(max(random, 0), 1) * 2 - 1)
        return min(maximumDelay, max(0.5, jittered))
    }
}

public enum EnqueueResult: Sendable, Equatable {
    case enqueued(UUID)
    case duplicate
}

public struct ProcessSummary: Sendable, Equatable {
    public var delivered = 0
    public var retried = 0
    public var failed = 0
    public var expired = 0
    public var deferredOffline = false
    public var notConfigured = false

    public init() {}
}

/// Durable, encrypted outbox for Telegram deliveries.
///
/// * Every alert, snapshot and video goes through the queue (outbox
///   pattern), so a crash or network loss never loses an event.
/// * Metadata is persisted as JSON (0600) separately from the encrypted media.
/// * Items are processed oldest-first; a network-type failure stops the pass,
///   which keeps alert → snapshot → video ordering per event.
/// * Media is deleted only after Telegram confirmed delivery (or the item
///   failed permanently / expired after the retention period, max 24 h).
public actor UploadQueue {
    private struct Persisted: Codable {
        var items: [UploadItem]
        var completedKeys: [String]
    }

    public static let maximumRememberedKeys = 2000
    public static let resendMarker = "[Resent after restart – may be a duplicate]"

    private let indexURL: URL?
    private let mediaStore: any MediaStoring
    private let sessionProvider: any TelegramSessionProviding
    private let policy: RetryPolicy
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let logger = AppLogger(category: "UploadQueue")

    private var retention: TimeInterval
    private var items: [UploadItem] = []
    private var completedKeys: [String] = []
    private var networkAvailable = true
    private var isProcessing = false
    private var lastConfigurationProblem: String?
    private var eventHandler: (@Sendable (UploadQueueEvent) async -> Void)?
    private var loopTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private let signalStream: AsyncStream<Void>
    private nonisolated let signal: AsyncStream<Void>.Continuation

    public init(
        indexURL: URL?,
        mediaStore: any MediaStoring,
        sessionProvider: any TelegramSessionProviding,
        retention: TimeInterval = ApplicationSettings.maximumRetentionHours * 3600,
        policy: RetryPolicy = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.indexURL = indexURL
        self.mediaStore = mediaStore
        self.sessionProvider = sessionProvider
        self.policy = policy
        self.now = now
        self.random = random
        self.retention = min(retention, ApplicationSettings.maximumRetentionHours * 3600)
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.signalStream = stream
        self.signal = continuation
        if let indexURL, let data = try? Data(contentsOf: indexURL),
           let persisted = try? JSONDecoder().decode(Persisted.self, from: data) {
            items = persisted.items
            completedKeys = persisted.completedKeys
        }
    }

    // MARK: Configuration

    public func setEventHandler(_ handler: (@Sendable (UploadQueueEvent) async -> Void)?) {
        eventHandler = handler
    }

    public func setRetention(_ interval: TimeInterval) {
        retention = min(max(interval, 60), ApplicationSettings.maximumRetentionHours * 3600)
    }

    public func setNetworkAvailable(_ available: Bool) {
        let recovered = available && !networkAvailable
        networkAvailable = available
        if recovered {
            // Network recovery: retry everything now instead of waiting for
            // the backoff timers.
            let date = now()
            for index in items.indices where items[index].state == .pending {
                items[index].nextAttemptAt = min(items[index].nextAttemptAt, date)
            }
            persist()
            kick()
        }
    }

    /// Re-check configuration problems now (after the owner fixed settings).
    public func configurationChanged() {
        lastConfigurationProblem = nil
        let date = now()
        for index in items.indices where items[index].state == .pending {
            items[index].nextAttemptAt = date
        }
        persist()
        kick()
    }

    // MARK: Queue operations

    @discardableResult
    public func enqueue(
        _ payload: UploadPayload,
        eventID: EventID?,
        artifact: EventArtifact?,
        deduplicationKey: String
    ) async -> EnqueueResult {
        guard !items.contains(where: { $0.deduplicationKey == deduplicationKey }),
              !completedKeys.contains(deduplicationKey)
        else {
            logger.warning("Duplicate upload suppressed: \(deduplicationKey)")
            return .duplicate
        }
        let date = now()
        let item = UploadItem(
            id: UUID(), deduplicationKey: deduplicationKey, eventID: eventID, artifact: artifact,
            payload: payload, createdAt: date, attempts: 0, nextAttemptAt: date,
            state: .pending, lastError: nil, resumedAfterInterruption: false
        )
        items.append(item)
        persist()
        await emit(.pendingCountChanged(items.count))
        kick()
        return .enqueued(item.id)
    }

    public func allItems() -> [UploadItem] { items }
    public var pendingCount: Int { items.count }
    public var isNetworkAvailable: Bool { networkAvailable }

    /// Called once at launch: re-arms items that were in flight when the app
    /// stopped, drops expired items and removes orphaned media files.
    @discardableResult
    public func recoverAfterLaunch() async -> Int {
        var recovered = 0
        for index in items.indices where items[index].state == .inFlight {
            items[index].state = .pending
            items[index].resumedAfterInterruption = true
            items[index].nextAttemptAt = now()
            recovered += 1
        }
        persist()
        var summary = ProcessSummary()
        await expireOldItems(&summary)
        let referenced = Set(items.compactMap { $0.payload.media?.id })
        _ = await mediaStore.purge(keeping: referenced)
        await emit(.pendingCountChanged(items.count))
        if !items.isEmpty { logger.info("Recovered \(items.count) pending upload(s) after launch") }
        return recovered
    }

    // MARK: Processing loop

    public func start(pollInterval: TimeInterval = 2) {
        guard loopTask == nil else { return }
        let stream = signalStream
        loopTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                _ = await self.processDueItems()
            }
        }
        let signal = self.signal
        tickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                signal.yield()
            }
        }
        kick()
    }

    public func stop() {
        tickTask?.cancel()
        tickTask = nil
        loopTask?.cancel()
        loopTask = nil
    }

    public nonisolated func kick() {
        signal.yield()
    }

    /// Delivers every item that is due. Safe to call concurrently (re-entrant
    /// calls return immediately).
    @discardableResult
    public func processDueItems() async -> ProcessSummary {
        var summary = ProcessSummary()
        guard !isProcessing else { return summary }
        isProcessing = true
        defer { isProcessing = false }

        await expireOldItems(&summary)

        guard networkAvailable else {
            summary.deferredOffline = !items.isEmpty
            return summary
        }
        guard let session = sessionProvider.currentSession() else {
            summary.notConfigured = !items.isEmpty
            return summary
        }

        while let index = nextDueIndex() {
            // Connectivity may change while a pass is awaiting the network.
            guard networkAvailable else {
                summary.deferredOffline = true
                return summary
            }
            items[index].state = .inFlight
            items[index].attempts += 1
            let item = items[index]
            persist()
            await emit(.uploading(item))

            do {
                let messageID = try await send(item, using: session)
                await complete(item.id, outcome: .delivered(messageID))
                summary.delivered += 1
            } catch let error as TelegramError {
                switch error.disposition {
                case .retryable(let after):
                    await scheduleRetry(item.id, reason: error.safeDescription, minimumDelay: after)
                    summary.retried += 1
                    // Offline / rate limited: stop this pass to keep ordering.
                    return summary
                case .configuration:
                    await scheduleRetry(item.id, reason: error.safeDescription, minimumDelay: policy.maximumDelay)
                    summary.retried += 1
                    if lastConfigurationProblem != error.safeDescription {
                        lastConfigurationProblem = error.safeDescription
                        await emit(.configurationProblem(error.safeDescription))
                    }
                    return summary
                case .permanent:
                    await complete(item.id, outcome: .failed(error.safeDescription))
                    summary.failed += 1
                }
            } catch let error as MediaStoreError {
                await complete(item.id, outcome: .failed(error.localizedDescription))
                summary.failed += 1
            } catch {
                await scheduleRetry(item.id, reason: "Unexpected error", minimumDelay: nil)
                summary.retried += 1
                return summary
            }
        }
        return summary
    }

    // MARK: Internals

    private enum Outcome {
        case delivered(Int)
        case failed(String)
        case expired
    }

    private func nextDueIndex() -> Int? {
        let date = now()
        return items.indices.first { items[$0].state == .pending && items[$0].nextAttemptAt <= date }
    }

    private func send(_ item: UploadItem, using session: TelegramSession) async throws -> Int {
        let chatID = session.ownerUserID
        func mark(_ text: String?) -> String? {
            guard item.resumedAfterInterruption else { return text }
            return [Self.resendMarker, text].compactMap { $0 }.joined(separator: "\n")
        }
        switch item.payload {
        case .text(let text):
            return try await session.api.sendMessage(chatID: chatID, text: mark(text) ?? text).messageId
        case .photo(let media, let caption):
            let data = try await mediaStore.load(media)
            return try await session.api.sendPhoto(chatID: chatID, jpegData: data, caption: mark(caption)).messageId
        case .video(let media, let caption, let duration, let width, let height):
            let data = try await mediaStore.load(media)
            return try await session.api.sendVideo(
                chatID: chatID, mp4Data: data, caption: mark(caption),
                durationSeconds: duration, width: width, height: height
            ).messageId
        }
    }

    private func scheduleRetry(_ id: UUID, reason: String, minimumDelay: TimeInterval?) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var delay = policy.delay(afterAttempt: items[index].attempts, random: random())
        if let minimumDelay { delay = max(delay, minimumDelay) }
        items[index].state = .pending
        items[index].lastError = reason
        items[index].nextAttemptAt = now().addingTimeInterval(delay)
        let item = items[index]
        persist()
        logger.info("Upload \(item.deduplicationKey) retry in \(Int(delay)) s: \(reason)")
        await emit(.retryScheduled(item, delay: delay, reason: reason))
    }

    private func complete(_ id: UUID, outcome: Outcome) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        if let media = item.payload.media {
            await mediaStore.delete(media)
        }
        switch outcome {
        case .delivered:
            completedKeys.append(item.deduplicationKey)
            if completedKeys.count > Self.maximumRememberedKeys {
                completedKeys.removeFirst(completedKeys.count - Self.maximumRememberedKeys)
            }
        case .failed, .expired:
            break
        }
        persist()
        switch outcome {
        case .delivered(let messageID):
            logger.info("Delivered \(item.deduplicationKey)")
            await emit(.delivered(item, messageID: messageID))
        case .failed(let reason):
            logger.error("Upload \(item.deduplicationKey) failed permanently: \(reason)")
            await emit(.failed(item, reason: reason))
        case .expired:
            logger.warning("Upload \(item.deduplicationKey) expired")
            await emit(.expired(item))
        }
        await emit(.pendingCountChanged(items.count))
    }

    private func expireOldItems(_ summary: inout ProcessSummary) async {
        let cutoff = now().addingTimeInterval(-retention)
        let expired = items.filter { $0.state == .pending && $0.createdAt <= cutoff }
        for item in expired {
            await complete(item.id, outcome: .expired)
            summary.expired += 1
        }
    }

    private func emit(_ event: UploadQueueEvent) async {
        await eventHandler?(event)
    }

    private func persist() {
        guard let indexURL else { return }
        do {
            try SecureFiles.createPrivateDirectory(at: indexURL.deletingLastPathComponent())
            let data = try JSONEncoder().encode(Persisted(items: items, completedKeys: completedKeys))
            try SecureFiles.writePrivateFile(data, to: indexURL)
        } catch {
            logger.error("Could not persist upload queue: \(error.localizedDescription)")
        }
    }
}
