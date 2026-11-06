import Foundation

/// Reads and writes the Telegram bot token in secure storage (Keychain).
/// The token is never written to user defaults, files or logs.
public struct TelegramCredentialStore: Sendable {
    public static let tokenKey = "telegram.bot-token.v1"
    private let storage: any SecureStorage

    public init(storage: any SecureStorage) {
        self.storage = storage
    }

    public func loadToken() throws -> BotToken? {
        guard let data = try storage.readData(forKey: Self.tokenKey),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return BotToken(string)
    }

    public func saveToken(_ token: BotToken) throws {
        try storage.writeData(Data(token.secretValueForStorage.utf8), forKey: Self.tokenKey)
    }

    public func deleteToken() throws {
        try storage.deleteData(forKey: Self.tokenKey)
    }

    public func hasToken() -> Bool {
        (try? loadToken()) != nil
    }
}
