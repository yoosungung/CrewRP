import Foundation

public struct Notice: Sendable, Equatable {
    public let id: String
    public let title: String
    public let body: String
}

public struct PollOption: Sendable, Equatable {
    public let id: String
    public let text: String
    public let voteCount: Int
    public let viewerHasVoted: Bool
}

public struct DiscussionsClient: Sendable {
    private let transport: any HTTPTransport
    private let apiBase: URL

    public init(transport: any HTTPTransport, apiBase: URL = URL(string: "https://api.github.com")!) {
        self.transport = transport
        self.apiBase = apiBase
    }

    public func listNotices(owner: String, repo: String, token: String) async throws -> [Notice] {
        let query = """
        query($owner:String!,$name:String!){
          repository(owner:$owner,name:$name){
            discussions(first:20){ nodes { id title body } }
          }
        }
        """
        let data = try await graphql(token: token, query: query, variables: ["owner": owner, "name": repo])
        struct Envelope: Decodable {
            struct DataObj: Decodable {
                struct Repo: Decodable {
                    struct Discussions: Decodable {
                        struct Node: Decodable { let id: String; let title: String; let body: String }
                        let nodes: [Node]
                    }
                    let discussions: Discussions
                }
                let repository: Repo
            }
            let data: DataObj
        }
        let decoded = try JSONDecoder().decode(Envelope.self, from: data)
        return decoded.data.repository.discussions.nodes.map {
            Notice(id: $0.id, title: $0.title, body: $0.body)
        }
    }

    public func createNotice(repositoryId: String, categoryId: String, title: String, body: String, token: String) async throws -> Notice {
        let query = """
        mutation($input:CreateDiscussionInput!){
          createDiscussion(input:$input){ discussion { id title body } }
        }
        """
        let variables: [String: Any] = [
            "input": [
                "repositoryId": repositoryId,
                "categoryId": categoryId,
                "title": title,
                "body": body,
            ],
        ]
        let data = try await graphql(token: token, query: query, variables: variables)
        struct Envelope: Decodable {
            struct DataObj: Decodable {
                struct Payload: Decodable {
                    struct Discussion: Decodable { let id: String; let title: String; let body: String }
                    let discussion: Discussion
                }
                let createDiscussion: Payload
            }
            let data: DataObj
        }
        let decoded = try JSONDecoder().decode(Envelope.self, from: data)
        let d = decoded.data.createDiscussion.discussion
        return Notice(id: d.id, title: d.title, body: d.body)
    }

    public func vote(pollOptionId: String, token: String) async throws {
        let query = """
        mutation($input:AddDiscussionPollVoteInput!){
          addDiscussionPollVote(input:$input){ pollOption { id } }
        }
        """
        _ = try await graphql(
            token: token,
            query: query,
            variables: ["input": ["pollOptionId": pollOptionId]]
        )
    }

    private func graphql(token: String, query: String, variables: [String: Any]) async throws -> Data {
        var request = URLRequest(url: apiBase.appending(path: "graphql"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
        return data
    }
}
