import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum MediaKind: String, Codable, Sendable {
    case snapshot
    case video

    public var mimeType: String {
        switch self {
        case .snapshot: return "image/jpeg"
        case .video: return "video/mp4"
        }
    }

    public var fileExtension: String {
        switch self {
        case .snapshot: return "jpg"
        case .video: return "mp4"
        }
    }
}

/// Reference to an encrypted media file in the temporary store.
public struct StoredMedia: Codable, Sendable, Hashable {
    public let id: UUID
    public let kind: MediaKind
    public let byteCount: Int
    public let createdAt: Date

    public init(id: UUID = UUID(), kind: MediaKind, byteCount: Int, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.byteCount = byteCount
        self.createdAt = createdAt
    }

    var fileName: String { "\(id.uuidString).\(kind.rawValue).enc" }
}

public enum MediaStoreError: Error, Sendable, Equatable, LocalizedError {
    case invalidKey
    case invalidFormat
    case decryptionFailed
    case missingFile
    case emptyRecording

    public var errorDescription: String? {
        switch self {
        case .invalidKey: return "The media encryption key is invalid."
        case .invalidFormat: return "The media file has an unknown format."
        case .decryptionFailed: return "The media file could not be decrypted (tampered or key changed)."
        case .missingFile: return "The media file is missing."
        case .emptyRecording: return "The recording is empty."
        }
    }
}

/// AES-256-GCM encryption for media at rest. The media id is bound as
/// associated data, so swapping two encrypted files is detected.
public struct MediaCipher: Sendable {
    static let magic = Data("MSA1".utf8)
    private let keyData: Data

    public init(keyData: Data) throws {
        guard keyData.count == 32 else { throw MediaStoreError.invalidKey }
        self.keyData = keyData
    }

    public func seal(_ plaintext: Data, associatedData: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData), authenticating: associatedData)
        guard let combined = box.combined else { throw MediaStoreError.invalidFormat }
        return Self.magic + combined
    }

    public func open(_ data: Data, associatedData: Data) throws -> Data {
        guard data.count > Self.magic.count + 28, data.prefix(Self.magic.count) == Self.magic else {
            throw MediaStoreError.invalidFormat
        }
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(Self.magic.count))
            return try AES.GCM.open(box, using: SymmetricKey(data: keyData), authenticating: associatedData)
        } catch {
            throw MediaStoreError.decryptionFailed
        }
    }

    public static func generateKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

/// Loads the media key from secure storage, creating it on first use.
public struct MediaKeyProvider: Sendable {
    public static let storageKey = "media-encryption-key.v1"
    private let storage: any SecureStorage

    public init(storage: any SecureStorage) {
        self.storage = storage
    }

    public func loadOrCreateKey() throws -> Data {
        if let existing = try storage.readData(forKey: Self.storageKey), existing.count == 32 {
            return existing
        }
        let key = MediaCipher.generateKey()
        try storage.writeData(key, forKey: Self.storageKey)
        return key
    }
}

public protocol MediaStoring: Sendable {
    func store(_ data: Data, kind: MediaKind) async throws -> StoredMedia
    /// Encrypts a finished plaintext recording into the store and securely
    /// deletes the plaintext.
    func importRecording(at url: URL) async throws -> StoredMedia
    func load(_ media: StoredMedia) async throws -> Data
    func delete(_ media: StoredMedia) async
    /// Location for the in-progress (plaintext) recording of an event.
    func makeRecordingURL(for eventID: EventID) async throws -> URL
    func discardRecording(at url: URL) async
    /// Removes encrypted files not in `referenced` and any leftover plaintext
    /// recordings. Returns the number of removed files.
    func purge(keeping referenced: Set<UUID>) async -> Int
}

/// Encrypted temporary media store.
///
/// Layout (inside the sandbox container's Application Support):
///
///     Queue/Media/<uuid>.<kind>.enc   AES-GCM encrypted snapshots & videos
///     Queue/Recording/<event>.mp4     plaintext while AVAssetWriter records
///
/// Directories are 0700, files 0600, everything is excluded from backups.
/// Media is deleted as soon as Telegram confirms delivery, or after the
/// retention period (max 24 h).
public actor TemporaryMediaStore: MediaStoring {
    public nonisolated let mediaDirectory: URL
    public nonisolated let recordingDirectory: URL
    private let cipher: MediaCipher
    private let now: @Sendable () -> Date
    private let logger = AppLogger(category: "MediaStore")

    public init(
        rootDirectory: URL,
        keyProvider: MediaKeyProvider,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        mediaDirectory = rootDirectory.appendingPathComponent("Media", isDirectory: true)
        recordingDirectory = rootDirectory.appendingPathComponent("Recording", isDirectory: true)
        try SecureFiles.createPrivateDirectory(at: rootDirectory)
        try SecureFiles.createPrivateDirectory(at: mediaDirectory)
        try SecureFiles.createPrivateDirectory(at: recordingDirectory)
        cipher = try MediaCipher(keyData: keyProvider.loadOrCreateKey())
        self.now = now
    }

    public func store(_ data: Data, kind: MediaKind) async throws -> StoredMedia {
        let media = StoredMedia(kind: kind, byteCount: data.count, createdAt: now())
        let sealed = try cipher.seal(data, associatedData: Data(media.id.uuidString.utf8))
        try SecureFiles.writePrivateFile(sealed, to: url(for: media))
        return media
    }

    public func importRecording(at url: URL) async throws -> StoredMedia {
        defer { SecureFiles.secureDelete(url) }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw MediaStoreError.emptyRecording }
        return try await store(data, kind: .video)
    }

    public func load(_ media: StoredMedia) async throws -> Data {
        let fileURL = url(for: media)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw MediaStoreError.missingFile }
        let sealed = try Data(contentsOf: fileURL)
        return try cipher.open(sealed, associatedData: Data(media.id.uuidString.utf8))
    }

    public func delete(_ media: StoredMedia) async {
        // Ciphertext only: a plain unlink is sufficient once the key is
        // required to read it, but overwrite anyway (cheap, defence in depth).
        SecureFiles.secureDelete(url(for: media))
    }

    public func makeRecordingURL(for eventID: EventID) async throws -> URL {
        try SecureFiles.createPrivateDirectory(at: recordingDirectory)
        return recordingDirectory.appendingPathComponent("\(eventID.rawValue)-\(UUID().uuidString.prefix(8)).mp4")
    }

    public func discardRecording(at url: URL) async {
        SecureFiles.secureDelete(url)
    }

    public func purge(keeping referenced: Set<UUID>) async -> Int {
        let manager = FileManager.default
        var removed = 0
        let mediaFiles = (try? manager.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in mediaFiles {
            let idString = file.lastPathComponent.split(separator: ".").first.map(String.init) ?? ""
            if let id = UUID(uuidString: idString), referenced.contains(id) { continue }
            SecureFiles.secureDelete(file)
            removed += 1
        }
        let recordings = (try? manager.contentsOfDirectory(at: recordingDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in recordings {
            SecureFiles.secureDelete(file)
            removed += 1
        }
        if removed > 0 { logger.info("Purged \(removed) orphaned temporary media file(s)") }
        return removed
    }

    public func encryptedFileURL(for media: StoredMedia) -> URL {
        url(for: media)
    }

    private func url(for media: StoredMedia) -> URL {
        mediaDirectory.appendingPathComponent(media.fileName)
    }
}
