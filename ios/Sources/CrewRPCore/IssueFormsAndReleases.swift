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

public struct AttachmentEntry: Sendable, Equatable, Identifiable, Codable {
    public let id: Int
    public let name: String
    public let contentType: String?
    public let size: Int
    public let browserDownloadURL: URL
    public let apiURL: URL

    public init(
        id: Int,
        name: String,
        contentType: String? = nil,
        size: Int,
        browserDownloadURL: URL,
        apiURL: URL
    ) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.size = size
        self.browserDownloadURL = browserDownloadURL
        self.apiURL = apiURL
    }

    /// 인앱 미리보기(QuickLook / Intent)에 적합한 타입.
    public var isPreviewable: Bool {
        attachmentIsPreviewable(name: name, contentType: contentType)
    }
}

public enum DocsLibraryItem: Sendable, Equatable, Identifiable {
    case doc(DocEntry)
    case attachment(AttachmentEntry)

    public var id: String {
        switch self {
        case .doc(let e): return "doc:\(e.path)"
        case .attachment(let e): return "att:\(e.id)"
        }
    }

    public var name: String {
        switch self {
        case .doc(let e): return e.name
        case .attachment(let e): return e.name
        }
    }
}

public func attachmentIsPreviewable(name: String, contentType: String?) -> Bool {
    let lower = name.lowercased()
    if lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
        || lower.hasSuffix(".gif") || lower.hasSuffix(".webp") || lower.hasSuffix(".pdf")
        || lower.hasSuffix(".heic")
    {
        return true
    }
    guard let ct = contentType?.lowercased() else { return false }
    return ct.hasPrefix("image/") || ct == "application/pdf"
}

public struct ReleaseAssetClient: Sendable {
    private let transport: any HTTPTransport
    private let apiBase: URL
    private let uploadsBase: URL

    public init(
        transport: any HTTPTransport,
        apiBase: URL = URL(string: "https://api.github.com")!,
        uploadsBase: URL = URL(string: "https://uploads.github.com")!
    ) {
        self.transport = transport
        self.apiBase = apiBase
        self.uploadsBase = uploadsBase
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
        create.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
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

    public func listAssets(
        owner: String,
        repo: String,
        releaseId: Int,
        token: String
    ) async throws -> [AttachmentEntry] {
        var req = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/releases/\(releaseId)/assets"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.data(for: req)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
        return try Self.decodeAssets(data)
    }

    /// 첨부 Release를 보장한 뒤 asset 목록을 반환한다.
    public func listAttachments(
        owner: String,
        repo: String,
        token: String,
        tag: String = "crewrp-attachments"
    ) async throws -> [AttachmentEntry] {
        let releaseId = try await ensureAttachmentRelease(owner: owner, repo: repo, token: token, tag: tag)
        return try await listAssets(owner: owner, repo: repo, releaseId: releaseId, token: token)
    }

    public func upload(
        owner: String,
        repo: String,
        releaseId: Int,
        name: String,
        bytes: Data,
        contentType: String,
        token: String
    ) async throws -> AttachmentEntry {
        var components = URLComponents(
            url: uploadsBase.appending(path: "repos/\(owner)/\(repo)/releases/\(releaseId)/assets"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.httpBody = bytes
        let (data, response) = try await transport.data(for: req)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
        return try Self.decodeAsset(data)
    }

    public func uploadAttachment(
        owner: String,
        repo: String,
        name: String,
        bytes: Data,
        contentType: String,
        token: String,
        tag: String = "crewrp-attachments"
    ) async throws -> AttachmentEntry {
        let releaseId = try await ensureAttachmentRelease(owner: owner, repo: repo, token: token, tag: tag)
        return try await upload(
            owner: owner,
            repo: repo,
            releaseId: releaseId,
            name: name,
            bytes: bytes,
            contentType: contentType,
            token: token
        )
    }

    /// Private asset 바이트 다운로드 (`Accept: application/octet-stream`).
    public func downloadBytes(asset: AttachmentEntry, token: String) async throws -> Data {
        var req = URLRequest(url: asset.apiURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.data(for: req)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
        return data
    }

    private static func decodeAssets(_ data: Data) throws -> [AttachmentEntry] {
        try JSONDecoder().decode([AssetDTO].self, from: data).map { $0.asEntry() }
    }

    private static func decodeAsset(_ data: Data) throws -> AttachmentEntry {
        try JSONDecoder().decode(AssetDTO.self, from: data).asEntry()
    }

    private struct AssetDTO: Decodable {
        let id: Int
        let name: String
        let content_type: String?
        let size: Int
        let browser_download_url: URL
        let url: URL

        func asEntry() -> AttachmentEntry {
            AttachmentEntry(
                id: id,
                name: name,
                contentType: content_type,
                size: size,
                browserDownloadURL: browser_download_url,
                apiURL: url
            )
        }
    }
}
