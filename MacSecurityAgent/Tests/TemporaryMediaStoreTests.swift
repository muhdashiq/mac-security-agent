import XCTest
@testable import MacSecurityCore

final class TemporaryMediaStoreTests: XCTestCase {
    func testMediaIsEncryptedAtRestAndRoundTrips() async throws {
        let directory = try makeTemporaryDirectory()
        let store = try TemporaryMediaStore(rootDirectory: directory, keyProvider: MediaKeyProvider(storage: InMemorySecureStorage()))
        let plaintext = Data("JPEG secret content of my living room".utf8)
        let media = try await store.store(plaintext, kind: .snapshot)
        let fileURL = await store.encryptedFileURL(for: media)
        let onDisk = try Data(contentsOf: fileURL)
        XCTAssertNil(onDisk.range(of: Data("living room".utf8)), "Plaintext must not be on disk")
        XCTAssertEqual(onDisk.prefix(4), Data("MSA1".utf8))
        let loaded = try await store.load(media)
        XCTAssertEqual(loaded, plaintext)
    }

    func testPermissionsAreOwnerOnly() async throws {
        let directory = try makeTemporaryDirectory()
        let root = directory.appendingPathComponent("Queue")
        let store = try TemporaryMediaStore(rootDirectory: root, keyProvider: MediaKeyProvider(storage: InMemorySecureStorage()))
        let media = try await store.store(Data([1, 2, 3]), kind: .video)
        XCTAssertEqual(SecureFiles.permissions(of: root), 0o700)
        XCTAssertEqual(SecureFiles.permissions(of: store.mediaDirectory), 0o700)
        XCTAssertEqual(SecureFiles.permissions(of: store.recordingDirectory), 0o700)
        let fileURL = await store.encryptedFileURL(for: media)
        XCTAssertEqual(SecureFiles.permissions(of: fileURL), 0o600)
    }

    func testKeyIsPersistedInSecureStorage() async throws {
        let directory = try makeTemporaryDirectory()
        let storage = InMemorySecureStorage()
        let first = try TemporaryMediaStore(rootDirectory: directory, keyProvider: MediaKeyProvider(storage: storage))
        let media = try await first.store(Data("x".utf8), kind: .snapshot)
        XCTAssertEqual(try storage.readData(forKey: MediaKeyProvider.storageKey)?.count, 32)
        let second = try TemporaryMediaStore(rootDirectory: directory, keyProvider: MediaKeyProvider(storage: storage))
        let loaded = try await second.load(media)
        XCTAssertEqual(loaded, Data("x".utf8))
    }

    func testDifferentKeyCannotDecrypt() async throws {
        let directory = try makeTemporaryDirectory()
        let first = try TemporaryMediaStore(rootDirectory: directory, keyProvider: MediaKeyProvider(storage: InMemorySecureStorage()))
        let media = try await first.store(Data("x".utf8), kind: .snapshot)
        let other = try TemporaryMediaStore(rootDirectory: directory, keyProvider: MediaKeyProvider(storage: InMemorySecureStorage()))
        do {
            _ = try await other.load(media)
            XCTFail("Expected decryption failure")
        } catch {
            XCTAssertEqual(error as? MediaStoreError, .decryptionFailed)
        }
    }

    func testSwappedFilesAreDetected() async throws {
        let directory = try makeTemporaryDirectory()
        let store = try TemporaryMediaStore(rootDirectory: directory, keyProvider: MediaKeyProvider(storage: InMemorySecureStorage()))
        let a = try await store.store(Data("a".utf8), kind: .snapshot)
        let b = try await store.store(Data("b".utf8), kind: .snapshot)
        let urlA = await store.encryptedFileURL(for: a)
        let urlB = await store.encryptedFileURL(for: b)
        try FileManager.default.removeItem(at: urlA)
        try FileManager.default.copyItem(at: urlB, to: urlA)
        do {
            _ = try await store.load(a)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? MediaStoreError, .decryptionFailed)
        }
    }

    func testImportRecordingEncryptsAndDeletesPlaintext() async throws {
        let directory = try makeTemporaryDirectory()
        let store = try TemporaryMediaStore(rootDirectory: directory, keyProvider: MediaKeyProvider(storage: InMemorySecureStorage()))
        let url = try await store.makeRecordingURL(for: EventID(sequence: 9))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("EVT-00009"))
        try Data("mp4 plaintext".utf8).write(to: url)
        let media = try await store.importRecording(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(media.kind, .video)
        let loaded = try await store.load(media)
        XCTAssertEqual(loaded, Data("mp4 plaintext".utf8))
    }

    func testEmptyRecordingIsRejected() async throws {
        let directory = try makeTemporaryDirectory()
        let store = try TemporaryMediaStore(rootDirectory: directory, keyProvider: MediaKeyProvider(storage: InMemorySecureStorage()))
        let url = try await store.makeRecordingURL(for: EventID(sequence: 1))
        try Data().write(to: url)
        do {
            _ = try await store.importRecording(at: url)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? MediaStoreError, .emptyRecording)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeleteRemovesFile() async throws {
        let directory = try makeTemporaryDirectory()
        let store = try TemporaryMediaStore(rootDirectory: directory, keyProvider: MediaKeyProvider(storage: InMemorySecureStorage()))
        let media = try await store.store(Data(repeating: 7, count: 200_000), kind: .video)
        await store.delete(media)
        XCTAssertTrue(directoryContents(store.mediaDirectory).isEmpty)
        do {
            _ = try await store.load(media)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? MediaStoreError, .missingFile)
        }
    }

    func testCipherRejectsGarbage() throws {
        let cipher = try MediaCipher(keyData: MediaCipher.generateKey())
        XCTAssertThrowsError(try cipher.open(Data("nope".utf8), associatedData: Data()))
        XCTAssertThrowsError(try MediaCipher(keyData: Data(count: 16)))
    }
}
