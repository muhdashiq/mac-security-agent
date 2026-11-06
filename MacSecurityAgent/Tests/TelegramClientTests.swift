import XCTest
@testable import MacSecurityCore

final class TelegramClientTests: XCTestCase {
    private let tokenString = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawA"

    private func makeClient() -> (TelegramClient, MockTransport) {
        let transport = MockTransport()
        return (TelegramClient(token: BotToken(tokenString)!, transport: transport), transport)
    }

    func testTokenValidation() {
        XCTAssertNotNil(BotToken(tokenString))
        XCTAssertNotNil(BotToken("  \(tokenString)\n"))
        XCTAssertNil(BotToken("not-a-token"))
        XCTAssertNil(BotToken("123:short"))
        XCTAssertNil(BotToken("12345678:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawA/../x"))
    }

    func testTokenIsNeverPrinted() {
        let token = BotToken(tokenString)!
        XCTAssertFalse(String(describing: token).contains("AAHdq"))
        XCTAssertFalse(String(reflecting: token).contains("AAHdq"))
        XCTAssertFalse("\(token)".contains("AAHdq"))
        var dumped = ""
        dump(token, to: &dumped)
        XCTAssertFalse(dumped.contains("AAHdq"))
        XCTAssertEqual(token.botID, "123456789")
    }

    func testSendMessageUsesHTTPSJSONAndParsesResult() async throws {
        let (client, transport) = makeClient()
        transport.enqueue(json: #"{"ok":true,"result":{"message_id":77,"chat":{"id":5,"type":"private"},"date":1,"text":"hi"}}"#)
        let message = try await client.sendMessage(chatID: 5, text: "hi")
        XCTAssertEqual(message.messageId, 77)
        let request = try XCTUnwrap(transport.received.first)
        XCTAssertEqual(request.url.scheme, "https")
        XCTAssertEqual(request.url.host, "api.telegram.org")
        XCTAssertTrue(request.url.path.hasSuffix("/sendMessage"))
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any]
        XCTAssertEqual(body?["chat_id"] as? Int, 5)
        XCTAssertEqual(body?["text"] as? String, "hi")
        XCTAssertNil(body?["parse_mode"], "Plain text only – no formatting injection")
    }

    func testSendPhotoBuildsMultipartBody() async throws {
        let (client, transport) = makeClient()
        transport.enqueue(json: #"{"ok":true,"result":{"message_id":1,"chat":{"id":5,"type":"private"},"date":1}}"#)
        _ = try await client.sendPhoto(chatID: 5, jpegData: Data([0xFF, 0xD8, 0xFF]), caption: "Snapshot")
        let request = try XCTUnwrap(transport.received.first)
        let contentType = try XCTUnwrap(request.headers["Content-Type"])
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"chat_id\"\r\n\r\n5\r\n"))
        XCTAssertTrue(body.contains("name=\"caption\"\r\n\r\nSnapshot\r\n"))
        XCTAssertTrue(body.contains("name=\"photo\"; filename=\"snapshot.jpg\"\r\nContent-Type: image/jpeg"))
        let boundary = contentType.components(separatedBy: "boundary=").last!
        XCTAssertTrue(body.hasSuffix("--\(boundary)--\r\n"))
    }

    func testSendVideoIncludesMetadata() async throws {
        let (client, transport) = makeClient()
        transport.enqueue(json: #"{"ok":true,"result":{"message_id":1,"chat":{"id":5,"type":"private"},"date":1}}"#)
        _ = try await client.sendVideo(chatID: 5, mp4Data: Data(count: 10), caption: nil, durationSeconds: 30, width: 1280, height: 720)
        let body = String(decoding: try XCTUnwrap(transport.received.first?.body), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"duration\"\r\n\r\n30\r\n"))
        XCTAssertTrue(body.contains("name=\"supports_streaming\"\r\n\r\ntrue\r\n"))
        XCTAssertTrue(body.contains("filename=\"recording.mp4\"\r\nContent-Type: video/mp4"))
    }

    func testOversizedVideoIsRejectedLocally() async {
        let (client, transport) = makeClient()
        do {
            _ = try await client.sendVideo(chatID: 5, mp4Data: Data(count: TelegramClient.maximumUploadBytes + 1), caption: nil, durationSeconds: nil, width: nil, height: nil)
            XCTFail("Expected failure")
        } catch let error as TelegramError {
            XCTAssertEqual(error.disposition, .permanent)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertTrue(transport.received.isEmpty)
    }

    func testAPIErrorsAreMappedWithRetryAfter() async {
        let (client, transport) = makeClient()
        transport.enqueue(status: 429, json: #"{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 17","parameters":{"retry_after":17}}"#)
        do {
            _ = try await client.sendMessage(chatID: 5, text: "x")
            XCTFail("Expected failure")
        } catch let error as TelegramError {
            XCTAssertEqual(error, .api(code: 429, description: "Too Many Requests: retry after 17", retryAfter: 17))
            XCTAssertEqual(error.disposition, .retryable(after: 17))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testErrorDispositions() {
        XCTAssertEqual(TelegramError.network(code: -1009).disposition, .retryable(after: nil))
        XCTAssertEqual(TelegramError.api(code: 401, description: "Unauthorized", retryAfter: nil).disposition, .configuration)
        XCTAssertEqual(TelegramError.api(code: 400, description: "Bad Request: chat not found", retryAfter: nil).disposition, .configuration)
        XCTAssertEqual(TelegramError.api(code: 400, description: "Bad Request: wrong file", retryAfter: nil).disposition, .permanent)
        XCTAssertEqual(TelegramError.api(code: 502, description: "Bad Gateway", retryAfter: nil).disposition, .retryable(after: nil))
        XCTAssertEqual(TelegramError.http(status: 503).disposition, .retryable(after: nil))
        XCTAssertEqual(TelegramError.http(status: 400).disposition, .permanent)
    }

    func testNonJSONResponseIsHTTPError() async {
        let (client, transport) = makeClient()
        transport.enqueue(status: 502, json: "<html>Bad gateway</html>")
        do {
            _ = try await client.getMe()
            XCTFail("Expected failure")
        } catch let error as TelegramError {
            XCTAssertEqual(error, .http(status: 502))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testGetUpdatesDecodesMessages() async throws {
        let (client, transport) = makeClient()
        transport.enqueue(json: #"""
        {"ok":true,"result":[{"update_id":10,"message":{"message_id":3,"from":{"id":123456789,"is_bot":false,"first_name":"Owner"},"chat":{"id":123456789,"type":"private"},"date":1800000000,"text":"/status"}}]}
        """#)
        let updates = try await client.getUpdates(offset: 9, timeoutSeconds: 25, limit: 20)
        XCTAssertEqual(updates.first?.updateId, 10)
        XCTAssertEqual(updates.first?.message?.from?.id, ownerID)
        XCTAssertEqual(updates.first?.message?.text, "/status")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(transport.received.first?.body)) as? [String: Any]
        XCTAssertEqual(body?["offset"] as? Int, 9)
        XCTAssertEqual(body?["timeout"] as? Int, 25)
        XCTAssertEqual(transport.received.first?.timeout ?? 0, 40, accuracy: 0.001)
    }

    func testSafeDescriptionsNeverContainToken() {
        let error = TelegramError.api(code: 404, description: "Not Found: /bot\(tokenString)/getMe", retryAfter: nil)
        XCTAssertFalse(error.safeDescription.contains("AAHdq"))
    }

    func testTransportRefusesPlainHTTP() async {
        let transport = URLSessionTransport()
        do {
            _ = try await transport.send(HTTPRequest(url: URL(string: "http://api.telegram.org/x")!))
            XCTFail("Expected failure")
        } catch let error as TelegramError {
            XCTAssertEqual(error, .insecureURL)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testCredentialStoreRoundTrip() throws {
        let storage = InMemorySecureStorage()
        let store = TelegramCredentialStore(storage: storage)
        XCTAssertNil(try store.loadToken())
        try store.saveToken(BotToken(tokenString)!)
        XCTAssertEqual(try store.loadToken(), BotToken(tokenString))
        XCTAssertTrue(store.hasToken())
        try store.deleteToken()
        XCTAssertFalse(store.hasToken())
    }
}
