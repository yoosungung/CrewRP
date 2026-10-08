import Foundation

public struct CachedHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data
    public let etag: String?
    public let fromCache: Bool
}

public struct ETagRESTClient: Sendable {
    private let transport: any HTTPTransport
    private let cache: CacheStore

    public init(transport: any HTTPTransport, cache: CacheStore) {
        self.transport = transport
        self.cache = cache
    }

    public func get(url: URL, token: String) async throws -> CachedHTTPResponse {
        let key = url.absoluteString
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // Cache is best-effort — a corrupt/busy sqlite must not fail the network read.
        if let etag = try? cache.cacheEntry(url: key)?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await transport.data(for: request)
        if response.statusCode == 304, let cached = try? cache.cacheEntry(url: key) {
            return CachedHTTPResponse(
                statusCode: 304,
                body: Data(cached.body.utf8),
                etag: cached.etag,
                fromCache: true
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
        let etag = response.value(forHTTPHeaderField: "Etag") ?? response.value(forHTTPHeaderField: "ETag")
        let body = String(data: data, encoding: .utf8) ?? ""
        try? cache.putCacheEntry(url: key, body: body, etag: etag)
        return CachedHTTPResponse(statusCode: response.statusCode, body: data, etag: etag, fromCache: false)
    }
}

public struct DocFile: Sendable, Equatable {
    public let path: String
    public let content: String
    public let sha: String?

    public init(path: String, content: String, sha: String? = nil) {
        self.path = path
        self.content = content
        self.sha = sha
    }
}

public struct DocEntry: Sendable, Equatable {
    public let path: String
    public let name: String
    public let sha: String?
    public let isDir: Bool
}

public struct DocsClient: Sendable {
    private let transport: any HTTPTransport
    private let rest: ETagRESTClient
    private let apiBase: URL

    public init(transport: any HTTPTransport, cache: CacheStore, apiBase: URL = URL(string: "https://api.github.com")!) {
        self.transport = transport
        self.rest = ETagRESTClient(transport: transport, cache: cache)
        self.apiBase = apiBase
    }

    public func listDocs(owner: String, repo: String, token: String, path: String = "docs") async throws -> [DocEntry] {
        let url = apiBase.appending(path: "repos/\(owner)/\(repo)/contents/\(path)")
        let response: CachedHTTPResponse
        do {
            response = try await rest.get(url: url, token: token)
        } catch {
            if case GitHubAPIError.httpStatus(404) = error { return [] }
            throw error
        }
        struct Entry: Decodable {
            let path: String
            let name: String
            let sha: String?
            let type: String
        }
        // Contents API may return a single file object; treat non-array as empty listing.
        guard let entries = try? JSONDecoder().decode([Entry].self, from: response.body) else { return [] }
        return entries.map { DocEntry(path: $0.path, name: $0.name, sha: $0.sha, isDir: $0.type == "dir") }
    }

    public func fetchMarkdown(owner: String, repo: String, path: String, token: String) async throws -> DocFile {
        let url = apiBase.appending(path: "repos/\(owner)/\(repo)/contents/\(path)")
        let response = try await rest.get(url: url, token: token)
        struct ContentDTO: Decodable {
            let path: String
            let content: String?
            let encoding: String?
            let sha: String?
        }
        let dto = try JSONDecoder().decode(ContentDTO.self, from: response.body)
        guard dto.encoding == "base64", let raw = dto.content else {
            throw GitHubAPIError.invalidResponse
        }
        let cleaned = raw.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned), let text = String(data: data, encoding: .utf8) else {
            throw GitHubAPIError.invalidResponse
        }
        return DocFile(path: dto.path, content: text, sha: dto.sha)
    }

    public func saveMarkdown(owner: String, repo: String, path: String, content: String, token: String, sha: String?) async throws -> DocFile {
        guard path.hasPrefix("docs/") else { throw GitHubAPIError.invalidResponse }
        var request = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/contents/\(path)"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoded = Data(content.utf8).base64EncodedString()
        var payload: [String: Any] = ["message": "자료 저장", "content": encoded]
        if let sha { payload["sha"] = sha }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
        struct Envelope: Decodable {
            struct Content: Decodable { let sha: String? }
            let content: Content
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return DocFile(path: path, content: content, sha: env.content.sha)
    }

    public func deleteDoc(owner: String, repo: String, path: String, sha: String, token: String) async throws {
        guard path.hasPrefix("docs/") else { throw GitHubAPIError.invalidResponse }
        var request = URLRequest(url: apiBase.appending(path: "repos/\(owner)/\(repo)/contents/\(path)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["message": "자료 삭제", "sha": sha])
        let (_, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
    }
}
