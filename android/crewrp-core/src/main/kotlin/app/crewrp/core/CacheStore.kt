package app.crewrp.core

import java.sql.DriverManager
import java.time.Instant

data class CacheEntry(
    val url: String,
    val body: String,
    val etag: String?,
    val fetchedAt: Instant,
)

data class GraphQLCursorRow(
    val queryName: String,
    val cursor: String?,
    val updatedAt: Instant,
)

data class AccountLink(
    val provider: String,
    val userId: String,
    val username: String,
    val linkedAt: Instant = Instant.now(),
) {
    companion object {
        const val DISCORD = "discord"
    }
}

interface CacheStore : AutoCloseable {
    fun putCacheEntry(url: String, body: String, etag: String?, fetchedAt: Instant = Instant.now())
    fun cacheEntry(url: String): CacheEntry?
    fun putGraphQLCursor(queryName: String, cursor: String?, updatedAt: Instant)
    fun graphQLCursor(queryName: String): GraphQLCursorRow?
    fun putSession(session: Session)
    fun session(): Session?
    fun clearSession()
    fun putAccountLink(link: AccountLink)
    fun accountLink(provider: String): AccountLink?
    fun clearAccountLink(provider: String)
    fun clearAllAccountLinks()
}

/** JVM / unit-test store (sqlite-jdbc). Not for Android runtime. */
class JdbcCacheStore(path: String) : CacheStore {
    private val connection = DriverManager.getConnection("jdbc:sqlite:$path").also { conn ->
        conn.createStatement().use { st ->
            st.execute(
                """
                CREATE TABLE IF NOT EXISTS cache_entry (
                  url TEXT PRIMARY KEY NOT NULL,
                  body TEXT NOT NULL,
                  etag TEXT,
                  fetched_at REAL NOT NULL
                );
                """.trimIndent(),
            )
            st.execute(
                """
                CREATE TABLE IF NOT EXISTS graphql_cursor (
                  query_name TEXT PRIMARY KEY NOT NULL,
                  cursor TEXT,
                  updated_at REAL NOT NULL
                );
                """.trimIndent(),
            )
            st.execute(
                """
                CREATE TABLE IF NOT EXISTS session (
                  id INTEGER PRIMARY KEY CHECK (id = 1),
                  org TEXT NOT NULL,
                  repo TEXT NOT NULL,
                  team_role TEXT NOT NULL
                );
                """.trimIndent(),
            )
            st.execute(
                """
                CREATE TABLE IF NOT EXISTS account_link (
                  provider TEXT PRIMARY KEY NOT NULL,
                  user_id TEXT NOT NULL,
                  username TEXT NOT NULL,
                  linked_at REAL NOT NULL
                );
                """.trimIndent(),
            )
        }
    }

    override fun putCacheEntry(url: String, body: String, etag: String?, fetchedAt: Instant) {
        connection.prepareStatement(
            "INSERT OR REPLACE INTO cache_entry(url, body, etag, fetched_at) VALUES (?, ?, ?, ?)",
        ).use { ps ->
            ps.setString(1, url)
            ps.setString(2, body)
            if (etag == null) ps.setNull(3, java.sql.Types.VARCHAR) else ps.setString(3, etag)
            ps.setDouble(4, fetchedAt.epochSecond.toDouble())
            ps.executeUpdate()
        }
    }

    override fun cacheEntry(url: String): CacheEntry? {
        connection.prepareStatement(
            "SELECT url, body, etag, fetched_at FROM cache_entry WHERE url = ?",
        ).use { ps ->
            ps.setString(1, url)
            ps.executeQuery().use { rs ->
                if (!rs.next()) return null
                return CacheEntry(
                    url = rs.getString(1),
                    body = rs.getString(2),
                    etag = rs.getString(3),
                    fetchedAt = Instant.ofEpochSecond(rs.getDouble(4).toLong()),
                )
            }
        }
    }

    override fun putGraphQLCursor(queryName: String, cursor: String?, updatedAt: Instant) {
        connection.prepareStatement(
            "INSERT OR REPLACE INTO graphql_cursor(query_name, cursor, updated_at) VALUES (?, ?, ?)",
        ).use { ps ->
            ps.setString(1, queryName)
            if (cursor == null) ps.setNull(2, java.sql.Types.VARCHAR) else ps.setString(2, cursor)
            ps.setDouble(3, updatedAt.epochSecond.toDouble())
            ps.executeUpdate()
        }
    }

    override fun graphQLCursor(queryName: String): GraphQLCursorRow? {
        connection.prepareStatement(
            "SELECT query_name, cursor, updated_at FROM graphql_cursor WHERE query_name = ?",
        ).use { ps ->
            ps.setString(1, queryName)
            ps.executeQuery().use { rs ->
                if (!rs.next()) return null
                return GraphQLCursorRow(
                    queryName = rs.getString(1),
                    cursor = rs.getString(2),
                    updatedAt = Instant.ofEpochSecond(rs.getDouble(3).toLong()),
                )
            }
        }
    }

    override fun putSession(session: Session) {
        connection.prepareStatement(
            "INSERT OR REPLACE INTO session(id, org, repo, team_role) VALUES (1, ?, ?, ?)",
        ).use { ps ->
            ps.setString(1, session.org)
            ps.setString(2, session.repo)
            ps.setString(3, session.teamRole.name.lowercase())
            ps.executeUpdate()
        }
    }

    override fun session(): Session? {
        connection.prepareStatement(
            "SELECT org, repo, team_role FROM session WHERE id = 1",
        ).use { ps ->
            ps.executeQuery().use { rs ->
                if (!rs.next()) return null
                val role = when (rs.getString(3)) {
                    "admin" -> TeamRole.ADMIN
                    "member" -> TeamRole.MEMBER
                    else -> TeamRole.NONE
                }
                return Session(rs.getString(1), rs.getString(2), role)
            }
        }
    }

    override fun clearSession() {
        connection.prepareStatement("DELETE FROM session WHERE id = 1").use { it.executeUpdate() }
    }

    override fun putAccountLink(link: AccountLink) {
        connection.prepareStatement(
            "INSERT OR REPLACE INTO account_link(provider, user_id, username, linked_at) VALUES (?, ?, ?, ?)",
        ).use { ps ->
            ps.setString(1, link.provider)
            ps.setString(2, link.userId)
            ps.setString(3, link.username)
            ps.setDouble(4, link.linkedAt.epochSecond.toDouble())
            ps.executeUpdate()
        }
    }

    override fun accountLink(provider: String): AccountLink? {
        connection.prepareStatement(
            "SELECT provider, user_id, username, linked_at FROM account_link WHERE provider = ?",
        ).use { ps ->
            ps.setString(1, provider)
            ps.executeQuery().use { rs ->
                if (!rs.next()) return null
                return AccountLink(
                    provider = rs.getString(1),
                    userId = rs.getString(2),
                    username = rs.getString(3),
                    linkedAt = Instant.ofEpochSecond(rs.getDouble(4).toLong()),
                )
            }
        }
    }

    override fun clearAccountLink(provider: String) {
        connection.prepareStatement("DELETE FROM account_link WHERE provider = ?").use { ps ->
            ps.setString(1, provider)
            ps.executeUpdate()
        }
    }

    override fun clearAllAccountLinks() {
        connection.prepareStatement("DELETE FROM account_link").use { it.executeUpdate() }
    }

    override fun close() {
        connection.close()
    }
}

/** Back-compat for JVM tests. */
typealias CacheStoreJvm = JdbcCacheStore
