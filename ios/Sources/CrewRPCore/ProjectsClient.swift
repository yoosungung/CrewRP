import Foundation

public struct TaskCard: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let status: String
    public let dueOn: String?
    public let issueNumber: Int?
    public let contentId: String?

    public init(
        id: String,
        title: String,
        status: String,
        dueOn: String?,
        issueNumber: Int? = nil,
        contentId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.dueOn = dueOn
        self.issueNumber = issueNumber
        self.contentId = contentId
    }
}

public struct ProjectFieldMeta: Sendable, Equatable {
    public let projectId: String
    public let statusFieldId: String?
    public let dueFieldId: String?
    public let statusOptions: [String: String]
}

public struct ProjectsClient: Sendable {
    private let transport: any HTTPTransport
    private let apiBase: URL

    public init(transport: any HTTPTransport, apiBase: URL = URL(string: "https://api.github.com")!) {
        self.transport = transport
        self.apiBase = apiBase
    }

    public func listTasks(org: String, projectNumber: Int, token: String) async throws -> [TaskCard] {
        if let cards = try await queryItems(kind: "organization", login: org, projectNumber: projectNumber, token: token) {
            return cards
        }
        return try await queryItems(kind: "user", login: org, projectNumber: projectNumber, token: token) ?? []
    }

    public func sortedByDueDate(_ cards: [TaskCard]) -> [TaskCard] {
        cards.sorted { ($0.dueOn ?? "9999") < ($1.dueOn ?? "9999") }
    }

    public func firstProjectNumber(owner: String, token: String) async throws -> Int? {
        let query = """
        query($login:String!){
          organization(login:$login){ projectsV2(first:20){ nodes{ number } } }
          user(login:$login){ projectsV2(first:20){ nodes{ number } } }
        }
        """
        let data = try await graphql(token: token, query: query, variables: ["login": owner])
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObj = root["data"] as? [String: Any]
        else { return nil }
        func numbers(_ key: String) -> [Int] {
            let nodes = ((dataObj[key] as? [String: Any])?["projectsV2"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            return nodes.compactMap { $0["number"] as? Int }
        }
        return (numbers("organization") + numbers("user")).min()
    }

    public func createUserProject(ownerLogin: String, title: String, token: String) async throws -> Int {
        let idData = try await graphql(
            token: token,
            query: "query($login:String!){ user(login:$login){ id } }",
            variables: ["login": ownerLogin]
        )
        guard
            let idRoot = try JSONSerialization.jsonObject(with: idData) as? [String: Any],
            let ownerId = ((idRoot["data"] as? [String: Any])?["user"] as? [String: Any])?["id"] as? String
        else { throw GitHubAPIError.httpStatus(500) }
        let created = try await graphql(
            token: token,
            query: """
            mutation($ownerId:ID!,$title:String!){
              createProjectV2(input:{ownerId:$ownerId,title:$title}){ projectV2 { number } }
            }
            """,
            variables: ["ownerId": ownerId, "title": title]
        )
        guard
            let root = try JSONSerialization.jsonObject(with: created) as? [String: Any],
            let number = (((root["data"] as? [String: Any])?["createProjectV2"] as? [String: Any])?["projectV2"] as? [String: Any])?["number"] as? Int
        else { throw GitHubAPIError.httpStatus(500) }
        return number
    }

    public func resolveProjectNumber(owner: String, preferred: Int, token: String) async throws -> Int {
        if try await loadFieldMeta(owner: owner, projectNumber: preferred, token: token) != nil {
            return preferred
        }
        if let existing = try await firstProjectNumber(owner: owner, token: token) {
            return existing
        }
        return try await createUserProject(ownerLogin: owner, title: "CrewRP", token: token)
    }

    public func loadFieldMeta(owner: String, projectNumber: Int, token: String) async throws -> ProjectFieldMeta? {
        let query = """
        query($login:String!,$number:Int!){
          organization(login:$login){
            projectV2(number:$number){
              id
              fields(first:20){
                nodes{
                  ... on ProjectV2SingleSelectField { id name options { id name } }
                  ... on ProjectV2Field { id name }
                }
              }
            }
          }
          user(login:$login){
            projectV2(number:$number){
              id
              fields(first:20){
                nodes{
                  ... on ProjectV2SingleSelectField { id name options { id name } }
                  ... on ProjectV2Field { id name }
                }
              }
            }
          }
        }
        """
        let data = try await graphql(token: token, query: query, variables: ["login": owner, "number": projectNumber])
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObj = root["data"] as? [String: Any]
        else { return nil }
        let project = (dataObj["organization"] as? [String: Any])?["projectV2"] as? [String: Any]
            ?? (dataObj["user"] as? [String: Any])?["projectV2"] as? [String: Any]
        guard let project, let projectId = project["id"] as? String else { return nil }
        var statusFieldId: String?
        var dueFieldId: String?
        var options: [String: String] = [:]
        let nodes = ((project["fields"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        for node in nodes {
            let fieldName = node["name"] as? String
            switch fieldName {
            case "Status":
                statusFieldId = node["id"] as? String
                for opt in (node["options"] as? [[String: Any]]) ?? [] {
                    if let name = opt["name"] as? String, let id = opt["id"] as? String {
                        options[name] = id
                    }
                }
            default:
                if isProjectsDueFieldName(fieldName) {
                    dueFieldId = node["id"] as? String
                }
            }
        }
        return ProjectFieldMeta(
            projectId: projectId,
            statusFieldId: statusFieldId,
            dueFieldId: dueFieldId,
            statusOptions: options
        )
    }

    public func createTask(
        owner: String,
        repo: String,
        title: String,
        body: String,
        projectNumber: Int,
        token: String,
        dueOn: String? = nil,
        statusLabel: String = "접수"
    ) async throws -> TaskCard {
        var request = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/issues"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["title": title, "body": body])
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
        struct IssueDTO: Decodable {
            let number: Int
            let node_id: String
        }
        let issue = try JSONDecoder().decode(IssueDTO.self, from: data)
        let meta: ProjectFieldMeta
        do {
            guard let loaded = try await loadFieldMeta(owner: owner, projectNumber: projectNumber, token: token) else {
                throw GitHubAPIError.invalidResponse
            }
            meta = loaded
        } catch {
            // Avoid orphan issues when project scope/meta is missing.
            var close = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/issues/\(issue.number)"))
            close.httpMethod = "PATCH"
            close.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            close.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            close.setValue("application/json", forHTTPHeaderField: "Content-Type")
            close.httpBody = try? JSONSerialization.data(withJSONObject: ["state": "closed"])
            _ = try? await transport.data(for: close)
            throw error
        }
        let addQuery = """
        mutation($projectId:ID!,$contentId:ID!){
          addProjectV2ItemById(input:{projectId:$projectId,contentId:$contentId}){ item { id } }
        }
        """
        let added = try await graphql(
            token: token,
            query: addQuery,
            variables: ["projectId": meta.projectId, "contentId": issue.node_id]
        )
        guard
            let root = try JSONSerialization.jsonObject(with: added) as? [String: Any],
            let itemId = (((root["data"] as? [String: Any])?["addProjectV2ItemById"] as? [String: Any])?["item"] as? [String: Any])?["id"] as? String
        else { throw GitHubAPIError.invalidResponse }

        let statusOpt = meta.statusOptions.first { key, _ in
            key == statusLabel || taskLane(status: key) == taskLane(status: statusLabel)
        }?.value
        try await updateTaskFields(
            projectId: meta.projectId,
            itemId: itemId,
            statusFieldId: meta.statusFieldId,
            statusOptionId: statusOpt,
            dueFieldId: meta.dueFieldId,
            dueOn: dueOn,
            token: token
        )
        return TaskCard(
            id: itemId,
            title: title,
            status: statusLabel,
            dueOn: dueOn,
            issueNumber: issue.number,
            contentId: issue.node_id
        )
    }

    public func updateTaskFields(
        projectId: String,
        itemId: String,
        statusFieldId: String?,
        statusOptionId: String?,
        dueFieldId: String?,
        dueOn: String?,
        token: String
    ) async throws {
        let mutation = """
        mutation($input:UpdateProjectV2ItemFieldValueInput!){
          updateProjectV2ItemFieldValue(input:$input){ projectV2Item { id } }
        }
        """
        if let statusFieldId, let statusOptionId {
            _ = try await graphql(
                token: token,
                query: mutation,
                variables: [
                    "input": [
                        "projectId": projectId,
                        "itemId": itemId,
                        "fieldId": statusFieldId,
                        "value": ["singleSelectOptionId": statusOptionId],
                    ],
                ]
            )
        }
        if let dueFieldId, let dueOn {
            _ = try await graphql(
                token: token,
                query: mutation,
                variables: [
                    "input": [
                        "projectId": projectId,
                        "itemId": itemId,
                        "fieldId": dueFieldId,
                        "value": ["date": dueOn],
                    ],
                ]
            )
        }
    }

    public func deleteTask(
        projectId: String,
        itemId: String,
        owner: String,
        repo: String,
        issueNumber: Int?,
        token: String
    ) async throws {
        let query = """
        mutation($input:DeleteProjectV2ItemInput!){
          deleteProjectV2Item(input:$input){ deletedItemId }
        }
        """
        _ = try await graphql(
            token: token,
            query: query,
            variables: ["input": ["projectId": projectId, "itemId": itemId]]
        )
        if let issueNumber {
            var request = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/issues/\(issueNumber)"))
            request.httpMethod = "PATCH"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["state": "closed"])
            let (_, response) = try await transport.data(for: request)
            guard (200..<300).contains(response.statusCode) else {
                throw GitHubAPIError.httpStatus(response.statusCode)
            }
        }
    }

    private func queryItems(kind: String, login: String, projectNumber: Int, token: String) async throws -> [TaskCard]? {
        let rootField = kind
        let query = """
        query($login:String!,$number:Int!){
          \(rootField)(login:$login){
            projectV2(number:$number){
              items(first:50){
                nodes{
                  id
                  content{ ... on Issue { title number id } }
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
        let data = try await graphql(token: token, query: query, variables: ["login": login, "number": projectNumber])
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObj = root["data"] as? [String: Any],
            let container = dataObj[rootField] as? [String: Any],
            let project = container["projectV2"] as? [String: Any],
            let items = (project["items"] as? [String: Any])?["nodes"] as? [[String: Any]]
        else { return nil }

        return items.compactMap { node in
            guard let id = node["id"] as? String else { return nil }
            let content = node["content"] as? [String: Any]
            let title = content?["title"] as? String ?? "(제목 없음)"
            let issueNumber = content?["number"] as? Int
            let contentId = content?["id"] as? String
            var status = "접수"
            var due: String?
            let fields = ((node["fieldValues"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            for field in fields {
                let fieldName = (field["field"] as? [String: Any])?["name"] as? String
                if fieldName == "Status", let name = field["name"] as? String { status = name }
                if isProjectsDueFieldName(fieldName), let date = field["date"] as? String { due = date }
            }
            return TaskCard(
                id: id,
                title: title,
                status: status,
                dueOn: due,
                issueNumber: issueNumber,
                contentId: contentId
            )
        }
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
