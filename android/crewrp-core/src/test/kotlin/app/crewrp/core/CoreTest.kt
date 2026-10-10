package app.crewrp.core

import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
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
        // Projects v2 mutations require the dedicated `project` scope (repo alone is not enough).
        assertTrue(url.contains("scope=read%3Aorg+repo+project") || url.contains("scope=read%3Aorg%20repo%20project"))
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

    @Test
    fun storesDiscordAccountLinkWithoutToken() {
        JdbcCacheStore(":memory:").use { store ->
            store.putAccountLink(AccountLink(AccountLink.DISCORD, "99", "crewmate", Instant.ofEpochSecond(50)))
            val link = store.accountLink(AccountLink.DISCORD)
            assertEquals("99", link?.userId)
            assertEquals("crewmate", link?.username)
            store.clearAccountLink(AccountLink.DISCORD)
            assertEquals(null, store.accountLink(AccountLink.DISCORD))
        }
    }
}

class ETagRESTClientTest {
    @Test
    fun persistsResponseEtag() {
        JdbcCacheStore(":memory:").use { cache ->
            val transport = HttpTransport { _, _, _, _ ->
                HttpResult(
                    200,
                    """{"path":"docs/a.md","content":"","encoding":"base64"}""",
                    mapOf("ETag" to "\"fresh\""),
                )
            }
            ETagRESTClient(transport, cache).get("https://api.github.com/repos/o/r/contents/docs/a.md", "t")
            assertEquals("\"fresh\"", cache.cacheEntry("https://api.github.com/repos/o/r/contents/docs/a.md")?.etag)
        }
    }
}

class GraphQLFreshnessTest {
    @Test
    fun skipsNetworkWhenCursorFresh() {
        JdbcCacheStore(":memory:").use { cache ->
            val now = Instant.ofEpochSecond(1_000)
            GraphQLFreshness.store(
                cache,
                GraphQLFreshness.listNoticesQueryName("o", "r"),
                """[{"id":"D1","title":"t","body":"b","authorLogin":"ada"}]""",
                now,
            )
            var hits = 0
            val notices = DiscussionsClient(
                HttpTransport { _, _, _, _ ->
                    hits += 1
                    error("network should not run")
                },
            ).listNotices("o", "r", "t", cache, forceNetwork = false, now = now.plusSeconds(30))
            assertEquals(0, hits)
            assertEquals(listOf("D1"), notices.map { it.id })
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

    @Test
    fun exchangesDiscordIdentity() {
        val transport = HttpTransport { method, url, _, _ ->
            assertEquals("POST", method)
            assertTrue(url.endsWith("/oauth/discord/token"))
            HttpResult(200, """{"id":"99","username":"crewmate"}""")
        }
        val client = AuthBridgeClient("https://auth.example", transport)
        val id = client.exchangeDiscord("abc", "ver", "discord-dcid:/authorize/callback")
        assertEquals("99", id.id)
        assertEquals("crewmate", id.username)
    }
}

class CrewSettingsClientTest {
    @Test
    fun loadsDiscordSettingsFromRepoFile() {
        val json = """{"discord":{"serverId":"1","channelId":"2"}}"""
        val encoded = java.util.Base64.getEncoder().encodeToString(json.toByteArray())
        JdbcCacheStore(":memory:").use { cache ->
            val transport = HttpTransport { _, url, _, _ ->
                assertTrue(url.contains("/contents/.crewrp/settings.json"))
                HttpResult(200, """{"content":"$encoded","encoding":"base64","sha":"abc"}""")
            }
            val file = CrewSettingsClient(transport, cache).load("crew", "box", "t")
            assertEquals("1", file?.settings?.discord?.serverId)
            assertEquals("2", file?.settings?.discord?.channelId)
            assertEquals("abc", file?.sha)
            assertEquals(true, file?.settings?.discord?.isConfigured)
        }
    }

    @Test
    fun returnsNullWhenSettingsMissing() {
        JdbcCacheStore(":memory:").use { cache ->
            val transport = HttpTransport { _, _, _, _ -> HttpResult(404, """{"message":"Not Found"}""") }
            val file = CrewSettingsClient(transport, cache).load("crew", "box", "t")
            assertEquals(null, file)
        }
    }
}

class DiscordLinkFlowTest {
    @Test
    fun linkAndUnlink() {
        val transport = HttpTransport { _, url, _, _ ->
            assertTrue(url.endsWith("/oauth/discord/token"))
            HttpResult(200, """{"id":"99","username":"crewmate"}""")
        }
        JdbcCacheStore(":memory:").use { cache ->
            val pending = InMemoryPendingLoginStore()
            val flow = DiscordLinkFlow(
                DiscordAuthConfig("dcid", authBridgeBaseUrl = "https://auth.example"),
                AuthBridgeClient("https://auth.example", transport),
                cache,
                pending,
            )
            val challenge = flow.beginLink()
            assertTrue(challenge.authorizeUrl.startsWith("https://discord.com/api/oauth2/authorize?"))
            assertTrue(challenge.authorizeUrl.contains("discord-dcid"))
            val link = flow.completeLink("discord-dcid:/authorize/callback?code=x&state=${challenge.state}")
            assertEquals("99", link.userId)
            assertEquals("crewmate", flow.linkedDiscord()?.username)
            flow.unlink()
            assertEquals(null, flow.linkedDiscord())
        }
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

    @Test
    fun logoutClearsTokenSessionAndPendingOauth() {
        val pending = InMemoryPendingLoginStore()
        val transport = HttpTransport { _, url, _, _ ->
            when {
                url.endsWith("/oauth/token") -> HttpResult(200, """{"access_token":"gho_ok"}""")
                url.contains("/user/repos") ->
                    HttpResult(
                        200,
                        """[{"name":"box","full_name":"crew/box","private":true,
                            "permissions":{"admin":true},"owner":{"login":"crew"}}]""",
                    )
                url.endsWith("/user/teams") -> HttpResult(200, "[]")
                else -> error("unexpected $url")
            }
        }
        JdbcCacheStore(":memory:").use { cache ->
            val tokens = InMemoryTokenStore()
            val flow = AuthFlow(
                AuthConfig("cid", "crewrp://oauth/callback", "https://auth.example"),
                AuthBridgeClient("https://auth.example", transport),
                GitHubMembershipClient(transport),
                tokens,
                cache,
                pending,
            )
            val challenge = flow.beginLogin()
            val repos = flow.completeLogin("crewrp://oauth/callback?code=x&state=${challenge.state}")
            flow.registerCrew(repos[0])
            flow.beginLogin()
            cache.putAccountLink(AccountLink(AccountLink.DISCORD, "1", "x"))
            flow.logout()
            assertEquals(null, tokens.loadAccessToken())
            assertEquals(null, cache.session())
            assertEquals(null, pending.load())
            assertEquals(null, cache.accountLink(AccountLink.DISCORD))
        }
    }

    @Test
    fun completesLoginAfterNewAuthFlowUsingPersistedPending() {
        val pending = InMemoryPendingLoginStore()
        val transport = HttpTransport { _, url, _, _ ->
            when {
                url.endsWith("/oauth/token") ->
                    HttpResult(200, """{"access_token":"gho_ok"}""")
                url.contains("/user/repos") ->
                    HttpResult(
                        200,
                        """[{"name":"ai-edu","full_name":"yoosungung/ai-edu","private":true,
                            "permissions":{"admin":true},"owner":{"login":"yoosungung"}}]""",
                    )
                else -> error("unexpected $url")
            }
        }
        JdbcCacheStore(":memory:").use { cache ->
            val config = AuthConfig("cid", "crewrp://oauth/callback", "https://auth.example")
            val first = AuthFlow(
                config,
                AuthBridgeClient(config.authBridgeBaseUrl, transport),
                GitHubMembershipClient(transport),
                InMemoryTokenStore(),
                cache,
                pending,
            )
            val challenge = first.beginLogin()
            val second = AuthFlow(
                config,
                AuthBridgeClient(config.authBridgeBaseUrl, transport),
                GitHubMembershipClient(transport),
                InMemoryTokenStore(),
                cache,
                pending,
            )
            val repos = second.completeLogin("crewrp://oauth/callback?code=abc&state=${challenge.state}")
            assertEquals(listOf("yoosungung/ai-edu"), repos.map { it.fullName })
            assertEquals(null, pending.load())
        }
    }

    @Test
    fun emptyRegistrableReposStillCompletesLogin() {
        val transport = HttpTransport { _, url, _, _ ->
            when {
                url.endsWith("/oauth/token") ->
                    HttpResult(200, """{"access_token":"gho_ok"}""")
                url.contains("/user/repos") -> HttpResult(200, "[]")
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
            val repos = flow.completeLogin("crewrp://oauth/callback?code=abc&state=${challenge.state}")
            assertEquals(emptyList(), repos)
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
            val doc = DocsClient(transport, cache)
                .fetchMarkdown("crew", "box", "docs/README.md", "t")
            assertTrue(doc.content.contains("자료실"))
        }
    }
}

class UrlHttpTransportTest {
    @Test
    fun sendsPatchViaMethodOverride() {
        var seenMethod = ""
        var seenOverride = ""
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            seenMethod = exchange.requestMethod
            seenOverride = exchange.requestHeaders.getFirst("X-HTTP-Method-Override").orEmpty()
            val bytes = "{}".toByteArray()
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        try {
            val url = "http://127.0.0.1:${server.address.port}/"
            val result = UrlHttpTransport().exchange("PATCH", url, emptyMap(), """{"body":"x"}""")
            assertEquals(200, result.status)
            assertEquals("POST", seenMethod)
            assertEquals("PATCH", seenOverride)
        } finally {
            server.stop(0)
        }
    }
}

class ShellPresentationTest {
    @Test
    fun labelsRoleLaneAndDueDate() {
        assertEquals("운영진", roleLabel(TeamRole.ADMIN))
        assertEquals("멤버", roleLabel(TeamRole.MEMBER))
        assertEquals(TaskLane.INBOX, taskLane("Todo"))
        assertEquals(TaskLane.DOING, taskLane("In Progress"))
        assertEquals(TaskLane.DONE, taskLane("완료"))
        assertEquals("9월 5일", formatDue("2026-09-05"))
        assertEquals("마감 없음", formatDue(null))
        assertEquals("crew", crewDisplayName("acme/crew"))
        assertEquals("acme", crewOwnerName("acme/crew"))
        assertEquals(false, discordConfigured("REPLACE_ME", "1"))
        assertEquals(true, discordConfigured("123", "456"))
    }

    @Test
    fun compactKanbanStacksLanesAndWideKeepsColumns() {
        assertTrue(kanbanUsesStackedLanes(true))
        assertFalse(kanbanUsesStackedLanes(false))
        assertEquals("진행 중", taskStatusChoice("In Progress"))
        assertEquals("접수", taskStatusChoice("Todo"))
        assertEquals("2026-10-06", dueOnInput("2026-10-06T09:00:00"))
        assertEquals("", dueOnInput(null))
        assertEquals("2026-10-06", formatDueOnDate(parseDueOnDate("2026-10-06")!!))
        assertEquals(null, parseDueOnDate(""))
        assertEquals(null, parseDueOnDate("nope"))
    }

    @Test
    fun homeKeepsTodayUpcomingAndThreeNotices() {
        val tasks = listOf(
            TaskCard("a", "오늘", "접수", "2026-09-27T09:00:00"),
            TaskCard("b", "다음", "In Progress", "2026-10-01"),
            TaskCard("c", "끝", "Done", "2026-10-02"),
            TaskCard("d", "지난", "접수", "2026-09-01"),
        )
        val notices = (1..4).map { Notice("n$it", "공지$it", "") }
        val home = homeSections(tasks, notices, "2026-09-27")
        assertEquals(listOf("a"), home.today.map { it.id })
        assertEquals(listOf("b"), home.upcoming.map { it.id })
        assertEquals(listOf("n1", "n2", "n3"), home.notices.map { it.id })
    }

    @Test
    fun docBlocksKeepHeadingsBulletsAndParagraphs() {
        val blocks = docBlocks("# 정관\n\n첫 문단\n이어짐\n\n- 하나\n")
        assertEquals(
            listOf(
                DocBlock.Heading("정관"),
                DocBlock.Paragraph("첫 문단 이어짐"),
                DocBlock.Bullet("하나"),
            ),
            blocks,
        )
    }

    @Test
    fun filterDocsMatchesNameOrPathCaseInsensitiveDirsFirst() {
        val entries = listOf(
            DocEntry("docs/README.md", "README.md", null, false),
            DocEntry("docs/guides", "guides", null, true),
            DocEntry("docs/guides/onboard.md", "onboard.md", null, false),
            DocEntry("docs/notes.md", "notes.md", null, false),
        )
        assertEquals(listOf("guides", "notes.md", "onboard.md", "README.md"), filterDocs(entries, "").map { it.name })
        assertEquals(listOf("docs/guides", "docs/guides/onboard.md"), filterDocs(entries, "GUIDE").map { it.path })
        assertEquals(listOf("README.md"), filterDocs(entries, "readme").map { it.name })
        assertEquals(4, filterDocs(entries, "   ").size)
    }

    @Test
    fun listedDocsUsesFolderWhenQueryEmptyElseTreeIndex() {
        val folder = listOf(DocEntry("docs/notes.md", "notes.md", null, false))
        val tree = listOf(
            DocEntry("docs/guides/onboard.md", "onboard.md", null, false),
            DocEntry("docs/notes.md", "notes.md", null, false),
        )
        assertEquals(listOf("docs/notes.md"), listedDocs(folder, tree, "").map { it.path })
        assertEquals(listOf("docs/guides/onboard.md"), listedDocs(folder, tree, "onboard").map { it.path })
    }

    @Test
    fun docsEntriesFromGitTreeKeepsDocsPrefixBlobAndTreeOnly() {
        val nodes = listOf(
            GitTreeNode("README.md", "blob", "a"),
            GitTreeNode("docs", "tree", "t0"),
            GitTreeNode("docs/guides", "tree", "t1"),
            GitTreeNode("docs/guides/onboard.md", "blob", "b1"),
            GitTreeNode("src/main.kt", "blob", "c"),
        )
        val entries = docsEntriesFromGitTree(nodes)
        assertEquals(listOf("docs", "docs/guides", "docs/guides/onboard.md"), entries.map { it.path })
        assertEquals(listOf(true, true, false), entries.map { it.isDir })
    }

    @Test
    fun parentDocsPathWalksUpUntilDocsRoot() {
        assertNull(parentDocsPath("docs"))
        assertNull(parentDocsPath("docs/"))
        assertEquals("docs", parentDocsPath("docs/guides"))
        assertEquals("docs/guides", parentDocsPath("docs/guides/deep"))
    }

    @Test
    fun listTasksReadsStatusAndSkipsMissingProject() {
        val payload = """
            {"data":{"organization":{"projectV2":{"items":{"nodes":[
              {"id":"t1","content":{"title":"보고서","body":"세부"},"fieldValues":{"nodes":[
                {"name":"In Progress","field":{"name":"Status"}},
                {"date":"2026-09-27","field":{"name":"Due"}}
              ]}}
            ]}}}}}
        """.trimIndent()
        val client = ProjectsClient(HttpTransport { method, url, _, _ ->
            assertEquals("POST", method)
            assertTrue(url.endsWith("/graphql"))
            HttpResult(200, payload)
        })
        val cards = client.listTasks("crew", 1, "tok")
        assertEquals("보고서", cards.single().title)
        assertEquals("세부", cards.single().body)
        assertEquals("2026-09-27", cards.single().dueOn)
        assertEquals(TaskLane.DOING, taskLane(cards.single().status))

        val empty = ProjectsClient(HttpTransport { _, _, _, _ ->
            HttpResult(200, """{"data":{"organization":{"projectV2":null}}}""")
        })
        assertEquals(emptyList(), empty.listTasks("crew", 1, "tok"))
    }

    @Test
    fun firstProjectNumberReadsUserProjectsIgnoringOrgError() {
        val payload = """
            {"data":{"organization":null,"user":{"projectsV2":{"nodes":[{"number":3},{"number":1}]}}},
             "errors":[{"type":"NOT_FOUND","path":["organization"]}]}
        """.trimIndent()
        val n = ProjectsClient(HttpTransport { _, _, _, _ -> HttpResult(200, payload) })
            .firstProjectNumber("yoosungung", "tok")
        assertEquals(1, n)
    }

    @Test
    fun resolveProjectNumberFallsBackWhenPreferredMissing() {
        var calls = 0
        val transport = HttpTransport { _, _, _, body ->
            calls++
            val q = body.orEmpty()
            when {
                q.contains("projectV2(number") && calls == 1 ->
                    HttpResult(
                        200,
                        """{"data":{"organization":null,"user":{"projectV2":null}},
                           "errors":[{"type":"NOT_FOUND","path":["organization"]}]}""",
                    )
                q.contains("projectsV2") ->
                    HttpResult(
                        200,
                        """{"data":{"organization":null,"user":{"projectsV2":{"nodes":[{"number":2}]}}},
                           "errors":[{"type":"NOT_FOUND","path":["organization"]}]}""",
                    )
                else -> error("unexpected graphql: $q")
            }
        }
        assertEquals(2, ProjectsClient(transport).resolveProjectNumber("alice", 1, "tok"))
    }

    @Test
    fun loadFieldMetaAndListTasksRecognizeGitHubDueDateField() {
        val metaPayload = """
            {"data":{"user":{"projectV2":{"id":"P1","fields":{"nodes":[
              {"id":"S1","name":"Status","options":[{"id":"o1","name":"접수"}]},
              {"id":"D1","name":"Due date"}
            ]}}}}}
        """.trimIndent()
        val meta = ProjectsClient(HttpTransport { _, _, _, _ -> HttpResult(200, metaPayload) })
            .loadFieldMeta("yoosungung", 1, "tok")
        assertEquals("D1", meta!!.dueFieldId)

        val listPayload = """
            {"data":{"user":{"projectV2":{"items":{"nodes":[
              {"id":"t1","content":{"title":"보고서"},"fieldValues":{"nodes":[
                {"name":"접수","field":{"name":"Status"}},
                {"date":"2026-10-07","field":{"name":"Due date"}}
              ]}}
            ]}}}}}
        """.trimIndent()
        val cards = ProjectsClient(HttpTransport { _, _, _, _ -> HttpResult(200, listPayload) })
            .listTasks("yoosungung", 1, "tok")
        assertEquals("2026-10-07", cards.single().dueOn)
    }

    @Test
    fun loadFieldMetaQueryAsksForFieldCommonAndFiftyFields() {
        var body: String? = null
        val transport = HttpTransport { _, _, _, raw ->
            body = raw
            HttpResult(
                200,
                """{"data":{"user":{"projectV2":{"id":"P1","fields":{"nodes":[
                  {"id":"S1","name":"Status","options":[{"id":"o1","name":"접수"}]},
                  {"id":"D1","name":"Due date"}
                ]}}}}}""",
            )
        }
        val meta = ProjectsClient(transport).loadFieldMeta("yoosungung", 1, "tok")
        assertEquals("D1", meta!!.dueFieldId)
        val sent = body!!
        assertTrue(sent.contains("fields(first:50)"))
        assertTrue(sent.contains("ProjectV2FieldCommon"))
    }

    @Test
    fun loadFieldMetaUsesDateDataTypeWhenNameIsNotDue() {
        val payload = """
            {"data":{"user":{"projectV2":{"id":"P1","fields":{"nodes":[
              {"id":"S1","name":"Status","options":[{"id":"o1","name":"접수"}]},
              {"id":"D1","name":"마감일","dataType":"DATE"}
            ]}}}}}
        """.trimIndent()
        val meta = ProjectsClient(HttpTransport { _, _, _, _ -> HttpResult(200, payload) })
            .loadFieldMeta("yoosungung", 1, "tok")
        assertEquals("D1", meta!!.dueFieldId)
    }

    @Test
    fun ensureDueDateFieldCreatesDateFieldWhenMissing() {
        var calls = 0
        val transport = HttpTransport { _, _, _, body ->
            calls++
            val q = body.orEmpty()
            when {
                q.contains("createProjectV2Field") -> {
                    assertTrue(q.contains("Due date"))
                    HttpResult(200, """{"data":{"createProjectV2Field":{"projectV2Field":{"id":"D1","name":"Due date"}}}}""")
                }
                q.contains("fields(first") && calls > 2 ->
                    HttpResult(
                        200,
                        """{"data":{"user":{"projectV2":{"id":"P1","fields":{"nodes":[
                          {"id":"S1","name":"Status","options":[{"id":"o1","name":"접수"}]},
                          {"id":"D1","name":"Due date","dataType":"DATE"}
                        ]}}}}}""",
                    )
                else ->
                    HttpResult(
                        200,
                        """{"data":{"user":{"projectV2":{"id":"P1","fields":{"nodes":[
                          {"id":"S1","name":"Status","options":[{"id":"o1","name":"접수"}]}
                        ]}}}}}""",
                    )
            }
        }
        val client = ProjectsClient(transport)
        val before = client.loadFieldMeta("yoosungung", 1, "tok")!!
        assertEquals(null, before.dueFieldId)
        val after = client.ensureDueDateField(before, "yoosungung", 1, "tok")
        assertEquals("D1", after.dueFieldId)
    }

    @Test
    fun loadFieldMetaToleratesOrganizationNotFoundForUserLogin() {
        val payload = """
            {"data":{"organization":null,"user":{"projectV2":{"id":"P1","fields":{"nodes":[
              {"id":"S1","name":"Status","options":[{"id":"o1","name":"접수"}]}
            ]}}}},
             "errors":[{"type":"NOT_FOUND","path":["organization"],"message":"Could not resolve to an Organization"}]}
        """.trimIndent()
        val meta = ProjectsClient(HttpTransport { _, _, _, _ -> HttpResult(200, payload) })
            .loadFieldMeta("yoosungung", 1, "tok")
        assertEquals("P1", meta!!.projectId)
        assertEquals("o1", meta.statusOptions["접수"])
    }

    @Test
    fun createTaskClosesIssueWhenProjectMetaMissing() {
        val calls = mutableListOf<String>()
        val client = ProjectsClient(HttpTransport { method, url, _, _ ->
            calls += "$method $url"
            when {
                method == "POST" && url.endsWith("/issues") ->
                    HttpResult(201, """{"number":42,"node_id":"I_1"}""")
                method == "POST" && url.endsWith("/graphql") ->
                    HttpResult(
                        200,
                        """{"data":{"organization":{"projectV2":null},"user":{"projectV2":null}}}""",
                    )
                method == "PATCH" && url.endsWith("/issues/42") ->
                    HttpResult(200, """{"state":"closed"}""")
                else -> error("$method $url")
            }
        })
        try {
            client.createTask("a", "b", "title", "", 1, "tok", null)
            error("expected createTask to fail")
        } catch (e: IllegalStateException) {
            assertTrue(e.message.orEmpty().contains("missing project"))
        }
        assertTrue(calls.any { it.startsWith("PATCH ") && it.endsWith("/issues/42") })
    }

    @Test
    fun listNoticesAndThreadComments() {
        val notices = DiscussionsClient(HttpTransport { _, _, _, _ ->
            HttpResult(
                200,
                """{"data":{"repository":{"discussions":{"nodes":[{"id":"n1","title":"정기 모임","body":"금요일"}]}}}}""",
            )
        }).listNotices("crew", "box", "tok")
        assertEquals("정기 모임", notices.single().title)

        val comments = ThreadTalkClient(HttpTransport { method, url, _, _ ->
            assertEquals("GET", method)
            assertTrue(url.endsWith("/repos/crew/box/issues/1/comments"))
            HttpResult(200, """[{"id":12,"body":"확인했습니다","user":{"login":"ada"}}]""")
        }).listIssueComments("crew", "box", 1, "tok")
        assertEquals("ada", comments.single().author)
        assertEquals("확인했습니다", comments.single().body)
    }

    @Test
    fun canMutateAllowsAdminOrAuthor() {
        assertEquals(true, canMutate(TeamRole.ADMIN, "other", "me"))
        assertEquals(true, canMutate(TeamRole.MEMBER, "me", "me"))
        assertEquals(false, canMutate(TeamRole.MEMBER, "other", "me"))
    }

    @Test
    fun writeFailureMessageGuidesReloginOnMissingScopes() {
        assertTrue(writeFailureMessage("requires one of the following scopes: ['project']").contains("다시 로그인"))
        assertEquals("저장하지 못했습니다. 잠시 후 다시 시도해 주세요.", writeFailureMessage("timeout"))
    }

    @Test
    fun createUpdateDeleteNotice() {
        var step = 0
        val client = DiscussionsClient(HttpTransport { _, _, _, body ->
            when (step++) {
                0 -> HttpResult(
                    200,
                    """{"data":{"repository":{"id":"R1","discussionCategories":{"nodes":[
                      {"id":"C1","name":"공지"},{"id":"C2","name":"일반"}
                    ]}}}}""",
                )
                1 -> {
                    assertTrue(body!!.contains("createDiscussion"))
                    HttpResult(200, """{"data":{"createDiscussion":{"discussion":{"id":"D1","title":"안녕","body":"본문","author":{"login":"ada"}}}}}""")
                }
                2 -> HttpResult(200, """{"data":{"updateDiscussion":{"discussion":{"id":"D1","title":"수정","body":"본문2","author":{"login":"ada"}}}}}""")
                else -> HttpResult(200, """{"data":{"deleteDiscussion":{"discussion":{"id":"D1"}}}}""")
            }
        })
        val setup = client.resolveSetup("crew", "box", "t")
        assertEquals("R1", setup.repositoryId)
        assertEquals("C1", setup.categoryId)
        val created = client.createNotice(setup.repositoryId, setup.categoryId, "안녕", "본문", "t")
        assertEquals("D1", created.id)
        assertEquals("수정", client.updateNotice("D1", "수정", "본문2", "t").title)
        client.deleteNotice("D1", "t")
    }

    @Test
    fun ensureTalkIssueCreatesWhenMissing() {
        var created = false
        val talk = ThreadTalkClient(HttpTransport { method, url, _, body ->
            when {
                method == "GET" && url.contains("state=open") -> HttpResult(200, "[]")
                method == "GET" && url.endsWith("/issues/1") -> HttpResult(404, "")
                method == "POST" && url.endsWith("/issues") -> {
                    created = true
                    assertTrue(body!!.contains(ThreadTalkClient.TALK_ISSUE_TITLE))
                    HttpResult(201, """{"number":7}""")
                }
                else -> error("$method $url")
            }
        })
        assertEquals(7, talk.ensureTalkIssueNumber("a", "b", "t"))
        assertTrue(created)
    }

    @Test
    fun threadCommentCrudAndDocsSave() {
        val talk = ThreadTalkClient(HttpTransport { method, url, _, body ->
            when {
                method == "POST" && url.endsWith("/comments") ->
                    HttpResult(201, """{"id":9,"body":"hi","user":{"login":"ada"}}""")
                method == "PATCH" ->
                    HttpResult(200, """{"id":9,"body":"edit","user":{"login":"ada"}}""")
                method == "DELETE" -> HttpResult(204, "")
                method == "POST" && url.contains("/reactions") -> HttpResult(200, "{}")
                else -> error("$method $url $body")
            }
        })
        assertEquals("hi", talk.postComment("a", "b", 1, "hi", "t").body)
        assertEquals("edit", talk.updateComment("a", "b", "9", "edit", "t").body)
        talk.deleteComment("a", "b", "9", "t")
        talk.addReaction("a", "b", "9", "+1", "t")

        JdbcCacheStore(":memory:").use { cache ->
            val docs = DocsClient(
                HttpTransport { method, url, _, body ->
                    when {
                        method == "GET" && url.contains("/contents/docs") && !url.contains("README") ->
                            HttpResult(200, """[{"path":"docs/README.md","name":"README.md","type":"file","sha":"s1"}]""")
                        method == "PUT" -> {
                            assertTrue(body!!.contains("자료 저장"))
                            HttpResult(200, """{"content":{"path":"docs/a.md","sha":"s2"}}""")
                        }
                        method == "DELETE" -> HttpResult(200, "{}")
                        else -> error("$method $url")
                    }
                },
                cache,
            )
            assertEquals("docs/README.md", docs.listDocs("c", "r", "t").single().path)
            assertEquals("s2", docs.saveMarkdown("c", "r", "docs/a.md", "# hi", "t", null).sha)
            docs.deleteDoc("c", "r", "docs/a.md", "s2", "t")
        }
    }

    @Test
    fun listDocsTreeFiltersRecursiveTreeTtlThenShaSkipRecursive() {
        JdbcCacheStore(":memory:").use { cache ->
            var recursiveHits = 0
            val now = Instant.ofEpochSecond(1_000)
            val docs = DocsClient(
                HttpTransport { method, url, _, _ ->
                    assertEquals("GET", method)
                    when {
                        url.endsWith("/repos/crew/box") ->
                            HttpResult(200, """{"default_branch":"main"}""")
                        url.contains("/git/trees/main?recursive=1") -> {
                            recursiveHits += 1
                            HttpResult(
                                200,
                                """{"sha":"tree1","tree":[
                                  {"path":"docs","type":"tree","sha":"d0"},
                                  {"path":"docs/guides/onboard.md","type":"blob","sha":"b1"},
                                  {"path":"src/a.kt","type":"blob","sha":"x"}
                                ],"truncated":false}""",
                            )
                        }
                        url.endsWith("/git/trees/main") ->
                            HttpResult(
                                200,
                                """{"sha":"tree1","tree":[{"path":"docs","type":"tree","sha":"d0"}],"truncated":false}""",
                            )
                        else -> error(url)
                    }
                },
                cache,
            )
            val first = docs.listDocsTree("crew", "box", "t", forceNetwork = true, now = now)
            assertEquals(listOf("docs", "docs/guides/onboard.md"), first.map { it.path })
            assertEquals(1, recursiveHits)

            val fresh = docs.listDocsTree("crew", "box", "t", forceNetwork = false, now = now.plusSeconds(30))
            assertEquals(listOf("docs", "docs/guides/onboard.md"), fresh.map { it.path })
            assertEquals(1, recursiveHits)

            val afterTtl = docs.listDocsTree("crew", "box", "t", forceNetwork = false, now = now.plusSeconds(120))
            assertEquals(listOf("docs", "docs/guides/onboard.md"), afterTtl.map { it.path })
            assertEquals(1, recursiveHits)
        }
    }

    @Test
    fun listTasksFallsBackToUserProject() {
        var calls = 0
        val client = ProjectsClient(HttpTransport { _, _, _, body ->
            calls++
            if (body!!.contains("organization(login")) {
                HttpResult(200, """{"data":{"organization":null}}""")
            } else {
                HttpResult(
                    200,
                    """{"data":{"user":{"projectV2":{"items":{"nodes":[
                      {"id":"i1","content":{"title":"개인","number":3},"fieldValues":{"nodes":[]}}
                    ]}}}}}""",
                )
            }
        })
        val cards = client.listTasks("alice", 1, "t")
        assertEquals(1, cards.size)
        assertEquals("개인", cards.single().title)
        assertEquals(3, cards.single().issueNumber)
        assertTrue(calls >= 2)
    }
}
