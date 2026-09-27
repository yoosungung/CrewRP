package app.crewrp.core

import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Live GitHub CRUD against CREWRP_E2E_TOKEN + CREWRP_E2E_REPO (same clients as the apps).
 * Skips when env vars are absent.
 */
class CrudE2ETest {
    private val token = System.getenv("CREWRP_E2E_TOKEN")
    private val repo = System.getenv("CREWRP_E2E_REPO")
    private val projectNumber = System.getenv("CREWRP_E2E_PROJECT_NUMBER")?.toIntOrNull() ?: 1
    private val requireProject = System.getenv("CREWRP_E2E_REQUIRE_PROJECT") == "1"
    private val transport = UrlHttpTransport()

    private fun partsOrSkip(): Pair<String, String>? {
        if (token.isNullOrBlank() || repo.isNullOrBlank()) return null
        val slash = repo.indexOf('/')
        if (slash <= 0) return null
        return repo.substring(0, slash) to repo.substring(slash + 1)
    }

    @Test
    fun talkCommentCreateUpdateDelete() {
        val (owner, name) = partsOrSkip() ?: return
        val talk = ThreadTalkClient(transport)
        val issue = talk.ensureTalkIssueNumber(owner, name, token!!)
        val marker = "crewrp-e2e-${UUID.randomUUID().toString().take(8)}"
        val created = talk.postComment(owner, name, issue, marker, token)
        assertEquals(marker, created.body)
        val edited = talk.updateComment(owner, name, created.id, "$marker-edit", token)
        assertTrue(edited.body.endsWith("-edit"))
        talk.deleteComment(owner, name, created.id, token)
    }

    @Test
    fun noticeCreateUpdateDelete() {
        val (owner, name) = partsOrSkip() ?: return
        val discussions = DiscussionsClient(transport)
        val setup = discussions.resolveSetup(owner, name, token!!)
        val title = "crewrp-e2e-${UUID.randomUUID().toString().take(8)}"
        val created = discussions.createNotice(setup.repositoryId, setup.categoryId, title, "e2e body", token)
        assertEquals(title, created.title)
        val edited = discussions.updateNotice(created.id, "$title-edit", "edited", token)
        assertTrue(edited.title.endsWith("-edit"))
        discussions.deleteNotice(created.id, token)
    }

    @Test
    fun docsMarkdownSaveAndDelete() {
        val (owner, name) = partsOrSkip() ?: return
        JdbcCacheStore(":memory:").use { cache ->
            val docs = DocsClient(transport, cache)
            val path = "docs/crewrp-e2e-${UUID.randomUUID().toString().take(8)}.md"
            val saved = docs.saveMarkdown(owner, name, path, "# e2e\n\nhello\n", token!!, null)
            assertEquals(path, saved.path)
            val fetched = docs.fetchMarkdown(owner, name, path, token)
            assertTrue(fetched.content.contains("hello"))
            val sha = assertNotNull(fetched.sha)
            docs.deleteDoc(owner, name, path, sha, token)
        }
    }

    @Test
    fun taskCreateAndDelete() {
        val (owner, name) = partsOrSkip() ?: return
        val projects = ProjectsClient(transport)
        val number = try {
            projects.resolveProjectNumber(owner, projectNumber, token!!)
        } catch (e: Throwable) {
            if (requireProject) throw e
            return // host token lacks project; device smoke / REQUIRE_PROJECT path covers tasks
        }
        val meta = projects.loadFieldMeta(owner, number, token!!)
        if (meta == null) {
            if (requireProject) error("project meta missing after resolve (#$number)")
            return
        }

        val title = "crewrp-e2e-${UUID.randomUUID().toString().take(8)}"
        val card = projects.createTask(owner, name, title, "e2e", number, token!!, null)
        assertEquals(title, card.title)
        projects.deleteTask(meta.projectId, card.id, owner, name, card.issueNumber, token)
    }
}
