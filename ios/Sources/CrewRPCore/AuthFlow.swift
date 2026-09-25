import Foundation

public struct AuthConfig: Sendable, Equatable {
    public var clientID: String
    public var redirectURI: String
    public var authBridgeBaseURL: URL
    public var defaultRepoName: String

    public init(
        clientID: String,
        redirectURI: String,
        authBridgeBaseURL: URL,
        defaultRepoName: String = "crew"
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.authBridgeBaseURL = authBridgeBaseURL
        self.defaultRepoName = defaultRepoName
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
    case noOrganizations
}

public final class AuthFlow: @unchecked Sendable {
    private let config: AuthConfig
    private let bridge: AuthBridgeClient
    private let membership: GitHubMembershipClient
    private let tokens: any TokenStore
    private let cache: CacheStore

    private var pending: LoginChallenge?

    public init(
        config: AuthConfig,
        bridge: AuthBridgeClient,
        membership: GitHubMembershipClient,
        tokens: any TokenStore,
        cache: CacheStore
    ) {
        self.config = config
        self.bridge = bridge
        self.membership = membership
        self.tokens = tokens
        self.cache = cache
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
        let challenge = LoginChallenge(authorizeURL: url, state: state, codeVerifier: pkce.verifier)
        pending = challenge
        return challenge
    }

    public func completeLogin(callbackURL: URL) async throws -> [Organization] {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var map: [String: String] = [:]
        for item in items {
            if let value = item.value {
                map[item.name] = value
            }
        }
        guard let pending else { throw AuthFlowError.missingCode }
        guard map["state"] == pending.state else { throw AuthFlowError.stateMismatch }
        guard let code = map["code"] else { throw AuthFlowError.missingCode }

        let token = try await bridge.exchange(
            code: code,
            codeVerifier: pending.codeVerifier,
            redirectURI: config.redirectURI
        )
        try tokens.saveAccessToken(token.accessToken)
        self.pending = nil

        let orgs = try await membership.listOrganizations(token: token.accessToken)
        guard !orgs.isEmpty else { throw AuthFlowError.noOrganizations }
        return orgs
    }

    public func selectOrganization(_ org: Organization) async throws -> Session {
        guard let token = try tokens.loadAccessToken() else { throw AuthFlowError.missingCode }
        let role = try await membership.resolveRole(org: org.login, token: token)
        let session = Session(
            org: org.login,
            repo: "\(org.login)/\(config.defaultRepoName)",
            teamRole: role
        )
        try cache.putSession(session)
        return session
    }
}
