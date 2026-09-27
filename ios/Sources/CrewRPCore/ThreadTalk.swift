import Foundation

public struct ThreadMessage: Sendable, Equatable, Identifiable {
    public let id: String
    public let body: String
    public let author: String

    public init(id: String, body: String, author: String) {
        self.id = id
        self.body = body
        self.author = author
    }
}

public struct ThreadTalkClient: Sendable {
    public static let talkIssueTitle = "스레드 톡"

    private let transport: any HTTPTransport
    private let apiBase: URL

    public init(transport: any HTTPTransport, apiBase: URL = URL(string: "https://api.github.com")!) {
        self.transport = transport
        self.apiBase = apiBase
    }

    /// Finds the dedicated talk issue (title `스레드 톡`), else issue `#1`, else creates one.
    public func ensureTalkIssueNumber(owner: String, repo: String, token: String) async throws -> Int {
        if let numbered = try await findOpenIssue(owner: owner, repo: repo, titled: Self.talkIssueTitle, token: token) {
            return numbered
        }
        if try await issueExists(owner: owner, repo: repo, number: 1, token: token) {
            return 1
        }
        return try await createIssue(owner: owner, repo: repo, title: Self.talkIssueTitle, body: "크루 스레드 톡", token: token)
    }

    public func listIssueComments(owner: String, repo: String, issueNumber: Int, token: String) async throws -> [ThreadMessage] {
        var request = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/issues/\(issueNumber)/comments"))
        applyGitHubHeaders(&request, token: token)
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
        struct Comment: Decodable {
            let id: Int
            let body: String
            let user: User
            struct User: Decodable { let login: String }
        }
        return try JSONDecoder().decode([Comment].self, from: data).map {
            ThreadMessage(id: String($0.id), body: $0.body, author: $0.user.login)
        }
    }

    public func postComment(owner: String, repo: String, issueNumber: Int, body: String, token: String) async throws -> ThreadMessage {
        var request = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/issues/\(issueNumber)/comments"))
        request.httpMethod = "POST"
        applyGitHubHeaders(&request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["body": body])
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
        return try decodeComment(data)
    }

    public func updateComment(owner: String, repo: String, commentId: String, body: String, token: String) async throws -> ThreadMessage {
        var request = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/issues/comments/\(commentId)"))
        request.httpMethod = "PATCH"
        applyGitHubHeaders(&request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["body": body])
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
        return try decodeComment(data)
    }

    public func deleteComment(owner: String, repo: String, commentId: String, token: String) async throws {
        var request = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/issues/comments/\(commentId)"))
        request.httpMethod = "DELETE"
        applyGitHubHeaders(&request, token: token)
        let (_, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
    }

    public func addReaction(owner: String, repo: String, commentId: String, content: String, token: String) async throws {
        var request = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/issues/comments/\(commentId)/reactions"))
        request.httpMethod = "POST"
        applyGitHubHeaders(&request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["content": content])
        let (_, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
    }

    private func applyGitHubHeaders(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    }

    private func findOpenIssue(owner: String, repo: String, titled title: String, token: String) async throws -> Int? {
        guard let url = GitHubMembershipClient.apiURL(
            base: apiBase,
            path: "repos/\(owner)/\(repo)/issues?state=open&per_page=50"
        ) else { throw GitHubAPIError.invalidResponse }
        var request = URLRequest(url: url)
        applyGitHubHeaders(&request, token: token)
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
        struct Issue: Decodable { let number: Int; let title: String }
        return try JSONDecoder().decode([Issue].self, from: data).first { $0.title == title }?.number
    }

    private func issueExists(owner: String, repo: String, number: Int, token: String) async throws -> Bool {
        var request = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/issues/\(number)"))
        applyGitHubHeaders(&request, token: token)
        let (_, response) = try await transport.data(for: request)
        if response.statusCode == 404 { return false }
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
        return true
    }

    private func createIssue(owner: String, repo: String, title: String, body: String, token: String) async throws -> Int {
        var request = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/issues"))
        request.httpMethod = "POST"
        applyGitHubHeaders(&request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["title": title, "body": body])
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
        struct Created: Decodable { let number: Int }
        return try JSONDecoder().decode(Created.self, from: data).number
    }

    private func decodeComment(_ data: Data) throws -> ThreadMessage {
        struct Comment: Decodable {
            let id: Int
            let body: String
            let user: User
            struct User: Decodable { let login: String }
        }
        let c = try JSONDecoder().decode(Comment.self, from: data)
        return ThreadMessage(id: String(c.id), body: c.body, author: c.user.login)
    }
}

public enum DiscordDeepLink {
    public static func voiceChannelURL(serverId: String, channelId: String) -> URL {
        URL(string: "https://discord.com/channels/\(serverId)/\(channelId)")!
    }
}
