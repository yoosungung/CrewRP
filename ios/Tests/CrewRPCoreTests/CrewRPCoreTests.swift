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
