package app.crewrp

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.crewrp.core.DiscussionsClient
import app.crewrp.core.DocsClient
import app.crewrp.core.ProjectsClient
import app.crewrp.core.ThreadTalkClient
import app.crewrp.core.UrlHttpTransport
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Live CRUD on the device (same clients as the app). Prefers instrumentation args
 * `e2e_token` + `e2e_repo`; falls back to the logged-in app session.
 */
@RunWith(AndroidJUnit4::class)
class DeviceCrudSmokeTest {
    @Test
    fun crudRoundTripWithAppSession() {
        val args = InstrumentationRegistry.getArguments()
        val argToken = args.getString("e2e_token")
        val argRepo = args.getString("e2e_repo")
        val projectNumber = args.getString("e2e_project_number")?.toIntOrNull()
            ?: BuildConfig.PROJECT_NUMBER.toIntOrNull()
            ?: 1
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext

        val token: String
        val owner: String
        val repo: String
        if (!argToken.isNullOrBlank() && !argRepo.isNullOrBlank()) {
            val parts = argRepo.split("/")
            assertEquals("e2e_repo must be owner/name", 2, parts.size)
            token = argToken
            owner = parts[0]
            repo = parts[1]
        } else {
            val stored = EncryptedPrefsTokenStore(ctx).loadAccessToken()
            assertNotNull("app not logged in — sign in or pass e2e_token/e2e_repo", stored)
            assertTrue(stored!!.isNotBlank())
            val session = AndroidCacheStore(ctx).session()
            assertNotNull("no crew session — register a crew or pass e2e_repo", session)
            val parts = session!!.repo.split("/")
            assertEquals("session.repo must be owner/name", 2, parts.size)
            token = stored
            owner = parts[0]
            repo = parts[1]
        }

        val scopes = oauthScopes(token)
        assertTrue(
            "token scopes lack project (re-login with project); scopes=$scopes",
            scopes.isEmpty() || scopes.split(',', ' ').any { it.trim() == "project" },
        )

        val transport = UrlHttpTransport()

        // Talk
        val talk = ThreadTalkClient(transport)
        val issue = talk.ensureTalkIssueNumber(owner, repo, token)
        val talkMarker = "crewrp-device-talk-${UUID.randomUUID().toString().take(8)}"
        val talkCreated = talk.postComment(owner, repo, issue, talkMarker, token)
        assertEquals(talkMarker, talkCreated.body)
        val talkEdited = talk.updateComment(owner, repo, talkCreated.id, "$talkMarker-edit", token)
        assertTrue(talkEdited.body.endsWith("-edit"))
        talk.deleteComment(owner, repo, talkCreated.id, token)

        // Notice
        val discussions = DiscussionsClient(transport)
        val setup = discussions.resolveSetup(owner, repo, token)
        val noticeTitle = "crewrp-device-notice-${UUID.randomUUID().toString().take(8)}"
        val notice = discussions.createNotice(setup.repositoryId, setup.categoryId, noticeTitle, "e2e", token)
        assertEquals(noticeTitle, notice.title)
        val noticeEdited = discussions.updateNotice(notice.id, "$noticeTitle-edit", "edited", token)
        assertTrue(noticeEdited.title.endsWith("-edit"))
        discussions.deleteNotice(notice.id, token)

        // Docs
        val docs = DocsClient(transport, AndroidCacheStore(ctx))
        val path = "docs/crewrp-device-${UUID.randomUUID().toString().take(8)}.md"
        val saved = docs.saveMarkdown(owner, repo, path, "# e2e\n\nhello\n", token, null)
        assertEquals(path, saved.path)
        val fetched = docs.fetchMarkdown(owner, repo, path, token)
        assertTrue(fetched.content.contains("hello"))
        val sha = fetched.sha
        assertNotNull(sha)
        docs.deleteDoc(owner, repo, path, sha!!, token)

        // Task (Projects v2 — resolve/create when preferred number is missing)
        val projects = ProjectsClient(transport)
        val number = projects.resolveProjectNumber(owner, projectNumber, token)
        val meta = projects.loadFieldMeta(owner, number, token)
        assertNotNull("project meta missing for $owner after resolve (#$number)", meta)
        val title = "crewrp-device-task-${UUID.randomUUID().toString().take(8)}"
        val card = projects.createTask(owner, repo, title, "device-e2e", number, token, null)
        assertEquals(title, card.title)
        projects.deleteTask(meta!!.projectId, card.id, owner, repo, card.issueNumber, token)
    }

    private fun oauthScopes(token: String): String {
        val conn = (URL("https://api.github.com/user").openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            setRequestProperty("Authorization", "Bearer $token")
            setRequestProperty("Accept", "application/vnd.github+json")
        }
        conn.responseCode
        return conn.getHeaderField("X-OAuth-Scopes").orEmpty()
    }
}
