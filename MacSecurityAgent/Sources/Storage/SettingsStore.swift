import Foundation

/// Persists `ApplicationSettings` (no secrets) in user defaults.
public final class SettingsStore: @unchecked Sendable {
    private static let key = "settings.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ApplicationSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(ApplicationSettings.self, from: data)
        else { return ApplicationSettings() }
        return settings.validated()
    }

    public func save(_ settings: ApplicationSettings) {
        guard let data = try? JSONEncoder().encode(settings.validated()) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Persists the Telegram `getUpdates` offset so commands are processed once.
public protocol UpdateOffsetStoring: Sendable {
    func loadOffset() -> Int64?
    func saveOffset(_ offset: Int64)
}

public final class UserDefaultsOffsetStore: UpdateOffsetStoring, @unchecked Sendable {
    private static let key = "telegram.update-offset.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadOffset() -> Int64? {
        guard defaults.object(forKey: Self.key) != nil else { return nil }
        return Int64(defaults.integer(forKey: Self.key))
    }

    public func saveOffset(_ offset: Int64) {
        defaults.set(Int(offset), forKey: Self.key)
    }
}

public final class InMemoryOffsetStore: UpdateOffsetStoring {
    private let value = LockedValue<Int64?>(nil)

    public init(offset: Int64? = nil) {
        value.set(offset)
    }

    public func loadOffset() -> Int64? { value.current }
    public func saveOffset(_ offset: Int64) { value.set(offset) }
}
