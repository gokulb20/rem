//
//  Logger.swift
//  Punk Records
//
//  Production-ready logging infrastructure
//

import Foundation
import os

// MARK: - Centralized Logger

/// Centralized logging infrastructure for Punk Records
/// Uses Apple's unified logging system (os.Logger) with consistent formatting
final class RemLogger {
    static let shared = RemLogger()

    // Subsystem for all Punk Records logs
    private let subsystem = Bundle.main.bundleIdentifier ?? "punk.records"

    // Category-specific loggers
    private(set) lazy var database = Logger(subsystem: subsystem, category: "Database")
    private(set) lazy var ocr = Logger(subsystem: subsystem, category: "OCR")
    private(set) lazy var export = Logger(subsystem: subsystem, category: "Export")
    private(set) lazy var capture = Logger(subsystem: subsystem, category: "Capture")
    private(set) lazy var ffmpeg = Logger(subsystem: subsystem, category: "FFmpeg")
    private(set) lazy var clipboard = Logger(subsystem: subsystem, category: "Clipboard")
    private(set) lazy var ui = Logger(subsystem: subsystem, category: "UI")
    private(set) lazy var general = Logger(subsystem: subsystem, category: "General")

    private init() {}

    /// Log an error with context
    func logError(_ error: Error, context: String, logger: Logger? = nil) {
        let log = logger ?? general
        log.error("[\(context)] Error: \(error.localizedDescription, privacy: .public)")
    }

    /// Log a warning
    func logWarning(_ message: String, context: String, logger: Logger? = nil) {
        let log = logger ?? general
        log.warning("[\(context)] \(message, privacy: .public)")
    }

    /// Log info
    func logInfo(_ message: String, context: String, logger: Logger? = nil) {
        let log = logger ?? general
        log.info("[\(context)] \(message, privacy: .public)")
    }

    /// Log debug info (only visible in debug builds)
    func logDebug(_ message: String, context: String, logger: Logger? = nil) {
        let log = logger ?? general
        log.debug("[\(context)] \(message, privacy: .public)")
    }
}

// MARK: - Error Types

/// Rem-specific error types for better error handling
enum RemError: LocalizedError {
    case databaseError(String)
    case exportError(String)
    case captureError(String)
    case fileSystemError(String)
    case ocrError(String)
    case ffmpegError(String)
    case configurationError(String)

    var errorDescription: String? {
        switch self {
        case .databaseError(let message):
            return "Database error: \(message)"
        case .exportError(let message):
            return "Export error: \(message)"
        case .captureError(let message):
            return "Capture error: \(message)"
        case .fileSystemError(let message):
            return "File system error: \(message)"
        case .ocrError(let message):
            return "OCR error: \(message)"
        case .ffmpegError(let message):
            return "FFmpeg error: \(message)"
        case .configurationError(let message):
            return "Configuration error: \(message)"
        }
    }
}

// MARK: - Result Extensions

extension Result {
    /// Log failure and return nil, or return success value
    func logFailure(context: String, logger: Logger? = nil) -> Success? {
        switch self {
        case .success(let value):
            return value
        case .failure(let error):
            RemLogger.shared.logError(error, context: context, logger: logger)
            return nil
        }
    }
}

// MARK: - Safe File Operations

/// Safe file operations with proper error handling and logging
struct SafeFileManager {
    static let shared = SafeFileManager()
    private let fileManager = FileManager.default
    private let logger = RemLogger.shared.export

    private init() {}

    /// Create directory with proper error handling
    @discardableResult
    func createDirectory(at url: URL, withIntermediateDirectories: Bool = true) -> Bool {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
            return true
        } catch {
            RemLogger.shared.logError(error, context: "createDirectory:\(url.path)", logger: logger)
            return false
        }
    }

    /// Write data to file with proper error handling
    @discardableResult
    func write(data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url)
            logger.info("Successfully wrote \(data.count) bytes to \(url.lastPathComponent, privacy: .public)")
            return true
        } catch {
            RemLogger.shared.logError(error, context: "writeData:\(url.path)", logger: logger)
            return false
        }
    }

    /// Remove item with proper error handling
    @discardableResult
    func removeItem(at url: URL) -> Bool {
        do {
            try fileManager.removeItem(at: url)
            logger.info("Removed: \(url.lastPathComponent, privacy: .public)")
            return true
        } catch {
            RemLogger.shared.logError(error, context: "removeItem:\(url.path)", logger: logger)
            return false
        }
    }

    /// Get file attributes safely
    func attributes(at path: String) -> [FileAttributeKey: Any]? {
        do {
            return try fileManager.attributesOfItem(atPath: path)
        } catch {
            RemLogger.shared.logError(error, context: "getAttributes:\(path)", logger: logger)
            return nil
        }
    }

    /// List directory contents safely
    func contentsOfDirectory(at url: URL) -> [URL]? {
        do {
            return try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        } catch {
            RemLogger.shared.logError(error, context: "contentsOfDirectory:\(url.path)", logger: logger)
            return nil
        }
    }
}

// MARK: - Sensitive Content Filter

/// Filters sensitive content from text before storage
struct SensitiveContentFilter {
    static let shared = SensitiveContentFilter()

    // Pre-compiled regex patterns for performance
    private let passwordPattern: NSRegularExpression?
    private let apiKeyPattern: NSRegularExpression?
    private let creditCardPattern: NSRegularExpression?
    private let ssnPattern: NSRegularExpression?
    private let jwtPattern: NSRegularExpression?
    private let awsKeyPattern: NSRegularExpression?

    private let logger = RemLogger.shared.clipboard

    private init() {
        // Compile patterns once at initialization
        passwordPattern = try? NSRegularExpression(
            pattern: #"(?i)(password|passwd|pwd|secret|api[_-]?key|private[_-]?key|auth[_-]?token)\s*[=:]\s*\S+"#,
            options: []
        )

        apiKeyPattern = try? NSRegularExpression(
            pattern: #"(?i)(sk-[a-zA-Z0-9]{20,}|api[_-]?key[_-]?[a-zA-Z0-9]{16,})"#,
            options: []
        )

        creditCardPattern = try? NSRegularExpression(
            pattern: #"\b(?:\d{4}[- ]?){3}\d{4}\b"#,
            options: []
        )

        ssnPattern = try? NSRegularExpression(
            pattern: #"\b\d{3}[- ]\d{2}[- ]\d{4}\b"#,
            options: []
        )

        jwtPattern = try? NSRegularExpression(
            pattern: #"eyJ[a-zA-Z0-9_-]*\.eyJ[a-zA-Z0-9_-]*\.[a-zA-Z0-9_-]*"#,
            options: []
        )

        awsKeyPattern = try? NSRegularExpression(
            pattern: #"AKIA[0-9A-Z]{16}"#,
            options: []
        )
    }

    /// Check if text contains sensitive content
    func containsSensitiveContent(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)

        // Check each pattern
        if let pattern = passwordPattern, pattern.firstMatch(in: text, range: range) != nil {
            logger.warning("Detected password-like pattern in content")
            return true
        }

        if let pattern = apiKeyPattern, pattern.firstMatch(in: text, range: range) != nil {
            logger.warning("Detected API key pattern in content")
            return true
        }

        if let pattern = creditCardPattern, pattern.firstMatch(in: text, range: range) != nil {
            logger.warning("Detected credit card pattern in content")
            return true
        }

        if let pattern = ssnPattern, pattern.firstMatch(in: text, range: range) != nil {
            logger.warning("Detected SSN pattern in content")
            return true
        }

        if let pattern = jwtPattern, pattern.firstMatch(in: text, range: range) != nil {
            logger.warning("Detected JWT token in content")
            return true
        }

        if let pattern = awsKeyPattern, pattern.firstMatch(in: text, range: range) != nil {
            logger.warning("Detected AWS key in content")
            return true
        }

        return false
    }

    /// Redact sensitive content from text
    func redactSensitiveContent(_ text: String) -> String {
        var result = text
        let range = NSRange(text.startIndex..., in: text)

        // Redact each pattern type
        let patterns: [(NSRegularExpression?, String)] = [
            (passwordPattern, "[REDACTED:PASSWORD]"),
            (apiKeyPattern, "[REDACTED:API_KEY]"),
            (creditCardPattern, "[REDACTED:CARD]"),
            (ssnPattern, "[REDACTED:SSN]"),
            (jwtPattern, "[REDACTED:TOKEN]"),
            (awsKeyPattern, "[REDACTED:AWS_KEY]")
        ]

        for (pattern, replacement) in patterns {
            if let regex = pattern {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: replacement
                )
            }
        }

        return result
    }

    /// Filter clipboard text - returns nil if text should not be saved
    func filterClipboardText(_ text: String) -> String? {
        // If it's mostly sensitive content, don't save at all
        if containsSensitiveContent(text) && text.count < 200 {
            logger.info("Skipping clipboard save: sensitive content detected")
            return nil
        }

        // For longer text, redact sensitive parts
        if containsSensitiveContent(text) {
            logger.info("Redacting sensitive content from clipboard")
            return redactSensitiveContent(text)
        }

        return text
    }
}
