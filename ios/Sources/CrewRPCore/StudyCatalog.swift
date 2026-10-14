import Foundation

public struct StudySubject: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct StudyCourseSummary: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct RecentStudyEntry: Sendable, Equatable, Codable {
    public var subjectId: String
    public var courseId: String
    public var title: String
    public var openedAtEpochSec: Int64

    public init(subjectId: String, courseId: String, title: String, openedAtEpochSec: Int64) {
        self.subjectId = subjectId
        self.courseId = courseId
        self.title = title
        self.openedAtEpochSec = openedAtEpochSec
    }
}

public let studyRoot = ".crewrp/study"
public let recentStudyCacheKey = "crewrp://study/recent"
public let recentStudyMax = 10

public func subjectsPath() -> String { "\(studyRoot)/subjects.json" }
public func coursesPath(subjectId: String) -> String { "\(studyRoot)/\(subjectId)/courses.json" }
public func courseAssetPath(subjectId: String, courseId: String) -> String {
    "\(studyRoot)/\(subjectId)/\(courseId)/course.json"
}
public func conceptsPath(subjectId: String, courseId: String) -> String {
    "\(studyRoot)/\(subjectId)/\(courseId)/concepts.json"
}

public func parseSubjectsJSON(_ json: String) throws -> [StudySubject] {
    guard let data = json.data(using: .utf8) else { return [] }
    return try JSONDecoder().decode([StudySubject].self, from: data)
}

public func subjectsJSON(_ subjects: [StudySubject]) throws -> String {
    let data = try JSONEncoder().encode(subjects)
    return (String(data: data, encoding: .utf8) ?? "[]") + "\n"
}

public func parseCourseSummariesJSON(_ json: String) throws -> [StudyCourseSummary] {
    guard let data = json.data(using: .utf8) else { return [] }
    return try JSONDecoder().decode([StudyCourseSummary].self, from: data)
}

public func courseSummariesJSON(_ courses: [StudyCourseSummary]) throws -> String {
    let data = try JSONEncoder().encode(courses)
    return (String(data: data, encoding: .utf8) ?? "[]") + "\n"
}

public func loadRecentStudy(cache: CacheStore) -> [RecentStudyEntry] {
    guard let body = try? cache.cacheEntry(url: recentStudyCacheKey)?.body,
          let data = body.data(using: .utf8),
          let entries = try? JSONDecoder().decode([RecentStudyEntry].self, from: data) else {
        return []
    }
    return entries
}

@discardableResult
public func recordRecentStudy(
    cache: CacheStore,
    entry: RecentStudyEntry,
    max: Int = recentStudyMax
) throws -> [RecentStudyEntry] {
    let next = [entry] + loadRecentStudy(cache: cache).filter {
        !($0.subjectId == entry.subjectId && $0.courseId == entry.courseId)
    }
    let trimmed = Array(next.prefix(max))
    let data = try JSONEncoder().encode(trimmed)
    let body = String(data: data, encoding: .utf8) ?? "[]"
    try cache.putCacheEntry(url: recentStudyCacheKey, body: body, etag: nil)
    return trimmed
}

public struct StudyCatalogClient: Sendable {
    public var transport: any HTTPTransport
    public var apiBase: URL

    public init(transport: any HTTPTransport, apiBase: URL = URL(string: "https://api.github.com")!) {
        self.transport = transport
        self.apiBase = apiBase
    }

    public func fetchText(owner: String, repo: String, path: String, token: String) async throws -> (String, String?)? {
        let url = apiBase.appending(path: "repos/\(owner)/\(repo)/contents/\(path)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, http) = try await transport.data(for: request)
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct DTO: Decodable {
            var content: String?
            var encoding: String?
            var sha: String?
        }
        let dto = try JSONDecoder().decode(DTO.self, from: data)
        guard dto.encoding == "base64", let content = dto.content else {
            throw URLError(.cannotParseResponse)
        }
        let cleaned = content.replacingOccurrences(of: "\n", with: "")
        guard let decoded = Data(base64Encoded: cleaned),
              let text = String(data: decoded, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return (text, dto.sha)
    }

    public func putText(
        owner: String,
        repo: String,
        path: String,
        content: String,
        token: String,
        sha: String?,
        message: String = "학습 저장"
    ) async throws -> String? {
        guard path.hasPrefix("\(studyRoot)/") else {
            throw URLError(.unsupportedURL)
        }
        let encoded = Data(content.utf8).base64EncodedString()
        var payload: [String: Any] = ["message": message, "content": encoded]
        if let sha { payload["sha"] = sha }
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        let url = apiBase.appending(path: "repos/\(owner)/\(repo)/contents/\(path)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.httpBody = bodyData
        let (data, http) = try await transport.data(for: request)
        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        struct Resp: Decodable {
            struct Content: Decodable { var sha: String? }
            var content: Content?
        }
        return try? JSONDecoder().decode(Resp.self, from: data).content?.sha
    }

    public func listSubjects(owner: String, repo: String, token: String) async throws -> [StudySubject] {
        guard let text = try await fetchText(owner: owner, repo: repo, path: subjectsPath(), token: token)?.0 else {
            return []
        }
        return try parseSubjectsJSON(text)
    }

    public func listCourses(owner: String, repo: String, subjectId: String, token: String) async throws -> [StudyCourseSummary] {
        guard let text = try await fetchText(
            owner: owner,
            repo: repo,
            path: coursesPath(subjectId: subjectId),
            token: token
        )?.0 else {
            return []
        }
        return try parseCourseSummariesJSON(text)
    }

    public func loadCourseAsset(
        owner: String,
        repo: String,
        subjectId: String,
        courseId: String,
        token: String
    ) async throws -> CourseAsset? {
        guard let text = try await fetchText(
            owner: owner,
            repo: repo,
            path: courseAssetPath(subjectId: subjectId, courseId: courseId),
            token: token
        )?.0 else {
            return nil
        }
        return try CourseAsset.parse(text)
    }
}
