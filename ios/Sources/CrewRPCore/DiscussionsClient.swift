import Foundation

public struct Notice: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let body: String
    public let authorLogin: String?

    public init(id: String, title: String, body: String, authorLogin: String? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.authorLogin = authorLogin
    }
}

public struct DiscussionSetup: Sendable, Equatable {
    public let repositoryId: String
    public let categoryId: String
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
            discussions(first:20){ nodes { id title body author { login } } }
          }
        }
        """
        let data = try await graphql(token: token, query: query, variables: ["owner": owner, "name": repo])
        struct Envelope: Decodable {
            struct DataObj: Decodable {
                struct Repo: Decodable {
                    struct Discussions: Decodable {
                        struct Node: Decodable {
                            let id: String
                            let title: String
                            let body: String
                            let author: Author?
                            struct Author: Decodable { let login: String }
                        }
                        let nodes: [Node]
                    }
                    let discussions: Discussions
                }
                let repository: Repo?
            }
            let data: DataObj
        }
        let decoded = try JSONDecoder().decode(Envelope.self, from: data)
        return (decoded.data.repository?.discussions.nodes ?? []).map {
            Notice(id: $0.id, title: $0.title, body: $0.body, authorLogin: $0.author?.login)
        }
    }

    public func getNotice(id: String, token: String) async throws -> Notice {
        let query = """
        query($id:ID!){
          node(id:$id){ ... on Discussion { id title body author { login } } }
        }
        """
        let data = try await graphql(token: token, query: query, variables: ["id": id])
        struct Envelope: Decodable {
            struct DataObj: Decodable {
                struct Node: Decodable {
                    let id: String
                    let title: String
                    let body: String
                    let author: Author?
                    struct Author: Decodable { let login: String }
                }
                let node: Node
            }
            let data: DataObj
        }
        let n = try JSONDecoder().decode(Envelope.self, from: data).data.node
        return Notice(id: n.id, title: n.title, body: n.body, authorLogin: n.author?.login)
    }

    public func resolveSetup(owner: String, repo: String, token: String) async throws -> DiscussionSetup {
        let query = """
        query($owner:String!,$name:String!){
          repository(owner:$owner,name:$name){
            id
            discussionCategories(first:20){ nodes { id name } }
          }
        }
        """
        let data = try await graphql(token: token, query: query, variables: ["owner": owner, "name": repo])
        struct Envelope: Decodable {
            struct DataObj: Decodable {
                struct Repo: Decodable {
                    let id: String
                    struct Cats: Decodable {
                        struct Node: Decodable { let id: String; let name: String }
                        let nodes: [Node]
                    }
                    let discussionCategories: Cats
                }
                let repository: Repo
            }
            let data: DataObj
        }
        let repoNode = try JSONDecoder().decode(Envelope.self, from: data).data.repository
        let preferred = repoNode.discussionCategories.nodes.first { $0.name.contains("공지") }
            ?? repoNode.discussionCategories.nodes.first
        guard let preferred else { throw GitHubAPIError.invalidResponse }
        return DiscussionSetup(repositoryId: repoNode.id, categoryId: preferred.id)
    }

    public func createNotice(repositoryId: String, categoryId: String, title: String, body: String, token: String) async throws -> Notice {
        let query = """
        mutation($input:CreateDiscussionInput!){
          createDiscussion(input:$input){ discussion { id title body author { login } } }
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
        return try decodeDiscussionMutation(data, key: "createDiscussion")
    }

    public func updateNotice(id: String, title: String, body: String, token: String) async throws -> Notice {
        let query = """
        mutation($input:UpdateDiscussionInput!){
          updateDiscussion(input:$input){ discussion { id title body author { login } } }
        }
        """
        let variables: [String: Any] = [
            "input": [
                "discussionId": id,
                "title": title,
                "body": body,
            ],
        ]
        let data = try await graphql(token: token, query: query, variables: variables)
        return try decodeDiscussionMutation(data, key: "updateDiscussion")
    }

    public func deleteNotice(id: String, token: String) async throws {
        let query = """
        mutation($input:DeleteDiscussionInput!){
          deleteDiscussion(input:$input){ discussion { id } }
        }
        """
        _ = try await graphql(token: token, query: query, variables: ["input": ["id": id]])
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

    private func decodeDiscussionMutation(_ data: Data, key: String) throws -> Notice {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObj = root["data"] as? [String: Any],
            let payload = dataObj[key] as? [String: Any],
            let d = payload["discussion"] as? [String: Any],
            let id = d["id"] as? String,
            let title = d["title"] as? String,
            let body = d["body"] as? String
        else { throw GitHubAPIError.invalidResponse }
        let author = (d["author"] as? [String: Any])?["login"] as? String
        return Notice(id: id, title: title, body: body, authorLogin: author)
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
