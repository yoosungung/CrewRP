import Foundation

public struct TaskCard: Sendable, Equatable {
    public let id: String
    public let title: String
    public let status: String
    public let dueOn: String?
}

public struct ProjectsClient: Sendable {
    private let transport: any HTTPTransport
    private let apiBase: URL

    public init(transport: any HTTPTransport, apiBase: URL = URL(string: "https://api.github.com")!) {
        self.transport = transport
        self.apiBase = apiBase
    }

    public func listTasks(org: String, projectNumber: Int, token: String) async throws -> [TaskCard] {
        let query = """
        query($org:String!,$number:Int!){
          organization(login:$org){
            projectV2(number:$number){
              items(first:50){
                nodes{
                  id
                  content{ ... on Issue { title } }
                  fieldValues(first:20){
                    nodes{
                      ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2SingleSelectField { name } } }
                      ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { name } } }
                    }
                  }
                }
              }
            }
          }
        }
        """
        let body: [String: Any] = [
            "query": query,
            "variables": ["org": org, "number": projectNumber],
        ]
        var request = URLRequest(url: apiBase.appending(path: "graphql"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }

        struct Envelope: Decodable {
            struct DataObj: Decodable {
                struct Org: Decodable {
                    struct Project: Decodable {
                        struct Items: Decodable {
                            struct Node: Decodable {
                                let id: String
                                let content: Content?
                                let fieldValues: FieldValues
                                struct Content: Decodable { let title: String? }
                                struct FieldValues: Decodable {
                                    let nodes: [FieldNode]
                                    struct FieldNode: Decodable {
                                        let name: String?
                                        let date: String?
                                        let field: FieldName?
                                        struct FieldName: Decodable { let name: String? }
                                    }
                                }
                            }
                            let nodes: [Node]
                        }
                        let items: Items
                    }
                    let projectV2: Project
                }
                let organization: Org
            }
            let data: DataObj
        }
        let decoded = try JSONDecoder().decode(Envelope.self, from: data)
        return decoded.data.organization.projectV2.items.nodes.map { node in
            var status = "할 일"
            var due: String?
            for field in node.fieldValues.nodes {
                if field.field?.name == "Status", let name = field.name {
                    status = name
                }
                if field.field?.name == "Due", let date = field.date {
                    due = date
                }
            }
            return TaskCard(id: node.id, title: node.content?.title ?? "(제목 없음)", status: status, dueOn: due)
        }
    }

    public func sortedByDueDate(_ cards: [TaskCard]) -> [TaskCard] {
        cards.sorted { ($0.dueOn ?? "9999") < ($1.dueOn ?? "9999") }
    }
}
