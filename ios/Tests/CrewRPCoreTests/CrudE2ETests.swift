import Foundation
import Testing
@testable import CrewRPCore

private enum E2EEnv {
    static var token: String? { ProcessInfo.processInfo.environment["CREWRP_E2E_TOKEN"] }
    static var repo: String? { ProcessInfo.processInfo.environment["CREWRP_E2E_REPO"] }
    static var projectNumber: Int {
        Int(ProcessInfo.processInfo.environment["CREWRP_E2E_PROJECT_NUMBER"] ?? "1") ?? 1
    }
    static var enabled: Bool { token != nil && repo != nil }
    static var requireProject: Bool {
        ProcessInfo.processInfo.environment["CREWRP_E2E_REQUIRE_PROJECT"] == "1"
    }
    static var parts: (owner: String, name: String)? {
        guard let repo, let slash = repo.firstIndex(of: "/") else { return nil }
        return (String(repo[..<slash]), String(repo[repo.index(after: slash)...]))
    }
}

/// Live GitHub CRUD against `CREWRP_E2E_TOKEN` + `CREWRP_E2E_REPO` (same clients as the apps).
@Suite("CRUD E2E", .enabled(if: E2EEnv.enabled))
struct CrudE2ETests {
    private let transport = URLSessionTransport()

    @Test("talk comment create update delete")
    func talkRoundTrip() async throws {
        let token = try #require(E2EEnv.token)
        let parts = try #require(E2EEnv.parts)
        let talk = ThreadTalkClient(transport: transport)
        let issue = try await talk.ensureTalkIssueNumber(owner: parts.owner, repo: parts.name, token: token)
        let marker = "crewrp-e2e-\(UUID().uuidString.prefix(8))"
        let created = try await talk.postComment(
            owner: parts.owner, repo: parts.name, issueNumber: issue, body: marker, token: token
        )
        #expect(created.body == marker)
        let edited = try await talk.updateComment(
            owner: parts.owner, repo: parts.name, commentId: created.id, body: "\(marker)-edit", token: token
        )
        #expect(edited.body.hasSuffix("-edit"))
        try await talk.deleteComment(owner: parts.owner, repo: parts.name, commentId: created.id, token: token)
    }

    @Test("notice create update delete")
    func noticeRoundTrip() async throws {
        let token = try #require(E2EEnv.token)
        let parts = try #require(E2EEnv.parts)
        let discussions = DiscussionsClient(transport: transport)
        let setup = try await discussions.resolveSetup(owner: parts.owner, repo: parts.name, token: token)
        let title = "crewrp-e2e-\(UUID().uuidString.prefix(8))"
        let created = try await discussions.createNotice(
            repositoryId: setup.repositoryId,
            categoryId: setup.categoryId,
            title: title,
            body: "e2e body",
            token: token
        )
        #expect(created.title == title)
        let edited = try await discussions.updateNotice(
            id: created.id, title: "\(title)-edit", body: "edited", token: token
        )
        #expect(edited.title.hasSuffix("-edit"))
        try await discussions.deleteNotice(id: created.id, token: token)
    }

    @Test("docs markdown save and delete")
    func docsRoundTrip() async throws {
        let token = try #require(E2EEnv.token)
        let parts = try #require(E2EEnv.parts)
        let cache = try CacheStore(path: ":memory:")
        let docs = DocsClient(transport: transport, cache: cache)
        let path = "docs/crewrp-e2e-\(UUID().uuidString.prefix(8)).md"
        let body = "# e2e\n\nhello\n"
        let saved = try await docs.saveMarkdown(
            owner: parts.owner, repo: parts.name, path: path, content: body, token: token, sha: nil
        )
        #expect(saved.path == path)
        let fetched = try await docs.fetchMarkdown(owner: parts.owner, repo: parts.name, path: path, token: token)
        #expect(fetched.content.contains("hello"))
        let sha = try #require(fetched.sha)
        try await docs.deleteDoc(owner: parts.owner, repo: parts.name, path: path, sha: sha, token: token)
    }

    @Test("task create and delete via project")
    func taskRoundTrip() async throws {
        let token = try #require(E2EEnv.token)
        let parts = try #require(E2EEnv.parts)
        let projects = ProjectsClient(transport: transport)
        let number: Int
        let meta: ProjectFieldMeta
        do {
            number = try await projects.resolveProjectNumber(
                owner: parts.owner, preferred: E2EEnv.projectNumber, token: token
            )
            let loaded = try await projects.loadFieldMeta(
                owner: parts.owner, projectNumber: number, token: token
            )
            if E2EEnv.requireProject {
                meta = try #require(loaded, "project meta missing after resolve")
            } else if let loaded {
                meta = loaded
            } else {
                return
            }
        } catch {
            // Host token without project: skip unless scripts set CREWRP_E2E_REQUIRE_PROJECT=1.
            if E2EEnv.requireProject { throw error }
            return
        }
        let title = "crewrp-e2e-\(UUID().uuidString.prefix(8))"
        let card = try await projects.createTask(
            owner: parts.owner,
            repo: parts.name,
            title: title,
            body: "e2e",
            projectNumber: number,
            token: token,
            dueOn: nil
        )
        #expect(card.title == title)
        try await projects.deleteTask(
            projectId: meta.projectId,
            itemId: card.id,
            owner: parts.owner,
            repo: parts.name,
            issueNumber: card.issueNumber,
            token: token
        )
    }
}
