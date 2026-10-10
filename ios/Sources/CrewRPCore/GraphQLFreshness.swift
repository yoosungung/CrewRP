import Foundation

/// ARCHITECTURE §5 — GraphQL has no ETag; skip network when `graphql_cursor.updated_at` is fresh.
/// Response bodies live in `cache_entry` under `graphql:<queryName>`.
public enum GraphQLFreshness {
    public static let ttl: TimeInterval = 60

    public static func cacheURL(queryName: String) -> String {
        "graphql:\(queryName)"
    }

    public static func listTasksQueryName(org: String, projectNumber: Int) -> String {
        "listTasks:\(org):\(projectNumber)"
    }

    public static func listNoticesQueryName(owner: String, repo: String) -> String {
        "listNotices:\(owner)/\(repo)"
    }

    public static func listDiscussionsQueryName(owner: String, repo: String, categoryId: String) -> String {
        "listDiscussions:\(owner)/\(repo):\(categoryId)"
    }

    public static func listCategoriesQueryName(owner: String, repo: String) -> String {
        "listCategories:\(owner)/\(repo)"
    }

    public static func docsTreeQueryName(owner: String, repo: String) -> String {
        "docsTree:\(owner)/\(repo)"
    }

    public static func freshBody(
        cache: CacheStore,
        queryName: String,
        now: Date = Date()
    ) -> Data? {
        guard
            let row = try? cache.graphQLCursor(queryName: queryName),
            now.timeIntervalSince(row.updatedAt) < ttl,
            let entry = try? cache.cacheEntry(url: cacheURL(queryName: queryName))
        else { return nil }
        return Data(entry.body.utf8)
    }

    public static func cachedBody(cache: CacheStore, queryName: String) -> Data? {
        guard let entry = try? cache.cacheEntry(url: cacheURL(queryName: queryName)) else { return nil }
        return Data(entry.body.utf8)
    }

    public static func storedCursor(cache: CacheStore, queryName: String) -> String? {
        try? cache.graphQLCursor(queryName: queryName)?.cursor
    }

    public static func store(
        cache: CacheStore,
        queryName: String,
        body: Data,
        cursor: String? = nil,
        now: Date = Date()
    ) {
        let text = String(data: body, encoding: .utf8) ?? ""
        try? cache.putCacheEntry(
            url: cacheURL(queryName: queryName),
            body: text,
            etag: nil,
            fetchedAt: now
        )
        try? cache.putGraphQLCursor(queryName: queryName, cursor: cursor, updatedAt: now)
    }
}
