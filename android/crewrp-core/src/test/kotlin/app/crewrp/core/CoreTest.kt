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
        JdbcCacheStore(":memory:").use { store ->
            store.putCacheEntry("https://api.github.com/user", """{"login":"a"}""", "\"etag1\"")
            val entry = store.cacheEntry("https://api.github.com/user")
            assertEquals("""{"login":"a"}""", entry?.body)
            assertEquals("\"etag1\"", entry?.etag)
        }
    }

    @Test
    fun storesGraphqlCursor() {
        JdbcCacheStore(":memory:").use { store ->
            store.putGraphQLCursor("discussions", "c1", Instant.ofEpochSecond(100))
            val row = store.graphQLCursor("discussions")
            assertEquals("c1", row?.cursor)
            assertEquals(100, row?.updatedAt?.epochSecond)
        }
    }

    @Test
    fun sessionExcludesToken() {
        JdbcCacheStore(":memory:").use { store ->
            store.putSession(Session("crew", "crew/box", TeamRole.MEMBER))
            val session = store.session()
            assertEquals("crew", session?.org)
            assertEquals("crew/box", session?.repo)
            assertEquals(TeamRole.MEMBER, session?.teamRole)
        }
    }
}

class TokenStoreTest {
    @Test
    fun memoryRoundTrip() {
        val store = InMemoryTokenStore()
        store.saveAccessToken("gho_x")
        assertEquals("gho_x", store.loadAccessToken())
        store.clearAccessToken()
        assertEquals(null, store.loadAccessToken())
    }
}

class AuthBridgeClientTest {
    @Test
    fun exchangesCode() {
        val transport = HttpTransport { method, url, _, body ->
            assertEquals("POST", method)
            assertTrue(url.endsWith("/oauth/token"))
            assertTrue(body!!.contains("\"code\":\"abc\""))
            HttpResult(200, """{"access_token":"gho_ok","token_type":"bearer","scope":"read:org"}""")
        }
        val client = AuthBridgeClient("https://auth.example", transport)
        assertEquals("gho_ok", client.exchange("abc", "ver", "crewrp://oauth/callback").accessToken)
    }
}

class GitHubMembershipClientTest {
    @Test
    fun listsRegistrableReposAndResolvesAdmin() {
        val transport = HttpTransport { _, url, _, _ ->
            when {
                url.contains("/user/repos") ->
                    HttpResult(
                        200,
                        """[{"name":"box","full_name":"crew/box","private":true,
                            "permissions":{"admin":true},"owner":{"login":"crew"}},
                           {"name":"public","full_name":"crew/public","private":false,
                            "permissions":{"admin":true},"owner":{"login":"crew"}}]""",
                    )
                url.endsWith("/user/teams") ->
                    HttpResult(
                        200,
                        """[{"id":9,"slug":"admins","name":"Admins","organization":{"login":"crew"}},
                           {"id":10,"slug":"members","name":"Members","organization":{"login":"other"}}]""",
                    )
                else -> error("unexpected $url")
            }
        }
        val client = GitHubMembershipClient(transport)
        assertEquals(listOf("crew/box"), client.listRegistrableRepos("t").map { it.fullName })
        assertEquals(TeamRole.ADMIN, client.resolveRole("crew", "t", isRepoAdmin = true))
    }
}

class AuthFlowTest {
    @Test
    fun loginAndRegisterCrew() {
        val transport = HttpTransport { method, url, _, _ ->
            when {
                url.endsWith("/oauth/token") ->
                    HttpResult(200, """{"access_token":"gho_ok","token_type":"bearer"}""")
                url.contains("/user/repos") ->
                    HttpResult(
                        200,
                        """[{"name":"box","full_name":"crew/box","private":true,
                            "permissions":{"admin":true},"owner":{"login":"crew"}}]""",
                    )
                url.endsWith("/user/teams") ->
                    HttpResult(200, """[{"id":9,"slug":"members","name":"Members","organization":{"login":"crew"}}]""")
                else -> error("unexpected $method $url")
            }
        }
        JdbcCacheStore(":memory:").use { cache ->
            val tokens = InMemoryTokenStore()
            val config = AuthConfig("cid", "crewrp://oauth/callback", "https://auth.example")
            val flow = AuthFlow(
                config,
                AuthBridgeClient(config.authBridgeBaseUrl, transport),
                GitHubMembershipClient(transport),
                tokens,
                cache,
            )
            val challenge = flow.beginLogin()
            val repos = flow.completeLogin("crewrp://oauth/callback?code=abc&state=${challenge.state}")
            assertEquals(listOf("crew/box"), repos.map { it.fullName })
            assertEquals("gho_ok", tokens.loadAccessToken())
            val session = flow.registerCrew(repos[0])
            assertEquals("crew/box", session.repo)
            assertEquals(TeamRole.MEMBER, session.teamRole)
            assertEquals("crew", cache.session()?.org)
        }
    }

    @Test
    fun personalAdminRepoRegistersAsOwnerAdmin() {
        val transport = HttpTransport { _, url, _, _ ->
            when {
                url.endsWith("/oauth/token") ->
                    HttpResult(200, """{"access_token":"gho_ok"}""")
                url.contains("/user/repos") ->
                    HttpResult(
                        200,
                        """[{"name":"study","full_name":"alice/study","private":true,
                            "permissions":{"admin":true},"owner":{"login":"alice"}}]""",
                    )
                url.endsWith("/user/teams") -> HttpResult(200, "[]")
                else -> error("unexpected $url")
            }
        }
        JdbcCacheStore(":memory:").use { cache ->
            val flow = AuthFlow(
                AuthConfig("cid", "crewrp://oauth/callback", "https://auth.example"),
                AuthBridgeClient("https://auth.example", transport),
                GitHubMembershipClient(transport),
                InMemoryTokenStore(),
                cache,
            )
            val challenge = flow.beginLogin()
            val repos = flow.completeLogin("crewrp://oauth/callback?code=x&state=${challenge.state}")
            assertEquals(listOf("alice/study"), repos.map { it.fullName })
            val session = flow.registerCrew(repos[0])
            assertEquals("alice/study", session.repo)
            assertEquals(TeamRole.ADMIN, session.teamRole)
        }
    }
}

class Phase2Test {
    @Test
    fun parsesIssueFormAndDiscordLink() {
        val form = IssueFormParser.parse(
            """
            name: 지출 결의서
            body:
              - type: input
                id: amount
                attributes:
                  label: 금액
                validations:
                  required: true
            """.trimIndent(),
        )
        assertEquals("지출 결의서", form.name)
        assertEquals("amount", form.fields[0].id)
        assertEquals(true, form.fields[0].required)
        assertEquals(
            "https://discord.com/channels/1/2",
            DiscordDeepLink.voiceChannelUrl("1", "2"),
        )
    }

    @Test
    fun sortsTasksByDueDate() {
        val sorted = ProjectsClient(HttpTransport { _, _, _, _ -> error("no") }).sortedByDueDate(
            listOf(
                TaskCard("1", "b", "할 일", "2026-09-30"),
                TaskCard("2", "a", "할 일", "2026-09-01"),
            ),
        )
        assertEquals(listOf("2", "1"), sorted.map { it.id })
    }

    @Test
    fun expenseFormAndDocs() {
        val form = IssueFormParser.parse(
            """
            name: 지출 결의서
            body:
              - type: input
                id: amount
                attributes:
                  label: 금액
                validations:
                  required: true
              - type: textarea
                id: reason
                attributes:
                  label: 사유
                validations:
                  required: true
            """.trimIndent(),
        )
        assertEquals(listOf("amount", "reason"), form.fields.map { it.id })

        val markdown = "# 자료실\n"
        val encoded = java.util.Base64.getEncoder().encodeToString(markdown.toByteArray())
        JdbcCacheStore(":memory:").use { cache ->
            val transport = HttpTransport { _, url, _, _ ->
                assertTrue(url.endsWith("/repos/crew/box/contents/docs/README.md"))
                HttpResult(200, """{"path":"docs/README.md","content":"$encoded","encoding":"base64"}""")
            }
            val doc = DocsClient(ETagRESTClient(transport, cache))
                .fetchMarkdown("crew", "box", "docs/README.md", "t")
            assertTrue(doc.content.contains("자료실"))
        }
    }
}
