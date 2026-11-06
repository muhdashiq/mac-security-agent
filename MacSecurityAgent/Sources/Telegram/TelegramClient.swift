import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Transport

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 30) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Outbound HTTPS only. Uses an ephemeral session (no cookies, no cache, no
/// credential storage) and refuses any non-HTTPS URL.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        #if canImport(Darwin)
        // Fail fast when offline; the upload queue owns retries.
        configuration.waitsForConnectivity = false
        #endif
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.scheme?.lowercased() == "https" else { throw TelegramError.insecureURL }
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return HTTPResponse(statusCode: status, body: data)
        } catch let error as URLError {
            // Never propagate the URLError itself: its userInfo contains the
            // request URL, which contains the bot token.
            throw TelegramError.network(code: error.code.rawValue)
        } catch {
            throw TelegramError.network(code: URLError.Code.unknown.rawValue)
        }
    }
}

// MARK: - Credentials

/// A Telegram bot token. Its textual representations are redacted so it can
/// never be printed or logged by accident.
public struct BotToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    fileprivate let value: String

    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(trimmed) else { return nil }
        value = trimmed
    }

    public static func isValid(_ candidate: String) -> Bool {
        guard let separator = candidate.firstIndex(of: ":") else { return false }
        let botID = candidate[..<separator]
        let secret = candidate[candidate.index(after: separator)...]
        guard (5...16).contains(botID.count), botID.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        guard (30...64).contains(secret.count) else { return false }
        return secret.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// The numeric bot id (public information, safe to show).
    public var botID: String {
        String(value.prefix { $0 != ":" })
    }

    public var description: String { "BotToken(\(botID):[REDACTED])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["botID": botID]) }

    /// Raw value for Keychain storage only.
    public var secretValueForStorage: String { value }
}

// MARK: - API models

public struct TelegramUser: Codable, Sendable, Equatable {
    public let id: Int64
    public let isBot: Bool
    public let firstName: String?
    public let username: String?

    public init(id: Int64, isBot: Bool, firstName: String? = nil, username: String? = nil) {
        self.id = id
        self.isBot = isBot
        self.firstName = firstName
        self.username = username
    }
}

public struct TelegramChat: Codable, Sendable, Equatable {
    public let id: Int64
    public let type: String

    public init(id: Int64, type: String) {
        self.id = id
        self.type = type
    }
}

public struct TelegramForwardOrigin: Codable, Sendable, Equatable {
    public let type: String
}

public struct TelegramMessage: Codable, Sendable, Equatable {
    public let messageId: Int
    public let from: TelegramUser?
    public let chat: TelegramChat
    public let date: Int
    public let text: String?
    public let forwardDate: Int?
    public let forwardOrigin: TelegramForwardOrigin?
    public let viaBot: TelegramUser?

    public init(
        messageId: Int, from: TelegramUser?, chat: TelegramChat, date: Int, text: String?,
        forwardDate: Int? = nil, forwardOrigin: TelegramForwardOrigin? = nil, viaBot: TelegramUser? = nil
    ) {
        self.messageId = messageId
        self.from = from
        self.chat = chat
        self.date = date
        self.text = text
        self.forwardDate = forwardDate
        self.forwardOrigin = forwardOrigin
        self.viaBot = viaBot
    }
}

public struct TelegramUpdate: Codable, Sendable, Equatable {
    public let updateId: Int64
    public let message: TelegramMessage?

    public init(updateId: Int64, message: TelegramMessage?) {
        self.updateId = updateId
        self.message = message
    }
}

// MARK: - Errors

public enum TelegramError: Error, Sendable, Equatable, LocalizedError {
    /// Transport failure (offline, timeout, DNS, TLS ...). `code` is the
    /// `URLError.Code` raw value.
    case network(code: Int)
    /// The Bot API answered `ok: false`.
    case api(code: Int, description: String, retryAfter: Int?)
    /// Non-JSON answer with this HTTP status.
    case http(status: Int)
    case decoding
    case insecureURL
    case notConfigured

    public enum Disposition: Sendable, Equatable {
        /// Try again later (optionally after the server-provided delay).
        case retryable(after: TimeInterval?)
        /// Wrong token / chat / bot blocked: retrying will not help until the
        /// owner fixes the configuration, but the item is kept until expiry.
        case configuration
        /// The request itself is invalid (e.g. file too large).
        case permanent
    }

    public var disposition: Disposition {
        switch self {
        case .network, .decoding:
            return .retryable(after: nil)
        case .http(let status):
            return status >= 500 || status == 429 || status == 0 ? .retryable(after: nil) : .permanent
        case .api(let code, let description, let retryAfter):
            switch code {
            case 429: return .retryable(after: retryAfter.map(TimeInterval.init))
            case 500...599: return .retryable(after: nil)
            case 401, 403, 404: return .configuration
            case 409: return .configuration
            case 400:
                let lowered = description.lowercased()
                if lowered.contains("chat not found") || lowered.contains("user not found") || lowered.contains("bot was blocked") {
                    return .configuration
                }
                return .permanent
            case 413: return .permanent
            default: return .retryable(after: nil)
            }
        case .insecureURL:
            return .permanent
        case .notConfigured:
            return .configuration
        }
    }

    public var isOffline: Bool {
        if case .network = self { return true }
        return false
    }

    /// A description that is safe to log and display.
    public var safeDescription: String {
        switch self {
        case .network(let code): return "Network error (\(code))"
        case .api(let code, let description, _): return LogSanitizer.sanitize("Telegram error \(code): \(description)")
        case .http(let status): return "HTTP status \(status)"
        case .decoding: return "Unexpected response from Telegram"
        case .insecureURL: return "Refused non-HTTPS request"
        case .notConfigured: return "Telegram is not configured"
        }
    }

    public var errorDescription: String? { safeDescription }
}

// MARK: - Client protocols

public protocol TelegramSending: Sendable {
    func sendMessage(chatID: Int64, text: String) async throws -> TelegramMessage
    func sendPhoto(chatID: Int64, jpegData: Data, caption: String?) async throws -> TelegramMessage
    func sendVideo(
        chatID: Int64, mp4Data: Data, caption: String?, durationSeconds: Int?, width: Int?, height: Int?
    ) async throws -> TelegramMessage
}

public protocol TelegramAPI: TelegramSending {
    func getMe() async throws -> TelegramUser
    func getUpdates(offset: Int64?, timeoutSeconds: Int, limit: Int) async throws -> [TelegramUpdate]
}

// MARK: - Client

/// Minimal client for the official Telegram Bot API
/// (https://core.telegram.org/bots/api), using only outbound HTTPS.
public final class TelegramClient: TelegramAPI {
    public static let apiHost = "api.telegram.org"
    public static let maximumCaptionLength = 1024
    public static let maximumMessageLength = 4096
    /// Bot API upload limit for `sendVideo` / `sendPhoto` via multipart.
    public static let maximumUploadBytes = 50 * 1024 * 1024

    private let token: BotToken
    private let transport: any HTTPTransport

    public init(token: BotToken, transport: any HTTPTransport = URLSessionTransport()) {
        self.token = token
        self.transport = transport
    }

    public func getMe() async throws -> TelegramUser {
        try await call("getMe", json: [:], timeout: 20)
    }

    public func getUpdates(offset: Int64?, timeoutSeconds: Int, limit: Int = 20) async throws -> [TelegramUpdate] {
        var body: [String: JSONValue] = [
            "timeout": .int(Int64(max(0, timeoutSeconds))),
            "limit": .int(Int64(min(max(limit, 1), 100))),
            "allowed_updates": .array([.string("message")]),
        ]
        if let offset { body["offset"] = .int(offset) }
        return try await call("getUpdates", json: body, timeout: TimeInterval(timeoutSeconds) + 15)
    }

    public func sendMessage(chatID: Int64, text: String) async throws -> TelegramMessage {
        try await call("sendMessage", json: [
            "chat_id": .int(chatID),
            "text": .string(String(text.prefix(Self.maximumMessageLength))),
            "disable_web_page_preview": .bool(true),
        ], timeout: 30)
    }

    public func sendPhoto(chatID: Int64, jpegData: Data, caption: String?) async throws -> TelegramMessage {
        var form = MultipartFormData()
        form.addField(name: "chat_id", value: String(chatID))
        if let caption { form.addField(name: "caption", value: String(caption.prefix(Self.maximumCaptionLength))) }
        form.addFile(name: "photo", fileName: "snapshot.jpg", mimeType: "image/jpeg", data: jpegData)
        return try await call("sendPhoto", form: form, timeout: 120)
    }

    public func sendVideo(
        chatID: Int64, mp4Data: Data, caption: String?, durationSeconds: Int?, width: Int?, height: Int?
    ) async throws -> TelegramMessage {
        guard mp4Data.count <= Self.maximumUploadBytes else {
            throw TelegramError.api(code: 413, description: "Request Entity Too Large", retryAfter: nil)
        }
        var form = MultipartFormData()
        form.addField(name: "chat_id", value: String(chatID))
        if let caption { form.addField(name: "caption", value: String(caption.prefix(Self.maximumCaptionLength))) }
        if let durationSeconds { form.addField(name: "duration", value: String(durationSeconds)) }
        if let width { form.addField(name: "width", value: String(width)) }
        if let height { form.addField(name: "height", value: String(height)) }
        form.addField(name: "supports_streaming", value: "true")
        form.addFile(name: "video", fileName: "recording.mp4", mimeType: "video/mp4", data: mp4Data)
        return try await call("sendVideo", form: form, timeout: 300)
    }

    // MARK: Plumbing

    func endpoint(_ method: String) -> URL {
        // Built from fixed components only; the token never leaves this type
        // except inside the HTTPS request line.
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.apiHost
        components.path = "/bot\(token.value)/\(method)"
        return components.url!
    }

    private func call<Result: Decodable>(_ method: String, json: [String: JSONValue], timeout: TimeInterval) async throws -> Result {
        let body = try JSONEncoder().encode(json)
        let request = HTTPRequest(
            url: endpoint(method),
            headers: ["Content-Type": "application/json"],
            body: body,
            timeout: timeout
        )
        return try await perform(request)
    }

    private func call<Result: Decodable>(_ method: String, form: MultipartFormData, timeout: TimeInterval) async throws -> Result {
        let request = HTTPRequest(
            url: endpoint(method),
            headers: ["Content-Type": form.contentType],
            body: form.encoded(),
            timeout: timeout
        )
        return try await perform(request)
    }

    private func perform<Result: Decodable>(_ request: HTTPRequest) async throws -> Result {
        let response = try await transport.send(request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let envelope = try? decoder.decode(Envelope<Result>.self, from: response.body) else {
            if (200..<300).contains(response.statusCode) { throw TelegramError.decoding }
            throw TelegramError.http(status: response.statusCode)
        }
        if envelope.ok, let result = envelope.result {
            return result
        }
        throw TelegramError.api(
            code: envelope.errorCode ?? response.statusCode,
            description: envelope.description ?? "Unknown error",
            retryAfter: envelope.parameters?.retryAfter
        )
    }

    private struct Envelope<Result: Decodable>: Decodable {
        let ok: Bool
        let result: Result?
        let description: String?
        let errorCode: Int?
        let parameters: Parameters?
    }

    private struct Parameters: Decodable {
        let retryAfter: Int?
    }
}

// MARK: - Encoding helpers

/// Small JSON value type so request bodies stay Sendable and explicit.
public enum JSONValue: Encodable, Sendable, Equatable {
    case string(String)
    case int(Int64)
    case bool(Bool)
    case array([JSONValue])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        }
    }
}

/// `multipart/form-data` body builder (RFC 7578).
public struct MultipartFormData: Sendable {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "MSA-Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(name: String, value: String) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(Self.escape(name))\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    public mutating func addFile(name: String, fileName: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(Self.escape(name))\"; filename=\"\(Self.escape(fileName))\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    public func encoded() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }
}

// MARK: - Session configuration

/// Everything needed to talk to the owner's bot.
public struct TelegramSession: Sendable {
    public let api: any TelegramAPI
    /// Numeric user id of the owner; also the private chat id.
    public let ownerUserID: Int64
    public let botUsername: String?

    public init(api: any TelegramAPI, ownerUserID: Int64, botUsername: String?) {
        self.api = api
        self.ownerUserID = ownerUserID
        self.botUsername = botUsername
    }
}

public protocol TelegramSessionProviding: Sendable {
    func currentSession() -> TelegramSession?
}

/// Thread-safe holder for the active Telegram session; updated when the owner
/// changes the configuration.
public final class TelegramConfigurationStore: TelegramSessionProviding {
    private let session = LockedValue<TelegramSession?>(nil)

    public init(session: TelegramSession? = nil) {
        self.session.set(session)
    }

    public func update(_ newValue: TelegramSession?) {
        session.set(newValue)
    }

    public func currentSession() -> TelegramSession? {
        session.current
    }
}
