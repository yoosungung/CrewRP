import Foundation

public struct ThreadMessage: Sendable, Equatable {
    public let id: String
    public let body: String
    public let author: String
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

    public func addReaction(owner: String, repo: String, commentId: Int, content: String, token: String) async throws {
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
}

public enum DiscordDeepLink {
    public static func voiceChannelURL(serverId: String, channelId: String) -> URL {
        URL(string: "https://discord.com/channels/\(serverId)/\(channelId)")!
    }
}
