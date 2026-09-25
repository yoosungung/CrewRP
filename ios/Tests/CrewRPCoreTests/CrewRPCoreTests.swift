import Foundation
import Testing
@testable import CrewRPCore

@Suite("PKCE")
struct PKCETests {
    @Test("verifier is URL-safe and long enough")
    func verifierShape() {
        let pair = PKCE.generate()
        #expect(pair.verifier.count >= 43)
        #expect(pair.verifier.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
    }

    @Test("challenge is S256 of verifier")
    func challengeMatchesRFC() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.challenge(for: verifier)
        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("authorize URL includes PKCE params")
    func authorizeURL() {
        let url = GitHubOAuth.authorizeURL(
            clientID: "cid",
            redirectURI: "crewrp://oauth/callback",
            state: "st",
            codeChallenge: "chal"
        )
        #expect(url.scheme == "https")
        #expect(url.host == "github.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        #expect(map["client_id"] == "cid")
        #expect(map["redirect_uri"] == "crewrp://oauth/callback")
        #expect(map["state"] == "st")
        #expect(map["code_challenge"] == "chal")
        #expect(map["code_challenge_method"] == "S256")
        #expect(map["response_type"] == "code")
    }
}

@Suite("TeamRole")
struct TeamRoleTests {
    @Test("admins wins over members")
    func adminsWins() {
        #expect(TeamRole.resolve(slugs: ["members", "admins"]) == .admin)
        #expect(TeamRole.resolve(slugs: ["admins"]) == .admin)
    }

    @Test("members alone is member")
    func membersOnly() {
        #expect(TeamRole.resolve(slugs: ["members"]) == .member)
    }

    @Test("unknown teams are none")
    func unknown() {
        #expect(TeamRole.resolve(slugs: ["random"]) == .none)
        #expect(TeamRole.resolve(slugs: []) == .none)
    }
}

@Suite("CacheStore")
struct CacheStoreTests {
    @Test("stores and returns REST body with etag")
    func restCache() throws {
        let store = try CacheStore(path: ":memory:")
        try store.putCacheEntry(url: "https://api.github.com/user", body: #"{"login":"a"}"#, etag: "\"etag1\"")
        let entry = try store.cacheEntry(url: "https://api.github.com/user")
        #expect(entry?.body == #"{"login":"a"}"#)
        #expect(entry?.etag == "\"etag1\"")
    }

    @Test("stores GraphQL cursor")
    func graphqlCursor() throws {
        let store = try CacheStore(path: ":memory:")
        try store.putGraphQLCursor(queryName: "discussions", cursor: "c1", updatedAt: Date(timeIntervalSince1970: 100))
        let row = try store.graphQLCursor(queryName: "discussions")
        #expect(row?.cursor == "c1")
        #expect(row?.updatedAt.timeIntervalSince1970 == 100)
    }

    @Test("session excludes token")
    func session() throws {
        let store = try CacheStore(path: ":memory:")
        try store.putSession(Session(org: "crew", repo: "crew/box", teamRole: .member))
        let session = try store.session()
        #expect(session?.org == "crew")
        #expect(session?.repo == "crew/box")
        #expect(session?.teamRole == .member)
    }
}

final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    var handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { _ in
        fatalError("unset")
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await handler(request)
    }
}

@Suite("TokenStore")
struct TokenStoreTests {
    @Test("memory store round-trips token")
    func memory() throws {
        let store = InMemoryTokenStore()
        try store.saveAccessToken("gho_x")
        #expect(try store.loadAccessToken() == "gho_x")
        try store.clearAccessToken()
        #expect(try store.loadAccessToken() == nil)
    }
}

@Suite("AuthBridgeClient")
struct AuthBridgeClientTests {
    @Test("exchanges code via bridge")
    func exchange() async throws {
        let transport = MockHTTPTransport()
        transport.handler = { request in
            #expect(request.url?.absoluteString.hasSuffix("/oauth/token") == true)
            #expect(request.httpMethod == "POST")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            #expect(body["code"] == "abc")
            #expect(body["code_verifier"] == "ver")
            #expect(body["redirect_uri"] == "crewrp://oauth/callback")
            let data = Data(#"{"access_token":"gho_ok","token_type":"bearer","scope":"read:org"}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        let client = AuthBridgeClient(baseURL: URL(string: "https://auth.example")!, transport: transport)
        let result = try await client.exchange(code: "abc", codeVerifier: "ver", redirectURI: "crewrp://oauth/callback")
        #expect(result.accessToken == "gho_ok")
    }
}

@Suite("GitHubMembershipClient")
struct GitHubMembershipClientTests {
    @Test("lists orgs and resolves admins role")
    func resolveAdmin() async throws {
        let transport = MockHTTPTransport()
        transport.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/user/orgs") {
                let data = Data(#"[{"login":"crew","id":1}]"#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if path.hasSuffix("/user/teams") {
                let data = Data(#"""
                [{"id":9,"slug":"admins","name":"Admins","organization":{"login":"crew"}},
                 {"id":10,"slug":"members","name":"Members","organization":{"login":"other"}}]
                """#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            Issue.record("unexpected \(path)")
            throw GitHubAPIError.invalidResponse
        }
        let client = GitHubMembershipClient(transport: transport, apiBase: URL(string: "https://api.github.com")!)
        let orgs = try await client.listOrganizations(token: "t")
        #expect(orgs.map(\.login) == ["crew"])
        #expect(try await client.resolveRole(org: "crew", token: "t") == .admin)
    }
}

@Suite("AuthFlow")
struct AuthFlowTests {
    @Test("completes login and selects organization")
    func loginAndSelect() async throws {
        let transport = MockHTTPTransport()
        transport.handler = { request in
            let url = request.url!.absoluteString
            if url.contains("/oauth/token") {
                let data = Data(#"{"access_token":"gho_ok","token_type":"bearer"}"#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if url.contains("/user/orgs") {
                let data = Data(#"[{"login":"crew","id":1}]"#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if url.contains("/user/teams") {
                let data = Data(#"[{"id":9,"slug":"members","name":"Members","organization":{"login":"crew"}}]"#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            throw GitHubAPIError.invalidResponse
        }
        let cache = try CacheStore(path: ":memory:")
        let tokens = InMemoryTokenStore()
        let config = AuthConfig(
            clientID: "cid",
            redirectURI: "crewrp://oauth/callback",
            authBridgeBaseURL: URL(string: "https://auth.example")!
        )
        let flow = AuthFlow(
            config: config,
            bridge: AuthBridgeClient(baseURL: config.authBridgeBaseURL, transport: transport),
            membership: GitHubMembershipClient(transport: transport),
            tokens: tokens,
            cache: cache
        )
        let challenge = flow.beginLogin()
        let callback = URL(string: "crewrp://oauth/callback?code=abc&state=\(challenge.state)")!
        let orgs = try await flow.completeLogin(callbackURL: callback)
        #expect(orgs.map(\.login) == ["crew"])
        #expect(try tokens.loadAccessToken() == "gho_ok")
        let session = try await flow.selectOrganization(orgs[0])
        #expect(session.repo == "crew/crew")
        #expect(session.teamRole == .member)
        #expect(try cache.session()?.org == "crew")
    }
}

@Suite("IssueFormParser")
struct IssueFormParserTests {
    @Test("parses YAML form fields")
    func parse() {
        let yaml = """
        name: 지출 결의서
        body:
          - type: input
            id: amount
            attributes:
              label: 금액
            validations:
              required: true
        """
        let form = IssueFormParser.parse(yaml)
        #expect(form.name == "지출 결의서")
        #expect(form.fields.count == 1)
        #expect(form.fields[0].id == "amount")
        #expect(form.fields[0].label == "금액")
        #expect(form.fields[0].required == true)
    }
}

@Suite("ETagRESTClient")
struct ETagRESTClientTests {
    @Test("returns cached body on 304")
    func notModified() async throws {
        let cache = try CacheStore(path: ":memory:")
        try cache.putCacheEntry(url: "https://api.github.com/repos/o/r/contents/docs/a.md", body: #"{"ok":1}"#, etag: "\"e1\"")
        let transport = MockHTTPTransport()
        transport.handler = { request in
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"e1\"")
            let response = HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        let client = ETagRESTClient(transport: transport, cache: cache)
        let result = try await client.get(url: URL(string: "https://api.github.com/repos/o/r/contents/docs/a.md")!, token: "t")
        #expect(result.fromCache)
        #expect(String(data: result.body, encoding: .utf8) == #"{"ok":1}"#)
    }
}

@Suite("DiscordDeepLink")
struct DiscordDeepLinkTests {
    @Test("builds voice channel URL")
    func url() {
        let url = DiscordDeepLink.voiceChannelURL(serverId: "1", channelId: "2")
        #expect(url.absoluteString == "https://discord.com/channels/1/2")
    }
}
