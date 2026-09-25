import Foundation

public struct Organization: Sendable, Equatable, Codable {
    public let login: String
    public let id: Int

    public init(login: String, id: Int) {
        self.login = login
        self.id = id
    }
}

public struct CrewRepo: Sendable, Equatable, Codable, Identifiable {
    public var id: String { fullName }
    public let owner: String
    public let name: String
    public let fullName: String
    public let isPrivate: Bool

    public init(owner: String, name: String, fullName: String, isPrivate: Bool) {
        self.owner = owner
        self.name = name
        self.fullName = fullName
        self.isPrivate = isPrivate
    }
}

public struct Team: Sendable, Equatable, Codable {
    public let slug: String
    public let id: Int
    public let name: String
}

public struct GitHubUser: Sendable, Equatable, Codable {
    public let login: String
    public let id: Int
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

    public func currentUser(token: String) async throws -> GitHubUser {
        var request = URLRequest(url: apiBase.appending(path: "user"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
        return try JSONDecoder().decode(GitHubUser.self, from: data)
    }

    public func listOrganizations(token: String) async throws -> [Organization] {
        try await get(path: "user/orgs", token: token)
    }

    /// Private repositories the user can administer — candidates to register as a crew.
    public func listRegistrableRepos(token: String) async throws -> [CrewRepo] {
        struct RepoDTO: Decodable {
            let name: String
            let fullName: String
            let isPrivate: Bool
            let permissions: Perms?
            let owner: Owner
            struct Perms: Decodable { let admin: Bool? }
            struct Owner: Decodable { let login: String }

            enum CodingKeys: String, CodingKey {
                case name
                case fullName = "full_name"
                case isPrivate = "private"
                case permissions
                case owner
            }
        }
        let dtos: [RepoDTO] = try await get(path: "user/repos?per_page=100&affiliation=owner,organization_member", token: token)
        return dtos
            .filter { $0.isPrivate && ($0.permissions?.admin == true) }
            .map {
                CrewRepo(owner: $0.owner.login, name: $0.name, fullName: $0.fullName, isPrivate: $0.isPrivate)
            }
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

    public func resolveRole(owner: String, token: String, isRepoAdmin: Bool) async throws -> TeamRole {
        let teams = try await listTeamsForOrg(org: owner, token: token)
        let fromTeams = TeamRole.resolve(slugs: teams.map(\.slug))
        if fromTeams != .none { return fromTeams }
        return isRepoAdmin ? .admin : .none
    }

    private func get<T: Decodable>(path: String, token: String) async throws -> [T] {
        let url: URL
        if path.contains("?") {
            url = URL(string: apiBase.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path)!
        } else {
            url = apiBase.appending(path: path)
        }
        var request = URLRequest(url: url)
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
