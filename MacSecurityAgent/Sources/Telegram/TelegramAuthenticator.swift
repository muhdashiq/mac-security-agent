import Foundation

/// Validates every incoming Telegram update before any command is handled.
///
/// A command is accepted only if *all* of the following hold:
/// * an authorised owner id is configured,
/// * the sender is that user id and not a bot,
/// * the message was sent in the private chat with that user (chat id ==
///   user id, chat type `private`),
/// * the message is not forwarded and not sent via an inline bot,
/// * the message is recent (prevents replay of an old backlog),
/// * the text is a short, well-formed bot command.
public struct TelegramAuthenticator: Sendable {
    public enum RejectionReason: Sendable, Equatable {
        case notConfigured
        case noMessage
        case unknownSender(userID: Int64?)
        case botSender
        case nonPrivateChat
        case chatMismatch
        case forwarded
        case staleMessage
        case malformedCommand
        case wrongBot
    }

    public enum Decision: Sendable, Equatable {
        case authorized(TelegramCommand)
        case rejected(RejectionReason)
    }

    public let authorizedUserID: Int64?
    public let botUsername: String?
    public var maximumMessageAge: TimeInterval
    public var maximumTextLength: Int

    public init(
        authorizedUserID: Int64?,
        botUsername: String? = nil,
        maximumMessageAge: TimeInterval = 300,
        maximumTextLength: Int = 64
    ) {
        self.authorizedUserID = authorizedUserID
        self.botUsername = botUsername
        self.maximumMessageAge = maximumMessageAge
        self.maximumTextLength = maximumTextLength
    }

    public func evaluate(_ update: TelegramUpdate, now: Date = Date()) -> Decision {
        guard let owner = authorizedUserID, owner > 0 else { return .rejected(.notConfigured) }
        guard let message = update.message else { return .rejected(.noMessage) }
        guard let sender = message.from else { return .rejected(.unknownSender(userID: nil)) }
        guard sender.id == owner else { return .rejected(.unknownSender(userID: sender.id)) }
        guard !sender.isBot else { return .rejected(.botSender) }
        guard message.chat.type == "private" else { return .rejected(.nonPrivateChat) }
        guard message.chat.id == owner else { return .rejected(.chatMismatch) }
        guard message.forwardDate == nil, message.forwardOrigin == nil, message.viaBot == nil else {
            return .rejected(.forwarded)
        }
        let sentAt = Date(timeIntervalSince1970: TimeInterval(message.date))
        guard now.timeIntervalSince(sentAt) <= maximumMessageAge else { return .rejected(.staleMessage) }

        guard let text = message.text else { return .rejected(.malformedCommand) }
        switch TelegramCommand.parse(text, botUsername: botUsername, maximumLength: maximumTextLength) {
        case .success(let command): return .authorized(command)
        case .failure(.wrongBot): return .rejected(.wrongBot)
        case .failure: return .rejected(.malformedCommand)
        }
    }
}
