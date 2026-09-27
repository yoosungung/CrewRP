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
    /// Fallback when Keychain returns errSecMissingEntitlement (-34018), e.g. unsigned simulator installs.
    private let fallbackKey: String

    public init(
        service: String = "app.crewrp.token",
        account: String = "access_token",
        fallbackKey: String = "crewrp.fallback.access_token"
    ) {
        self.service = service
        self.account = account
        self.fallbackKey = fallbackKey
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
        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
            return
        }
        if status == errSecMissingEntitlement {
            // Unsigned simulator builds cannot use Keychain; keep token in UserDefaults and
            // best-effort delete any stale Keychain value from an earlier signed install.
            UserDefaults.standard.set(token, forKey: fallbackKey)
            SecItemDelete(query as CFDictionary)
            return
        }
        throw TokenStoreError.saveFailed(status)
    }

    public func loadAccessToken() throws -> String? {
        // Prefer UserDefaults fallback when present — it is always from the latest login that
        // hit errSecMissingEntitlement. Stale Keychain tokens (e.g. after revoke) must not win.
        if let fallback = UserDefaults.standard.string(forKey: fallbackKey), !fallback.isEmpty {
            return fallback
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        if status == errSecItemNotFound || status == errSecMissingEntitlement {
            return nil
        }
        throw TokenStoreError.loadFailed(status)
    }

    public func clearAccessToken() throws {
        UserDefaults.standard.removeObject(forKey: fallbackKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
            throw TokenStoreError.clearFailed(status)
        }
    }
}

public enum TokenStoreError: Error {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case clearFailed(OSStatus)
}

/// Persists PKCE pending login across Safari round-trips.
/// UserDefaults (not Keychain): unsigned simulator builds hit errSecMissingEntitlement (-34018) on Keychain.
public final class UserDefaultsPendingLoginStore: PendingLoginStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let stateKey: String
    private let verifierKey: String

    public init(
        defaults: UserDefaults = .standard,
        stateKey: String = "crewrp.oauth.state",
        verifierKey: String = "crewrp.oauth.verifier"
    ) {
        self.defaults = defaults
        self.stateKey = stateKey
        self.verifierKey = verifierKey
    }

    public func save(state: String, codeVerifier: String) throws {
        defaults.set(state, forKey: stateKey)
        defaults.set(codeVerifier, forKey: verifierKey)
    }

    public func load() throws -> (state: String, codeVerifier: String)? {
        guard let state = defaults.string(forKey: stateKey),
              let verifier = defaults.string(forKey: verifierKey),
              !state.isEmpty, !verifier.isEmpty else { return nil }
        return (state, verifier)
    }

    public func clear() throws {
        defaults.removeObject(forKey: stateKey)
        defaults.removeObject(forKey: verifierKey)
    }
}
