import XCTest
@testable import MacSecurityCore

final class TelegramAuthenticatorTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var authenticator: TelegramAuthenticator {
        TelegramAuthenticator(authorizedUserID: ownerID, botUsername: "HomeGuardBot")
    }

    func testOwnerCommandsAreAuthorized() {
        XCTAssertEqual(authenticator.evaluate(makeUpdate(id: 1, text: "/status", date: now), now: now), .authorized(.status))
        XCTAssertEqual(authenticator.evaluate(makeUpdate(id: 2, text: "/events", date: now), now: now), .authorized(.events))
        XCTAssertEqual(authenticator.evaluate(makeUpdate(id: 3, text: "/help", date: now), now: now), .authorized(.help))
        XCTAssertEqual(authenticator.evaluate(makeUpdate(id: 4, text: " /STATUS@homeguardbot ", date: now), now: now), .authorized(.status))
    }

    func testUnknownUserIsRejected() {
        let update = makeUpdate(id: 1, text: "/status", from: 999, date: now)
        XCTAssertEqual(authenticator.evaluate(update, now: now), .rejected(.unknownSender(userID: 999)))
    }

    func testMissingSenderIsRejected() {
        let update = TelegramUpdate(updateId: 1, message: TelegramMessage(
            messageId: 1, from: nil, chat: TelegramChat(id: ownerID, type: "private"),
            date: Int(now.timeIntervalSince1970), text: "/status"
        ))
        XCTAssertEqual(authenticator.evaluate(update, now: now), .rejected(.unknownSender(userID: nil)))
    }

    func testOwnerInGroupChatIsRejected() {
        let update = makeUpdate(id: 1, text: "/status", chatID: -100_200, chatType: "group", date: now)
        XCTAssertEqual(authenticator.evaluate(update, now: now), .rejected(.nonPrivateChat))
    }

    func testChatMismatchIsRejected() {
        let update = makeUpdate(id: 1, text: "/status", chatID: 555, date: now)
        XCTAssertEqual(authenticator.evaluate(update, now: now), .rejected(.chatMismatch))
    }

    func testBotSenderIsRejected() {
        let update = makeUpdate(id: 1, text: "/status", isBot: true, date: now)
        XCTAssertEqual(authenticator.evaluate(update, now: now), .rejected(.botSender))
    }

    func testForwardedCommandIsRejected() {
        let update = TelegramUpdate(updateId: 1, message: TelegramMessage(
            messageId: 1, from: TelegramUser(id: ownerID, isBot: false), chat: TelegramChat(id: ownerID, type: "private"),
            date: Int(now.timeIntervalSince1970), text: "/status", forwardOrigin: TelegramForwardOrigin(type: "user")
        ))
        XCTAssertEqual(authenticator.evaluate(update, now: now), .rejected(.forwarded))
    }

    func testStaleCommandIsRejected() {
        let update = makeUpdate(id: 1, text: "/status", date: now.addingTimeInterval(-301))
        XCTAssertEqual(authenticator.evaluate(update, now: now), .rejected(.staleMessage))
    }

    func testNotConfiguredRejectsEverything() {
        let auth = TelegramAuthenticator(authorizedUserID: nil)
        XCTAssertEqual(auth.evaluate(makeUpdate(id: 1, text: "/status", date: now), now: now), .rejected(.notConfigured))
    }

    func testMalformedCommandsAreRejected() {
        for text in ["status", "/status now", "/", "/" + String(repeating: "a", count: 70), "/stat$us", "/status\n/events", "/ status"] {
            XCTAssertEqual(authenticator.evaluate(makeUpdate(id: 1, text: text, date: now), now: now), .rejected(.malformedCommand), text)
        }
    }

    func testCommandForAnotherBotIsRejected() {
        XCTAssertEqual(authenticator.evaluate(makeUpdate(id: 1, text: "/status@OtherBot", date: now), now: now), .rejected(.wrongBot))
    }

    func testRemoteArmingIsRecognisedButNotACapability() {
        XCTAssertEqual(authenticator.evaluate(makeUpdate(id: 1, text: "/arm", date: now), now: now), .authorized(.remoteControlRequest("arm")))
        XCTAssertEqual(authenticator.evaluate(makeUpdate(id: 1, text: "/unknowncmd", date: now), now: now), .authorized(.unrecognized("unknowncmd")))
    }

    func testAuthorizationServiceDelegatesToAuthenticator() async {
        let service = await AuthorizationService()
        let decision = service.authorizeTelegramUpdate(
            makeUpdate(id: 1, text: "/status", from: 1, date: now), ownerUserID: ownerID, botUsername: nil, now: now
        )
        XCTAssertEqual(decision, .rejected(.unknownSender(userID: 1)))
    }

    @MainActor
    func testLocalActivationRequestsAreSingleUseAndShortLived() async {
        let clock = TestClock()
        let service = AuthorizationService(now: clock.nowProvider)
        let request = service.makeLocalActivationRequest(origin: .menuBar)
        XCTAssertTrue(service.consume(request))
        XCTAssertFalse(service.consume(request), "A request must not be replayable")

        let stale = service.makeLocalActivationRequest(origin: .menuBar)
        clock.advance(AuthorizationService.requestLifetime + 1)
        XCTAssertFalse(service.consume(stale))
    }
}
