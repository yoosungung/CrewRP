package app.crewrp.core

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PKCETest {
    @Test
    fun verifierIsUrlSafeAndLongEnough() {
        val pair = PKCE.generate()
        assertTrue(pair.verifier.length >= 43)
        assertTrue(pair.verifier.all { it.isLetterOrDigit() || it == '-' || it == '_' })
    }

    @Test
    fun challengeMatchesRfc7636() {
        val verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        assertEquals("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", PKCE.challenge(verifier))
    }

    @Test
    fun authorizeUrlIncludesPkceParams() {
        val url = GitHubOAuth.authorizeUrl(
            clientId = "cid",
            redirectUri = "crewrp://oauth/callback",
            state = "st",
            codeChallenge = "chal",
        )
        assertTrue(url.startsWith("https://github.com/login/oauth/authorize?"))
        assertTrue(url.contains("client_id=cid"))
        assertTrue(url.contains("code_challenge=chal"))
        assertTrue(url.contains("code_challenge_method=S256"))
        assertTrue(url.contains("response_type=code"))
    }
}

class TeamRoleTest {
    @Test
    fun adminsWinsOverMembers() {
        assertEquals(TeamRole.ADMIN, TeamRole.resolve(listOf("members", "admins")))
    }

    @Test
    fun membersAloneIsMember() {
        assertEquals(TeamRole.MEMBER, TeamRole.resolve(listOf("members")))
    }

    @Test
    fun unknownIsNone() {
        assertEquals(TeamRole.NONE, TeamRole.resolve(listOf("random")))
    }
}

class CacheStoreTest {
    @Test
    fun storesRestBodyWithEtag() {
        CacheStore(":memory:").use { store ->
            store.putCacheEntry("https://api.github.com/user", """{"login":"a"}""", "\"etag1\"")
            val entry = store.cacheEntry("https://api.github.com/user")
            assertEquals("""{"login":"a"}""", entry?.body)
            assertEquals("\"etag1\"", entry?.etag)
        }
    }

    @Test
    fun storesGraphqlCursor() {
        CacheStore(":memory:").use { store ->
            store.putGraphQLCursor("discussions", "c1", Instant.ofEpochSecond(100))
            val row = store.graphQLCursor("discussions")
            assertEquals("c1", row?.cursor)
            assertEquals(100, row?.updatedAt?.epochSecond)
        }
    }

    @Test
    fun sessionExcludesToken() {
        CacheStore(":memory:").use { store ->
            store.putSession(Session("crew", "crew/box", TeamRole.MEMBER))
            val session = store.session()
            assertEquals("crew", session?.org)
            assertEquals("crew/box", session?.repo)
            assertEquals(TeamRole.MEMBER, session?.teamRole)
        }
    }
}
