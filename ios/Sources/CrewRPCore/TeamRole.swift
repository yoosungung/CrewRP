public enum TeamRole: String, Sendable, Equatable, Codable {
    case admin
    case member
    case none

    public static let adminSlug = "admins"
    public static let memberSlug = "members"

    public static func resolve(slugs: [String]) -> TeamRole {
        let set = Set(slugs)
        if set.contains(adminSlug) { return .admin }
        if set.contains(memberSlug) { return .member }
        return .none
    }

    public var canEdit: Bool { self == .admin }
}

public struct Session: Sendable, Equatable, Codable {
    public var org: String
    public var repo: String
    public var teamRole: TeamRole

    public init(org: String, repo: String, teamRole: TeamRole) {
        self.org = org
        self.repo = repo
        self.teamRole = teamRole
    }
}
