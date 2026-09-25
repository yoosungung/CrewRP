import Foundation

public struct Organization: Sendable, Equatable, Codable {
    public let login: String
    public let id: Int
}

public struct Team: Sendable, Equatable, Codable {
    public let slug: String
    public let id: Int
    public let name: String
}

public enum GitHubAPIError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
}

public struct GitHubMembershipClient: Sendable {
    private let transport: any HTTPTransport
    private let apiBase: URL

    public init(transport: any HTTPTransport, apiBase: URL = URL(string: "https://api.github.com")!) {
        self.transport = transport
        self.apiBase = apiBase
    }

    public func listOrganizations(token: String) async throws -> [Organization] {
        try await get(path: "user/orgs", token: token)
    }

    public func listTeamsForOrg(org: String, token: String) async throws -> [Team] {
        struct TeamDTO: Decodable {
            let id: Int
            let slug: String
            let name: String
            let organization: OrgLogin
            struct OrgLogin: Decodable { let login: String }
        }
        let dtos: [TeamDTO] = try await get(path: "user/teams", token: token)
        return dtos
            .filter { $0.organization.login.caseInsensitiveCompare(org) == .orderedSame }
            .map { Team(slug: $0.slug, id: $0.id, name: $0.name) }
    }

    public func resolveRole(org: String, token: String) async throws -> TeamRole {
        let teams = try await listTeamsForOrg(org: org, token: token)
        return TeamRole.resolve(slugs: teams.map(\.slug))
    }

    private func get<T: Decodable>(path: String, token: String) async throws -> [T] {
        var request = URLRequest(url: apiBase.appending(path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
        return try JSONDecoder().decode([T].self, from: data)
    }
}
