package app.crewrp.core

import java.time.Duration
import java.time.Instant

/** ARCHITECTURE §5 — GraphQL has no ETag; skip network when `graphql_cursor.updated_at` is fresh. */
object GraphQLFreshness {
    val ttl: Duration = Duration.ofSeconds(60)

    fun cacheURL(queryName: String): String = "graphql:$queryName"

    fun listTasksQueryName(org: String, projectNumber: Int): String =
        "listTasks:$org:$projectNumber"

    fun listNoticesQueryName(owner: String, repo: String): String =
        "listNotices:$owner/$repo"

    fun docsTreeQueryName(owner: String, repo: String): String =
        "docsTree:$owner/$repo"

    fun freshBody(cache: CacheStore, queryName: String, now: Instant = Instant.now()): String? {
        val row = cache.graphQLCursor(queryName) ?: return null
        if (Duration.between(row.updatedAt, now) >= ttl) return null
        return cache.cacheEntry(cacheURL(queryName))?.body
    }

    fun cachedBody(cache: CacheStore, queryName: String): String? =
        cache.cacheEntry(cacheURL(queryName))?.body

    fun storedCursor(cache: CacheStore, queryName: String): String? =
        cache.graphQLCursor(queryName)?.cursor

    fun store(
        cache: CacheStore,
        queryName: String,
        body: String,
        now: Instant = Instant.now(),
        cursor: String? = null,
    ) {
        runCatching {
            cache.putCacheEntry(cacheURL(queryName), body, null, now)
            cache.putGraphQLCursor(queryName, cursor, now)
        }
    }
}
