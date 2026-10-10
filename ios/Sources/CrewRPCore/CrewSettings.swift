import Foundation

public struct CrewDiscordSettings: Sendable, Equatable, Codable {
    public var serverId: String
    public var channelId: String

    public init(serverId: String, channelId: String) {
        self.serverId = serverId
        self.channelId = channelId
    }

    public var isConfigured: Bool {
        discordConfigured(serverId: serverId, channelId: channelId)
    }
}

public struct CrewSettings: Sendable, Equatable, Codable {
    public var discord: CrewDiscordSettings?

    public init(discord: CrewDiscordSettings? = nil) {
        self.discord = discord
    }
}

public struct CrewSettingsFile: Sendable, Equatable {
    public let settings: CrewSettings
    public let sha: String?

    public init(settings: CrewSettings, sha: String?) {
        self.settings = settings
        self.sha = sha
    }
}

public enum CrewSettingsPaths {
    public static let file = ".crewrp/settings.json"
}

public struct CrewSettingsClient: Sendable {
    private let transport: any HTTPTransport
    private let cache: CacheStore
    private let rest: ETagRESTClient
    private let apiBase: URL

    public init(transport: any HTTPTransport, cache: CacheStore, apiBase: URL = URL(string: "https://api.github.com")!) {
        self.transport = transport
        self.cache = cache
        self.rest = ETagRESTClient(transport: transport, cache: cache)
        self.apiBase = apiBase
    }

    public func load(owner: String, repo: String, token: String) async throws -> CrewSettingsFile? {
        let url = apiBase.appending(path: "repos/\(owner)/\(repo)/contents/\(CrewSettingsPaths.file)")
        let response: CachedHTTPResponse
        do {
            response = try await rest.get(url: url, token: token)
        } catch {
            if case GitHubAPIError.httpStatus(404) = error { return nil }
            throw error
        }
        struct ContentDTO: Decodable {
            let content: String?
            let encoding: String?
            let sha: String?
        }
        let dto = try JSONDecoder().decode(ContentDTO.self, from: response.body)
        guard dto.encoding == "base64", let raw = dto.content else {
            throw GitHubAPIError.invalidResponse
        }
        let cleaned = raw.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned) else {
            throw GitHubAPIError.invalidResponse
        }
        let settings = try JSONDecoder().decode(CrewSettings.self, from: data)
        return CrewSettingsFile(settings: settings, sha: dto.sha)
    }

    public func save(
        owner: String,
        repo: String,
        token: String,
        settings: CrewSettings,
        sha: String?
    ) async throws -> CrewSettingsFile {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(settings)
        let encoded = json.base64EncodedString()
        var request = URLRequest(
            url: apiBase.appending(path: "repos/\(owner)/\(repo)/contents/\(CrewSettingsPaths.file)")
        )
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "message": "크루 설정 저장",
            "content": encoded,
        ]
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
        return CrewSettingsFile(settings: settings, sha: env.content.sha)
    }
}
