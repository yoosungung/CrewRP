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
    private let transport: any HTTPTransport
    private let apiBase: URL

    public init(transport: any HTTPTransport, apiBase: URL = URL(string: "https://api.github.com")!) {
        self.transport = transport
        self.apiBase = apiBase
    }

    public func listIssueComments(owner: String, repo: String, issueNumber: Int, token: String) async throws -> [ThreadMessage] {
        var request = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/issues/\(issueNumber)/comments"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
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
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
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
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
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
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (_, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
    }

    public func addReaction(owner: String, repo: String, commentId: String, content: String, token: String) async throws {
        var request = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/issues/comments/\(commentId)/reactions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["content": content])
        let (_, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
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
