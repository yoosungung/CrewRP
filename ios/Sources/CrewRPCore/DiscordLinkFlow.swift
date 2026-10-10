import Foundation

public struct DiscordAuthConfig: Sendable, Equatable {
    public var clientID: String
    public var redirectURI: String
    public var authBridgeBaseURL: URL

    public init(
        clientID: String,
        redirectURI: String? = nil,
        authBridgeBaseURL: URL
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI ?? DiscordOAuth.mobileRedirectURI(clientID: clientID)
        self.authBridgeBaseURL = authBridgeBaseURL
    }
}

public final class DiscordLinkFlow: @unchecked Sendable {
    private let config: DiscordAuthConfig
    private let bridge: AuthBridgeClient
    private let cache: CacheStore
    private let pendingStore: any PendingLoginStore

    public init(
        config: DiscordAuthConfig,
        bridge: AuthBridgeClient,
        cache: CacheStore,
        pendingStore: any PendingLoginStore = InMemoryPendingLoginStore()
    ) {
        var resolved = config
        if resolved.redirectURI == "crewrp://oauth/discord" || resolved.redirectURI.isEmpty {
            resolved.redirectURI = DiscordOAuth.mobileRedirectURI(clientID: config.clientID)
        }
        self.config = resolved
        self.bridge = bridge
        self.cache = cache
        self.pendingStore = pendingStore
    }

    public func beginLink() -> LoginChallenge {
        let pkce = PKCE.generate()
        let state = PKCE.generate().verifier
        let url = DiscordOAuth.authorizeURL(
            clientID: config.clientID,
            redirectURI: config.redirectURI,
            state: state,
            codeChallenge: pkce.challenge
        )
        try? pendingStore.save(state: state, codeVerifier: pkce.verifier)
        return LoginChallenge(authorizeURL: url, state: state, codeVerifier: pkce.verifier)
    }

    public func completeLink(callbackURL: URL) async throws -> AccountLink {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var map: [String: String] = [:]
        for item in items {
            if let value = item.value {
                map[item.name] = value
            }
        }
        guard let pending = try pendingStore.load() else { throw AuthFlowError.missingPendingLogin }
        guard map["state"] == pending.state else { throw AuthFlowError.stateMismatch }
        guard let code = map["code"] else { throw AuthFlowError.missingCode }

        let identity = try await bridge.exchangeDiscord(
            code: code,
            codeVerifier: pending.codeVerifier,
            redirectURI: config.redirectURI
        )
        try pendingStore.clear()
        let link = AccountLink(
            provider: AccountLink.discordProvider,
            userId: identity.id,
            username: identity.username
        )
        try cache.putAccountLink(link)
        return link
    }

    public func linkedDiscord() throws -> AccountLink? {
        try cache.accountLink(provider: AccountLink.discordProvider)
    }

    public func unlink() throws {
        try pendingStore.clear()
        try cache.clearAccountLink(provider: AccountLink.discordProvider)
    }
}
