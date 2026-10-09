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
        // Projects v2 mutations require the dedicated `project` scope (repo alone is not enough).
        #expect(map["scope"] == "read:org repo project")
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

@Suite("GitHubMembershipClient")
struct GitHubMembershipClientURLTests {
    @Test("apiURL encodes affiliation query")
    func apiURLBuildsReposQuery() {
        let base = URL(string: "https://api.github.com")!
        let url = GitHubMembershipClient.apiURL(
            base: base,
            path: "user/repos?per_page=100&affiliation=owner,organization_member"
        )
        #expect(url?.absoluteString.contains("user/repos") == true)
        #expect(url?.absoluteString.contains("affiliation=") == true)
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
    @Test("lists registrable repos and resolves admins role")
    func registrableAndAdmin() async throws {
        let transport = MockHTTPTransport()
        transport.handler = { request in
            let path = request.url!.absoluteString
            if path.contains("/user/repos") {
                let data = Data(#"""
                [{"name":"box","full_name":"crew/box","private":true,
                  "permissions":{"admin":true},"owner":{"login":"crew"}},
                 {"name":"public","full_name":"crew/public","private":false,
                  "permissions":{"admin":true},"owner":{"login":"crew"}}]
                """#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if path.hasSuffix("/user/teams") || request.url!.path.hasSuffix("/user/teams") {
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
        let repos = try await client.listRegistrableRepos(token: "t")
        #expect(repos.map(\.fullName) == ["crew/box"])
        #expect(try await client.resolveRole(owner: "crew", token: "t", isRepoAdmin: true) == .admin)
    }
}

@Suite("AuthFlow")
struct AuthFlowTests {
    @Test("completes login and registers crew repo")
    func loginAndRegister() async throws {
        let transport = MockHTTPTransport()
        transport.handler = { request in
            let path = request.url!.absoluteString
            if path.hasSuffix("/oauth/token") || request.url!.path.hasSuffix("/oauth/token") {
                let data = Data(#"{"access_token":"gho_ok","token_type":"bearer"}"#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if path.contains("/user/repos") {
                let data = Data(#"""
                [{"name":"box","full_name":"crew/box","private":true,
                  "permissions":{"admin":true},"owner":{"login":"crew"}}]
                """#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if request.url!.path.hasSuffix("/user/teams") {
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
        let repos = try await flow.completeLogin(callbackURL: callback)
        #expect(repos.map(\.fullName) == ["crew/box"])
        #expect(try tokens.loadAccessToken() == "gho_ok")
        let session = try await flow.registerCrew(repos[0])
        #expect(session.repo == "crew/box")
        #expect(session.teamRole == .member)
        #expect(try cache.session()?.org == "crew")
    }

    @Test("personal admin repo registers as owner admin")
    func personalAdminRepo() async throws {
        let transport = MockHTTPTransport()
        transport.handler = { request in
            let path = request.url!.absoluteString
            if request.url!.path.hasSuffix("/oauth/token") {
                return (Data(#"{"access_token":"gho_ok"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if path.contains("/user/repos") {
                let data = Data(#"""
                [{"name":"study","full_name":"alice/study","private":true,
                  "permissions":{"admin":true},"owner":{"login":"alice"}}]
                """#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if request.url!.path.hasSuffix("/user/teams") {
                return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            throw GitHubAPIError.invalidResponse
        }
        let cache = try CacheStore(path: ":memory:")
        let flow = AuthFlow(
            config: AuthConfig(clientID: "cid", redirectURI: "crewrp://oauth/callback", authBridgeBaseURL: URL(string: "https://auth.example")!),
            bridge: AuthBridgeClient(baseURL: URL(string: "https://auth.example")!, transport: transport),
            membership: GitHubMembershipClient(transport: transport),
            tokens: InMemoryTokenStore(),
            cache: cache
        )
        let challenge = flow.beginLogin()
        let repos = try await flow.completeLogin(callbackURL: URL(string: "crewrp://oauth/callback?code=x&state=\(challenge.state)")!)
        #expect(repos.map(\.fullName) == ["alice/study"])
        let session = try await flow.registerCrew(repos[0])
        #expect(session.repo == "alice/study")
        #expect(session.teamRole == .admin)
    }

    @Test("logout clears token session and pending oauth")
    func logoutClearsLocalAuth() async throws {
        let transport = MockHTTPTransport()
        transport.handler = { request in
            if request.url!.path.hasSuffix("/oauth/token") {
                return (Data(#"{"access_token":"gho_ok"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if request.url!.absoluteString.contains("/user/repos") {
                let data = Data(#"""
                [{"name":"box","full_name":"crew/box","private":true,
                  "permissions":{"admin":true},"owner":{"login":"crew"}}]
                """#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if request.url!.path.hasSuffix("/user/teams") {
                return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            throw GitHubAPIError.invalidResponse
        }
        let cache = try CacheStore(path: ":memory:")
        let tokens = InMemoryTokenStore()
        let pending = InMemoryPendingLoginStore()
        let flow = AuthFlow(
            config: AuthConfig(clientID: "cid", redirectURI: "crewrp://oauth/callback", authBridgeBaseURL: URL(string: "https://auth.example")!),
            bridge: AuthBridgeClient(baseURL: URL(string: "https://auth.example")!, transport: transport),
            membership: GitHubMembershipClient(transport: transport),
            tokens: tokens,
            cache: cache,
            pendingStore: pending
        )
        let challenge = flow.beginLogin()
        _ = try await flow.completeLogin(callbackURL: URL(string: "crewrp://oauth/callback?code=x&state=\(challenge.state)")!)
        _ = try await flow.registerCrew(CrewRepo(owner: "crew", name: "box", fullName: "crew/box", isPrivate: true))
        _ = flow.beginLogin()
        try flow.logout()
        #expect(try tokens.loadAccessToken() == nil)
        #expect(try cache.session() == nil)
        #expect(try pending.load() == nil)
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

    @Test("persists response ETag for later If-None-Match")
    func storesEtag() async throws {
        let cache = try CacheStore(path: ":memory:")
        let transport = MockHTTPTransport()
        transport.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["ETag": "\"fresh\""]
            )!
            return (Data(#"{"path":"docs/a.md","content":"","encoding":"base64"}"#.utf8), response)
        }
        let client = ETagRESTClient(transport: transport, cache: cache)
        _ = try await client.get(url: URL(string: "https://api.github.com/repos/o/r/contents/docs/a.md")!, token: "t")
        #expect(try cache.cacheEntry(url: "https://api.github.com/repos/o/r/contents/docs/a.md")?.etag == "\"fresh\"")
    }
}

@Suite("GraphQLFreshness")
struct GraphQLFreshnessTests {
    @Test("skips network when cursor is fresh")
    func skipsNetworkWhenFresh() async throws {
        let cache = try CacheStore(path: ":memory:")
        let payload = [Notice(id: "D1", title: "t", body: "b", authorLogin: "ada")]
        let body = try JSONEncoder().encode(payload)
        let now = Date(timeIntervalSince1970: 1_000)
        GraphQLFreshness.store(
            cache: cache,
            queryName: GraphQLFreshness.listNoticesQueryName(owner: "o", repo: "r"),
            body: body,
            now: now
        )
        final class HitCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() {
                lock.lock()
                value += 1
                lock.unlock()
            }
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }
        let hits = HitCounter()
        let transport = MockHTTPTransport()
        transport.handler = { _ in
            hits.increment()
            fatalError("network should not run")
        }
        let notices = try await DiscussionsClient(transport: transport).listNotices(
            owner: "o",
            repo: "r",
            token: "t",
            cache: cache,
            forceNetwork: false,
            now: now.addingTimeInterval(30)
        )
        #expect(hits.count == 0)
        #expect(notices.map(\.id) == ["D1"])
    }

    @Test("forceNetwork bypasses freshness")
    func forceNetworkBypasses() async throws {
        let cache = try CacheStore(path: ":memory:")
        let stale = [Notice(id: "OLD", title: "old", body: "", authorLogin: nil)]
        GraphQLFreshness.store(
            cache: cache,
            queryName: GraphQLFreshness.listNoticesQueryName(owner: "o", repo: "r"),
            body: try JSONEncoder().encode(stale),
            now: Date(timeIntervalSince1970: 1_000)
        )
        let transport = MockHTTPTransport()
        transport.handler = { _ in
            let json = #"{"data":{"repository":{"discussions":{"nodes":[{"id":"NEW","title":"n","body":"","author":{"login":"x"}}]}}}}"#
            let response = HTTPURLResponse(
                url: URL(string: "https://api.github.com/graphql")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(json.utf8), response)
        }
        let notices = try await DiscussionsClient(transport: transport).listNotices(
            owner: "o",
            repo: "r",
            token: "t",
            cache: cache,
            forceNetwork: true,
            now: Date(timeIntervalSince1970: 1_030)
        )
        #expect(notices.map(\.id) == ["NEW"])
    }
}

@Suite("CacheStore concurrency")
struct CacheStoreConcurrencyTests {
    @Test("survives concurrent writers")
    func concurrentWriters() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "crewrp-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "crewrp.sqlite").path
        let store = try CacheStore(path: path)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask {
                    try? store.putCacheEntry(url: "https://example.com/\(i)", body: "{\"i\":\(i)}", etag: "\"e\(i)\"")
                    try? store.putSession(Session(org: "o", repo: "o/r", teamRole: .admin))
                    _ = try? store.cacheEntry(url: "https://example.com/\(i)")
                }
            }
        }
        #expect(try store.session()?.repo == "o/r")
    }
}

@Suite("CrewRegistrationFixtures")
struct CrewRegistrationFixtureTests {
    @Test("expense form seed matches parser contract")
    func expenseForm() {
        let yaml = """
        name: 지출 결의서
        description: 영수증을 첨부한 지출 요청
        body:
          - type: input
            id: amount
            attributes:
              label: 금액
            validations:
              required: true
          - type: textarea
            id: reason
            attributes:
              label: 사유
            validations:
              required: true
        """
        let form = IssueFormParser.parse(yaml)
        #expect(form.name == "지출 결의서")
        #expect(form.fields.map(\.id) == ["amount", "reason"])
        #expect(form.fields.allSatisfy { $0.required })
    }

    @Test("docs README fetch for registered repo")
    func docsFetch() async throws {
        let markdown = "# 자료실\n"
        let encoded = Data(markdown.utf8).base64EncodedString()
        let cache = try CacheStore(path: ":memory:")
        let transport = MockHTTPTransport()
        transport.handler = { request in
            #expect(request.url!.path.hasSuffix("/repos/crew/box/contents/docs/README.md"))
            let payload: [String: Any] = [
                "path": "docs/README.md",
                "content": encoded,
                "encoding": "base64",
            ]
            let body = try JSONSerialization.data(withJSONObject: payload)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"d1\""])!)
        }
        let doc = try await DocsClient(transport: transport, cache: cache)
            .fetchMarkdown(owner: "crew", repo: "box", path: "docs/README.md", token: "t")
        #expect(doc.content.contains("자료실"))
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

@Suite("ShellPresentation")
struct ShellPresentationTests {
    @Test("labels role, lane, and due date")
    func labels() {
        #expect(TeamRole.admin.label == "운영진")
        #expect(TeamRole.member.label == "멤버")
        #expect(taskLane(status: "Todo") == .inbox)
        #expect(taskLane(status: "In Progress") == .doing)
        #expect(taskLane(status: "완료") == .done)
        #expect(formatDue("2026-09-05") == "9월 5일")
        #expect(formatDue(nil) == "마감 없음")
        #expect(crewDisplayName("acme/crew") == "crew")
        #expect(crewOwnerName("acme/crew") == "acme")
        #expect(discordConfigured(serverId: "REPLACE_ME", channelId: "1") == false)
        #expect(discordConfigured(serverId: "123", channelId: "456") == true)
    }

    @Test("compact kanban stacks lanes; wide keeps columns")
    func kanbanLayout() {
        #expect(kanbanUsesStackedLanes(compact: true))
        #expect(!kanbanUsesStackedLanes(compact: false))
        #expect(taskStatusChoice(status: "In Progress") == "진행 중")
        #expect(taskStatusChoice(status: "Todo") == "접수")
        #expect(dueOnInput("2026-10-06T09:00:00") == "2026-10-06")
        #expect(dueOnInput(nil) == "")
    }

    @Test("home keeps today, upcoming, and three notices")
    func home() {
        let tasks = [
            TaskCard(id: "a", title: "오늘", status: "접수", dueOn: "2026-09-27T09:00:00"),
            TaskCard(id: "b", title: "다음", status: "In Progress", dueOn: "2026-10-01"),
            TaskCard(id: "c", title: "끝", status: "Done", dueOn: "2026-10-02"),
            TaskCard(id: "d", title: "지난", status: "접수", dueOn: "2026-09-01"),
        ]
        let notices = (1...4).map { Notice(id: "n\($0)", title: "공지\($0)", body: "") }
        let home = homeSections(tasks: tasks, notices: notices, today: "2026-09-27")
        #expect(home.today.map(\.id) == ["a"])
        #expect(home.upcoming.map(\.id) == ["b"])
        #expect(home.notices.map(\.id) == ["n1", "n2", "n3"])
    }

    @Test("doc blocks keep headings, bullets, and paragraphs")
    func blocks() {
        let blocks = docBlocks("# 정관\n\n첫 문단\n이어짐\n\n- 하나\n")
        #expect(blocks == [.heading("정관"), .paragraph("첫 문단 이어짐"), .bullet("하나")])
    }

    @Test("filterDocs matches name or path case-insensitively; empty query keeps all; dirs first")
    func filterDocsQuery() {
        let entries = [
            DocEntry(path: "docs/README.md", name: "README.md", sha: nil, isDir: false),
            DocEntry(path: "docs/guides", name: "guides", sha: nil, isDir: true),
            DocEntry(path: "docs/guides/onboard.md", name: "onboard.md", sha: nil, isDir: false),
            DocEntry(path: "docs/notes.md", name: "notes.md", sha: nil, isDir: false),
        ]
        #expect(filterDocs(entries, query: "").map(\.name) == ["guides", "notes.md", "onboard.md", "README.md"])
        #expect(filterDocs(entries, query: "GUIDE").map(\.path) == ["docs/guides", "docs/guides/onboard.md"])
        #expect(filterDocs(entries, query: "readme").map(\.name) == ["README.md"])
        #expect(filterDocs(entries, query: "   ").count == 4)
    }

    @Test("parentDocsPath walks up until docs root")
    func parentDocsPathWalk() {
        #expect(parentDocsPath("docs") == nil)
        #expect(parentDocsPath("docs/") == nil)
        #expect(parentDocsPath("docs/guides") == "docs")
        #expect(parentDocsPath("docs/guides/deep") == "docs/guides")
    }

    @Test("canMutate allows admin or author")
    func mutate() {
        #expect(canMutate(role: .admin, authorLogin: "other", currentLogin: "me"))
        #expect(canMutate(role: .member, authorLogin: "me", currentLogin: "me"))
        #expect(!canMutate(role: .member, authorLogin: "other", currentLogin: "me"))
    }

    @Test("writeFailureMessage guides re-login on missing scopes")
    func writeFailureGuidesRelogin() {
        #expect(writeFailureMessage("requires one of the following scopes: ['project']").contains("다시 로그인"))
        #expect(writeFailureMessage("httpStatus(401)").contains("만료"))
        #expect(writeFailureMessage("timeout") == "저장하지 못했습니다. 잠시 후 다시 시도해 주세요.")
    }

    @Test("loginFailureMessage ignores canceled session")
    func loginFailureIgnoresCancel() {
        #expect(loginFailureMessage(domain: "com.apple.AuthenticationServices.WebAuthenticationSession", code: 1) == nil)
        #expect(loginFailureMessage(domain: "com.apple.AuthenticationServices.WebAuthenticationSession", code: 2) != nil)
    }

    @Test("authFailureMessage maps pending and http errors")
    func authFailureMaps() {
        #expect(authFailureMessage(describing: "missingPendingLogin").contains("만료"))
        #expect(authFailureMessage(describing: "httpStatus(401)").contains("권한"))
        // OSStatus -34018 must not be mistaken for HTTP 401.
        #expect(!authFailureMessage(describing: "loadFailed(-34018)").contains("권한"))
        #expect(authFailureMessage(describing: "loadFailed(-34018)").contains("저장하지"))
    }
}

@Suite("PendingLoginStore")
struct PendingLoginStoreTests {
    @Test("user defaults pending round-trips")
    func userDefaultsPending() throws {
        let defaults = UserDefaults(suiteName: "crewrp.test.pending")!
        defaults.removePersistentDomain(forName: "crewrp.test.pending")
        let store = UserDefaultsPendingLoginStore(defaults: defaults)
        try store.save(state: "st", codeVerifier: "ver")
        let loaded = try store.load()
        #expect(loaded?.state == "st")
        #expect(loaded?.codeVerifier == "ver")
        try store.clear()
        #expect(try store.load() == nil)
    }
}
