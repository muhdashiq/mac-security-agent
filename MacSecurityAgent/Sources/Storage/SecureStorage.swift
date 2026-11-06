import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum SecureStorageError: Error, Sendable, Equatable, LocalizedError {
    case keychain(status: Int32)
    case unexpectedData
    case fileOperationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status): return "Keychain error \(status)"
        case .unexpectedData: return "Unexpected data in secure storage"
        case .fileOperationFailed(let detail): return "File operation failed: \(detail)"
        }
    }
}

/// Storage for small secrets (bot token, media encryption key).
/// Production uses `KeychainManager`; tests use `InMemorySecureStorage`.
public protocol SecureStorage: Sendable {
    func readData(forKey key: String) throws -> Data?
    func writeData(_ data: Data, forKey key: String) throws
    func deleteData(forKey key: String) throws
}

public final class InMemorySecureStorage: SecureStorage {
    private let values = LockedValue<[String: Data]>([:])

    public init() {}

    public func readData(forKey key: String) throws -> Data? {
        values.withLock { $0[key] }
    }

    public func writeData(_ data: Data, forKey key: String) throws {
        values.withLock { $0[key] = data }
    }

    public func deleteData(forKey key: String) throws {
        values.withLock { $0[key] = nil }
    }
}

/// File helpers that enforce owner-only permissions.
public enum SecureFiles {
    public static let directoryPermissions: Int = 0o700
    public static let filePermissions: Int = 0o600

    /// Creates (or tightens) a directory readable only by the current user and
    /// excludes it from Time Machine backups.
    public static func createPrivateDirectory(at url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryPermissions]
        )
        try manager.setAttributes([.posixPermissions: directoryPermissions], ofItemAtPath: url.path)
        #if os(macOS)
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
        #endif
    }

    /// Atomically writes `data` to `url` with 0600 permissions.
    public static func writePrivateFile(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let manager = FileManager.default
        guard manager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: filePermissions]
        ) else {
            throw SecureStorageError.fileOperationFailed("create \(url.lastPathComponent)")
        }
        try? manager.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: temporary.path)
        if rename(temporary.path, url.path) != 0 {
            try? manager.removeItem(at: temporary)
            throw SecureStorageError.fileOperationFailed("rename \(url.lastPathComponent)")
        }
    }

    /// Best-effort secure deletion: overwrites the file with zeros before
    /// unlinking. On APFS (copy-on-write, SSD wear levelling) overwriting does
    /// not guarantee the old blocks are gone, which is why queued media is
    /// also encrypted at rest.
    public static func secureDelete(_ url: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            let chunk = Data(count: 64 * 1024)
            var written = 0
            while written < size {
                let count = min(chunk.count, size - written)
                handle.write(chunk.prefix(count))
                written += count
            }
            try? handle.synchronize()
            try? handle.close()
        }
        try? manager.removeItem(at: url)
    }

    public static func permissions(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }
}
