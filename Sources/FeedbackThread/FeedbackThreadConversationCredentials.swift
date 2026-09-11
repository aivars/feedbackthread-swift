import Foundation
import Security
import CryptoKit

/// Separate Keychain entry for every API/project/account scope. No credentials
/// are stored in UserDefaults or sent in WebSocket URLs.
enum FeedbackThreadConversationCredentials {
    static func account(configuration: FeedbackThreadConfiguration, scope: String) -> String {
        let identity = "\(configuration.baseURL.absoluteString)|\(configuration.projectKey)|\(scope)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func load(account: String) throws -> FeedbackThreadCustomerSession? {
        var query = base(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw credentialError(status) }
        return try JSONDecoder().decode(FeedbackThreadCustomerSession.self, from: data)
    }
    static func save(_ session: FeedbackThreadCustomerSession, account: String) throws {
        let data = try JSONEncoder().encode(session)
        let query = base(account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let inserted = SecItemAdd(attributes as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw credentialError(inserted) }
        } else if status != errSecSuccess { throw credentialError(status) }
    }
    static func remove(account: String) throws {
        let status = SecItemDelete(base(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw credentialError(status) }
    }
    private static func base(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.feedbackthread.conversations", kSecAttrAccount as String: account]
    }
    private static func credentialError(_ status: OSStatus) -> FeedbackThreadError {
        .invalidConfiguration("Could not access conversation credentials (Keychain \(status)).")
    }
}
