import Foundation

/// Persists event *metadata* (never media) as JSON in Application Support.
public actor EventRepository {
    private struct Persisted: Codable {
        var nextSequence: Int
        var events: [SecurityEvent]
    }

    private let fileURL: URL?
    private let maxEvents: Int
    private var state: Persisted
    private let logger = AppLogger(category: "EventRepository")

    /// - Parameter fileURL: `nil` keeps everything in memory (tests).
    public init(fileURL: URL?, maxEvents: Int = 500) {
        self.fileURL = fileURL
        self.maxEvents = max(1, maxEvents)
        var loaded = Persisted(nextSequence: 1, events: [])
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
                loaded = decoded
            } else {
                // Keep the sequence monotonic even if the file is corrupt.
                let backup = fileURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: fileURL, to: backup)
                loaded.nextSequence = 1
            }
        }
        let highest = loaded.events.map(\.id.sequence).max() ?? 0
        loaded.nextSequence = max(loaded.nextSequence, highest + 1)
        self.state = loaded
    }

    public func allocateEventID() -> EventID {
        let id = EventID(sequence: state.nextSequence)
        state.nextSequence += 1
        persist()
        return id
    }

    public func upsert(_ event: SecurityEvent) {
        if let index = state.events.firstIndex(where: { $0.id == event.id }) {
            state.events[index] = event
        } else {
            state.events.append(event)
            state.events.sort { $0.id < $1.id }
            if state.events.count > maxEvents {
                state.events.removeFirst(state.events.count - maxEvents)
            }
        }
        persist()
    }

    /// Atomically applies `change` to the stored event and persists it.
    public func modify(_ id: EventID, _ change: (inout SecurityEvent) -> Void) -> SecurityEvent? {
        guard let index = state.events.firstIndex(where: { $0.id == id }) else { return nil }
        change(&state.events[index])
        persist()
        return state.events[index]
    }

    public func event(id: EventID) -> SecurityEvent? {
        state.events.first { $0.id == id }
    }

    /// Newest first.
    public func recent(limit: Int) -> [SecurityEvent] {
        Array(state.events.suffix(max(0, limit)).reversed())
    }

    public func removeAll(keeping id: EventID?) {
        state.events.removeAll { $0.id != id }
        persist()
    }

    public var count: Int { state.events.count }

    private func persist() {
        guard let fileURL else { return }
        do {
            try SecureFiles.createPrivateDirectory(at: fileURL.deletingLastPathComponent())
            let data = try JSONEncoder().encode(state)
            try SecureFiles.writePrivateFile(data, to: fileURL)
        } catch {
            logger.error("Could not persist events: \(error.localizedDescription)")
        }
    }
}
