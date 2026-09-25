package app.crewrp

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import app.crewrp.core.CacheEntry
import app.crewrp.core.CacheStore
import app.crewrp.core.GraphQLCursorRow
import app.crewrp.core.Session
import app.crewrp.core.TeamRole
import java.time.Instant

class AndroidCacheStore(context: Context) : CacheStore {
    private val helper = Helper(context)
    private val db: SQLiteDatabase get() = helper.writableDatabase

    override fun putCacheEntry(url: String, body: String, etag: String?, fetchedAt: Instant) {
        db.execSQL(
            "INSERT OR REPLACE INTO cache_entry(url, body, etag, fetched_at) VALUES (?, ?, ?, ?)",
            arrayOf(url, body, etag, fetchedAt.epochSecond.toDouble()),
        )
    }

    override fun cacheEntry(url: String): CacheEntry? {
        db.rawQuery("SELECT url, body, etag, fetched_at FROM cache_entry WHERE url = ?", arrayOf(url)).use { c ->
            if (!c.moveToFirst()) return null
            return CacheEntry(
                url = c.getString(0),
                body = c.getString(1),
                etag = c.getString(2),
                fetchedAt = Instant.ofEpochSecond(c.getDouble(3).toLong()),
            )
        }
    }

    override fun putGraphQLCursor(queryName: String, cursor: String?, updatedAt: Instant) {
        db.execSQL(
            "INSERT OR REPLACE INTO graphql_cursor(query_name, cursor, updated_at) VALUES (?, ?, ?)",
            arrayOf(queryName, cursor, updatedAt.epochSecond.toDouble()),
        )
    }

    override fun graphQLCursor(queryName: String): GraphQLCursorRow? {
        db.rawQuery(
            "SELECT query_name, cursor, updated_at FROM graphql_cursor WHERE query_name = ?",
            arrayOf(queryName),
        ).use { c ->
            if (!c.moveToFirst()) return null
            return GraphQLCursorRow(
                queryName = c.getString(0),
                cursor = c.getString(1),
                updatedAt = Instant.ofEpochSecond(c.getDouble(2).toLong()),
            )
        }
    }

    override fun putSession(session: Session) {
        db.execSQL(
            "INSERT OR REPLACE INTO session(id, org, repo, team_role) VALUES (1, ?, ?, ?)",
            arrayOf(session.org, session.repo, session.teamRole.name.lowercase()),
        )
    }

    override fun session(): Session? {
        db.rawQuery("SELECT org, repo, team_role FROM session WHERE id = 1", null).use { c ->
            if (!c.moveToFirst()) return null
            val role = when (c.getString(2)) {
                "admin" -> TeamRole.ADMIN
                "member" -> TeamRole.MEMBER
                else -> TeamRole.NONE
            }
            return Session(c.getString(0), c.getString(1), role)
        }
    }

    override fun close() {
        helper.close()
    }

    private class Helper(context: Context) : SQLiteOpenHelper(context, "crewrp.sqlite", null, 1) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS cache_entry (
                  url TEXT PRIMARY KEY NOT NULL,
                  body TEXT NOT NULL,
                  etag TEXT,
                  fetched_at REAL NOT NULL
                );
                """.trimIndent(),
            )
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS graphql_cursor (
                  query_name TEXT PRIMARY KEY NOT NULL,
                  cursor TEXT,
                  updated_at REAL NOT NULL
                );
                """.trimIndent(),
            )
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS session (
                  id INTEGER PRIMARY KEY CHECK (id = 1),
                  org TEXT NOT NULL,
                  repo TEXT NOT NULL,
                  team_role TEXT NOT NULL
                );
                """.trimIndent(),
            )
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
    }
}
