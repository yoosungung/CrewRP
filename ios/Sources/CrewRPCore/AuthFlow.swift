import Foundation

public struct AuthConfig: Sendable, Equatable {
    public var clientID: String
    public var redirectURI: String
    public var authBridgeBaseURL: URL

    public init(
        clientID: String,
        redirectURI: String,
        authBridgeBaseURL: URL
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.authBridgeBaseURL = authBridgeBaseURL
    }
}

public struct LoginChallenge: Sendable, Equatable {
    public let authorizeURL: URL
    public let state: String
    public let codeVerifier: String
}

public enum AuthFlowError: Error, Equatable {
    case stateMismatch
    case missingCode
    case missingPendingLogin
}

public protocol PendingLoginStore: AnyObject {
    func save(state: String, codeVerifier: String) throws
    func load() throws -> (state: String, codeVerifier: String)?
    func clear() throws
}

public final class InMemoryPendingLoginStore: PendingLoginStore, @unchecked Sendable {
    private var pending: (state: String, codeVerifier: String)?

    public init() {}

    public func save(state: String, codeVerifier: String) {
        pending = (state, codeVerifier)
    }

    public func load() -> (state: String, codeVerifier: String)? { pending }

    public func clear() { pending = nil }
}

public final class AuthFlow: @unchecked Sendable {
    private let config: AuthConfig
    private let bridge: AuthBridgeClient
    private let membership: GitHubMembershipClient
    private let tokens: any TokenStore
    private let cache: CacheStore
    private let pendingStore: any PendingLoginStore

    public init(
        config: AuthConfig,
        bridge: AuthBridgeClient,
        membership: GitHubMembershipClient,
        tokens: any TokenStore,
        cache: CacheStore,
        pendingStore: any PendingLoginStore = InMemoryPendingLoginStore()
    ) {
        self.config = config
        self.bridge = bridge
        self.membership = membership
        self.tokens = tokens
        self.cache = cache
        self.pendingStore = pendingStore
    }

    public func beginLogin() -> LoginChallenge {
        let pkce = PKCE.generate()
        let state = PKCE.generate().verifier
        let url = GitHubOAuth.authorizeURL(
            clientID: config.clientID,
            redirectURI: config.redirectURI,
            state: state,
            codeChallenge: pkce.challenge
        )
        try? pendingStore.save(state: state, codeVerifier: pkce.verifier)
        return LoginChallenge(authorizeURL: url, state: state, codeVerifier: pkce.verifier)
    }

    /// Exchanges the OAuth code and returns private repos the user can register as a crew.
    public func completeLogin(callbackURL: URL) async throws -> [CrewRepo] {
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

        let token = try await bridge.exchange(
            code: code,
            codeVerifier: pending.codeVerifier,
            redirectURI: config.redirectURI
        )
        try tokens.saveAccessToken(token.accessToken)
        try pendingStore.clear()
        return try await membership.listRegistrableRepos(token: token.accessToken)
    }

    public func registerCrew(_ repo: CrewRepo) async throws -> Session {
        guard let token = try tokens.loadAccessToken() else { throw AuthFlowError.missingCode }
        let role = try await membership.resolveRole(owner: repo.owner, token: token, isRepoAdmin: true)
        let session = Session(org: repo.owner, repo: repo.fullName, teamRole: role)
        try cache.putSession(session)
        return session
    }

    public func logout() throws {
        try tokens.clearAccessToken()
        try pendingStore.clear()
        try cache.clearSession()
    }
}
