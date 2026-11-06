import Foundation
#if canImport(os)
import os
#endif

/// Removes secrets from strings before they are written to any log.
///
/// The application never logs tokens on purpose; this is a second line of
/// defence for strings that come from third parties (error descriptions,
/// URLs inside `URLError` user-info, Telegram error descriptions, ...).
public enum LogSanitizer {
    private static let rules: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            // Telegram bot token: <bot id>:<35 char secret>
            (#"\b\d{5,16}:[A-Za-z0-9_-]{30,64}\b"#, "[REDACTED-TOKEN]"),
            // Bot API URL path segment.
            (#"/bot[^/\s]+"#, "/bot[REDACTED]"),
            // Bearer tokens (before key=value so "Authorization: Bearer x" is covered).
            (#"(?i)bearer\s+[A-Za-z0-9._~+/-]+=*"#, "Bearer [REDACTED]"),
            // key=value style secrets.
            (#"(?i)\b(token|secret|password|passwd|api[_-]?key|authorization)\s*[=:]\s*(?!Bearer \[REDACTED\])[^\s&,;]+"#, "$1=[REDACTED]"),
        ]
        return patterns.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, template)
        }
    }()

    /// Maximum length of a single log message. Long blobs (for example a raw
    /// HTTP body) are truncated so that media can never end up in a log.
    public static let maximumLength = 512

    public static func sanitize(_ message: String) -> String {
        var result = message
        for (regex, template) in rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        // Strip control characters (log injection) except tab.
        result = String(result.unicodeScalars.map { scalar -> Character in
            if scalar == "\t" { return " " }
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            return Character(scalar)
        })
        if result.count > maximumLength {
            result = String(result.prefix(maximumLength)) + "…[truncated]"
        }
        return result
    }
}

/// Thin wrapper around `os.Logger` that always sanitises messages.
///
/// Messages are marked `.public` *after* sanitising so that diagnostics remain
/// useful in Console.app; callers must still never pass private media or
/// credentials (and the sanitiser removes anything that looks like one).
public struct AppLogger: Sendable {
    public static let subsystem = "com.macsecurityagent.app"

    public let category: String
    #if canImport(os)
    private let logger: Logger
    #endif

    public init(category: String) {
        self.category = category
        #if canImport(os)
        self.logger = Logger(subsystem: Self.subsystem, category: category)
        #endif
    }

    public func debug(_ message: @autoclosure () -> String) {
        emit(level: "DEBUG", message())
    }

    public func info(_ message: @autoclosure () -> String) {
        emit(level: "INFO", message())
    }

    public func warning(_ message: @autoclosure () -> String) {
        emit(level: "WARN", message())
    }

    public func error(_ message: @autoclosure () -> String) {
        emit(level: "ERROR", message())
    }

    private func emit(level: String, _ raw: String) {
        let message = LogSanitizer.sanitize(raw)
        #if canImport(os)
        switch level {
        case "DEBUG": logger.debug("\(message, privacy: .public)")
        case "INFO": logger.info("\(message, privacy: .public)")
        case "WARN": logger.warning("\(message, privacy: .public)")
        default: logger.error("\(message, privacy: .public)")
        }
        #else
        if ProcessInfo.processInfo.environment["MSA_LOG_STDERR"] != nil {
            FileHandle.standardError.write(Data("[\(level)] [\(category)] \(message)\n".utf8))
        }
        #endif
    }
}
