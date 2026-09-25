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
    case noRegistrableRepos
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

    /// Exchanges the OAuth code and returns private repos the user can register as a crew.
    public func completeLogin(callbackURL: URL) async throws -> [CrewRepo] {
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

        let repos = try await membership.listRegistrableRepos(token: token.accessToken)
        guard !repos.isEmpty else { throw AuthFlowError.noRegistrableRepos }
        return repos
    }

    public func registerCrew(_ repo: CrewRepo) async throws -> Session {
        guard let token = try tokens.loadAccessToken() else { throw AuthFlowError.missingCode }
        let role = try await membership.resolveRole(owner: repo.owner, token: token, isRepoAdmin: true)
        let session = Session(org: repo.owner, repo: repo.fullName, teamRole: role)
        try cache.putSession(session)
        return session
    }
}
