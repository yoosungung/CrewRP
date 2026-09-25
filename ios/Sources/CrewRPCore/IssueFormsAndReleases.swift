import Foundation

public struct FormField: Sendable, Equatable {
    public let id: String
    public let label: String
    public let required: Bool
    public let type: String
}

public struct IssueFormTemplate: Sendable, Equatable {
    public let name: String
    public let fields: [FormField]
}

public struct IssueFormsClient: Sendable {
    private let rest: ETagRESTClient
    private let transport: any HTTPTransport
    private let apiBase: URL

    public init(
        rest: ETagRESTClient,
        transport: any HTTPTransport,
        apiBase: URL = URL(string: "https://api.github.com")!
    ) {
        self.rest = rest
        self.transport = transport
        self.apiBase = apiBase
    }

    public func loadTemplate(owner: String, repo: String, fileName: String, token: String) async throws -> IssueFormTemplate {
        let url = apiBase.appending(path: "repos/\(owner)/\(repo)/contents/.github/ISSUE_TEMPLATE/\(fileName)")
        let response = try await rest.get(url: url, token: token)
        struct ContentDTO: Decodable {
            let content: String?
            let encoding: String?
        }
        let dto = try JSONDecoder().decode(ContentDTO.self, from: response.body)
        guard dto.encoding == "base64", let raw = dto.content,
              let data = Data(base64Encoded: raw.replacingOccurrences(of: "\n", with: "")),
              let yaml = String(data: data, encoding: .utf8) else {
            throw GitHubAPIError.invalidResponse
        }
        return IssueFormParser.parse(yaml)
    }

    public func createIssue(
        owner: String,
        repo: String,
        title: String,
        body: String,
        token: String
    ) async throws -> Int {
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
        struct IssueDTO: Decodable { let number: Int }
        return try JSONDecoder().decode(IssueDTO.self, from: data).number
    }
}

enum IssueFormParser {
    static func parse(_ yaml: String) -> IssueFormTemplate {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var name = "서식"
        var fields: [FormField] = []
        var currentId: String?
        var currentLabel: String?
        var currentType = "input"
        var currentRequired = false

        func flush() {
            if let id = currentId, let label = currentLabel {
                fields.append(FormField(id: id, label: label, required: currentRequired, type: currentType))
            }
            currentId = nil
            currentLabel = nil
            currentType = "input"
            currentRequired = false
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name:") {
                name = trimmed
                    .replacingOccurrences(of: "name:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("- type:") {
                flush()
                currentType = trimmed.replacingOccurrences(of: "- type:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("id:") {
                currentId = trimmed.replacingOccurrences(of: "id:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("label:") {
                currentLabel = trimmed
                    .replacingOccurrences(of: "label:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("required:") {
                currentRequired = trimmed.contains("true")
            }
        }
        flush()
        return IssueFormTemplate(name: name, fields: fields)
    }
}

public struct ReleaseAssetClient: Sendable {
    private let transport: any HTTPTransport
    private let apiBase: URL

    public init(transport: any HTTPTransport, apiBase: URL = URL(string: "https://api.github.com")!) {
        self.transport = transport
        self.apiBase = apiBase
    }

    public func ensureAttachmentRelease(
        owner: String,
        repo: String,
        token: String,
        tag: String = "crewrp-attachments"
    ) async throws -> Int {
        var get = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/releases/tags/\(tag)"))
        get.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        get.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.data(for: get)
        if response.statusCode == 200 {
            struct Rel: Decodable { let id: Int }
            return try JSONDecoder().decode(Rel.self, from: data).id
        }
        var create = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/releases"))
        create.httpMethod = "POST"
        create.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: [
            "tag_name": tag,
            "name": "CrewRP Attachments",
            "draft": false,
            "prerelease": true,
        ])
        let (created, createResponse) = try await transport.data(for: create)
        guard (200..<300).contains(createResponse.statusCode) else {
            throw GitHubAPIError.httpStatus(createResponse.statusCode)
        }
        struct Rel: Decodable { let id: Int }
        return try JSONDecoder().decode(Rel.self, from: created).id
    }
}
