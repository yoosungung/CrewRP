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
        if let etag = try cache.cacheEntry(url: key)?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await transport.data(for: request)
        if response.statusCode == 304, let cached = try cache.cacheEntry(url: key) {
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
        try cache.putCacheEntry(url: key, body: body, etag: etag)
        return CachedHTTPResponse(statusCode: response.statusCode, body: data, etag: etag, fromCache: false)
    }
}

public struct DocFile: Sendable, Equatable {
    public let path: String
    public let content: String
}

public struct DocsClient: Sendable {
    private let rest: ETagRESTClient
    private let apiBase: URL

    public init(rest: ETagRESTClient, apiBase: URL = URL(string: "https://api.github.com")!) {
        self.rest = rest
        self.apiBase = apiBase
    }

    public func fetchMarkdown(owner: String, repo: String, path: String, token: String) async throws -> DocFile {
        let url = apiBase.appending(path: "repos/\(owner)/\(repo)/contents/\(path)")
        let response = try await rest.get(url: url, token: token)
        struct ContentDTO: Decodable {
            let path: String
            let content: String?
            let encoding: String?
        }
        let dto = try JSONDecoder().decode(ContentDTO.self, from: response.body)
        guard dto.encoding == "base64", let raw = dto.content else {
            throw GitHubAPIError.invalidResponse
        }
        let cleaned = raw.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned), let text = String(data: data, encoding: .utf8) else {
            throw GitHubAPIError.invalidResponse
        }
        return DocFile(path: dto.path, content: text)
    }
}
