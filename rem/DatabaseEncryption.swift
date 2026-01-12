//
//  DatabaseEncryption.swift
//  Punk Records
//
//  Database encryption support using Keychain for key storage
//

import Foundation
import Security
import os

// MARK: - Database Encryption Manager

/// Manages encryption keys for the database
/// Uses macOS Keychain for secure key storage
final class DatabaseEncryptionManager {
    static let shared = DatabaseEncryptionManager()

    private let logger = RemLogger.shared.database
    private let serviceName = "punk.records"
    private let accountName = "database-encryption-key"

    // Key length for AES-256
    private let keyLength = 32

    private init() {}

    // MARK: - Keychain Operations

    /// Get or create the database encryption key
    func getOrCreateEncryptionKey() -> String? {
        // Try to retrieve existing key
        if let existingKey = retrieveKeyFromKeychain() {
            logger.info("Retrieved existing database encryption key from Keychain")
            return existingKey
        }

        // Generate new key
        guard let newKey = generateSecureKey() else {
            logger.error("Failed to generate encryption key")
            return nil
        }

        // Store in Keychain
        if storeKeyInKeychain(newKey) {
            logger.info("Generated and stored new database encryption key")
            return newKey
        }

        logger.error("Failed to store encryption key in Keychain")
        return nil
    }

    /// Generate a cryptographically secure key
    private func generateSecureKey() -> String? {
        var keyData = Data(count: keyLength)
        let result = keyData.withUnsafeMutableBytes { pointer in
            SecRandomCopyBytes(kSecRandomDefault, keyLength, pointer.baseAddress!)
        }

        guard result == errSecSuccess else {
            logger.error("SecRandomCopyBytes failed with status: \(result)")
            return nil
        }

        // Convert to hex string for SQLCipher
        return keyData.map { String(format: "%02x", $0) }.joined()
    }

    /// Store key in macOS Keychain
    private func storeKeyInKeychain(_ key: String) -> Bool {
        guard let keyData = key.data(using: .utf8) else {
            return false
        }

        // Delete any existing key first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new key
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrDescription as String: "Rem database encryption key"
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Keychain add failed with status: \(status)")
        }
        return status == errSecSuccess
    }

    /// Retrieve key from macOS Keychain
    private func retrieveKeyFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let keyData = item as? Data,
              let key = String(data: keyData, encoding: .utf8) else {
            if status != errSecItemNotFound {
                logger.warning("Keychain retrieval failed with status: \(status)")
            }
            return nil
        }

        return key
    }

    /// Delete the encryption key (use with caution - data will become inaccessible)
    func deleteEncryptionKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            logger.info("Encryption key deleted from Keychain")
            return true
        }

        logger.error("Failed to delete encryption key: \(status)")
        return false
    }

    // MARK: - SQLCipher Integration

    /// Check if SQLCipher is available
    /// Note: Requires SQLCipher to be compiled with SQLite.swift
    var isSQLCipherAvailable: Bool {
        // SQLCipher availability would be checked here
        // For now, return false as SQLCipher requires special build configuration
        return false
    }

    /// Get the PRAGMA statements for SQLCipher encryption
    /// These should be executed immediately after opening the database connection
    func getEncryptionPragmas() -> [String] {
        guard let key = getOrCreateEncryptionKey() else {
            return []
        }

        return [
            "PRAGMA key = 'x\"\(key)\"';",
            "PRAGMA cipher_page_size = 4096;",
            "PRAGMA kdf_iter = 256000;",
            "PRAGMA cipher_hmac_algorithm = HMAC_SHA512;",
            "PRAGMA cipher_kdf_algorithm = PBKDF2_HMAC_SHA512;"
        ]
    }
}

// MARK: - Encrypted Data Wrapper

/// Wrapper for encrypting individual data fields when full DB encryption isn't available
struct EncryptedDataWrapper {
    private let logger = RemLogger.shared.database

    /// Simple XOR-based obfuscation for sensitive strings
    /// Note: This is NOT cryptographically secure - use only as defense in depth
    /// For real security, enable SQLCipher or FileVault
    func obfuscate(_ text: String, key: String) -> String {
        let textBytes = Array(text.utf8)
        let keyBytes = Array(key.utf8)

        var result = [UInt8]()
        for (index, byte) in textBytes.enumerated() {
            result.append(byte ^ keyBytes[index % keyBytes.count])
        }

        return Data(result).base64EncodedString()
    }

    /// Reverse obfuscation
    func deobfuscate(_ encoded: String, key: String) -> String? {
        guard let data = Data(base64Encoded: encoded) else {
            return nil
        }

        let encodedBytes = Array(data)
        let keyBytes = Array(key.utf8)

        var result = [UInt8]()
        for (index, byte) in encodedBytes.enumerated() {
            result.append(byte ^ keyBytes[index % keyBytes.count])
        }

        return String(bytes: result, encoding: .utf8)
    }
}

// MARK: - Security Recommendations

/*
 DATABASE ENCRYPTION RECOMMENDATIONS
 ===================================

 For production deployment, we recommend the following security measures:

 1. ENABLE FILEVAULT
    - System Preferences → Security & Privacy → FileVault
    - This encrypts the entire disk, protecting all data at rest
    - Most important security measure for a local-first app

 2. USE SQLCIPHER (Optional, for additional protection)
    - Replace SQLite.swift with SQLCipher-enabled version
    - Add to Podfile: pod 'SQLCipher', '~> 4.5'
    - Compile with: SQLITE_HAS_CODEC=1
    - The DatabaseEncryptionManager will automatically use it

 3. DATA RETENTION
    - Videos are auto-deleted after 1 hour
    - Consider implementing OCR data retention limits
    - Provide users with easy data purge options

 4. KEYCHAIN USAGE
    - Encryption keys are stored in macOS Keychain
    - Keys are tied to this device (kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    - Keys are not included in iCloud Keychain sync

 5. SENSITIVE CONTENT FILTERING
    - Already implemented via SensitiveContentFilter
    - Filters passwords, API keys, credit cards, SSNs from clipboard

 ENABLING SQLCIPHER
 ==================

 To enable SQLCipher encryption:

 1. Add SQLCipher dependency:
    - Via CocoaPods: pod 'SQLCipher', '~> 4.5'
    - Via Swift Package Manager: Add SQLCipher package

 2. Update DatabaseManager.init() to execute encryption pragmas:
    ```swift
    if DatabaseEncryptionManager.shared.isSQLCipherAvailable {
        for pragma in DatabaseEncryptionManager.shared.getEncryptionPragmas() {
            try db.run(pragma)
        }
    }
    ```

 3. Migrate existing unencrypted database:
    ```swift
    // Export existing data
    // Create new encrypted database
    // Import data
    // Delete old unencrypted database
    ```
*/
