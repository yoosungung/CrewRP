import Foundation
import Security

public protocol TokenStore: Sendable {
    func saveAccessToken(_ token: String) throws
    func loadAccessToken() throws -> String?
    func clearAccessToken() throws
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private var token: String?

    public init() {}

    public func saveAccessToken(_ token: String) throws {
        self.token = token
    }

    public func loadAccessToken() throws -> String? {
        token
    }

    public func clearAccessToken() throws {
        token = nil
    }
}

public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "app.crewrp.token", account: String = "access_token") {
        self.service = service
        self.account = account
    }

    public func saveAccessToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw TokenStoreError.saveFailed(status) }
    }

    public func loadAccessToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw TokenStoreError.loadFailed(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func clearAccessToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.clearFailed(status)
        }
    }
}

public enum TokenStoreError: Error {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case clearFailed(OSStatus)
}
