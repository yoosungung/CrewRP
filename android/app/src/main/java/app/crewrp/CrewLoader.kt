package app.crewrp

import app.crewrp.core.CacheStore
import app.crewrp.core.DiscussionSetup
import app.crewrp.core.DiscussionsClient
import app.crewrp.core.DocEntry
import app.crewrp.core.DocFile
import app.crewrp.core.DocsClient
import app.crewrp.core.GitHubMembershipClient
import app.crewrp.core.Notice
import app.crewrp.core.ProjectFieldMeta
import app.crewrp.core.ProjectsClient
import app.crewrp.core.Session
import app.crewrp.core.TaskCard
import app.crewrp.core.ThreadMessage
import app.crewrp.core.ThreadTalkClient
import app.crewrp.core.UrlHttpTransport
import app.crewrp.core.taskLane

data class CrewContent(
    val tasks: List<TaskCard> = emptyList(),
    val tasksFailed: Boolean = false,
    val notices: List<Notice> = emptyList(),
    val noticesFailed: Boolean = false,
    val threads: List<ThreadMessage> = emptyList(),
    val threadsFailed: Boolean = false,
    val docs: List<DocEntry> = emptyList(),
    val docPath: String = "docs/README.md",
    val doc: String = "",
    val docSha: String? = null,
    val docFailed: Boolean = false,
    val projectMeta: ProjectFieldMeta? = null,
    val discussionSetup: DiscussionSetup? = null,
    val currentLogin: String? = null,
    val loading: Boolean = false,
    val writeError: String? = null,
)

private fun parts(session: Session): Pair<String, String>? {
    val p = session.repo.split("/")
    return if (p.size == 2) p[0] to p[1] else null
}

fun fetchCrewContent(session: Session, token: String, cache: CacheStore, projectNumber: Int): CrewContent {
    val (owner, repo) = parts(session) ?: return CrewContent(
        tasksFailed = true,
        noticesFailed = true,
        threadsFailed = true,
        docFailed = true,
    )
    val transport = UrlHttpTransport()
    val login = runCatching { GitHubMembershipClient(transport).currentUser(token).login }.getOrNull()
    val projects = ProjectsClient(transport)
    val tasks = runCatching { projects.sortedByDueDate(projects.listTasks(session.org, projectNumber, token)) }
    val meta = runCatching { projects.loadFieldMeta(session.org, projectNumber, token) }
    val discussions = DiscussionsClient(transport)
    val notices = runCatching { discussions.listNotices(owner, repo, token) }
    val setup = runCatching { discussions.resolveSetup(owner, repo, token) }
    val threads = runCatching { ThreadTalkClient(transport).listIssueComments(owner, repo, 1, token) }
    val docsClient = DocsClient(transport, cache)
    val docs = runCatching { docsClient.listDocs(owner, repo, token) }
    val docPath = docs.getOrNull()?.firstOrNull { !it.isDir && it.name.equals("README.md", true) }?.path
        ?: "docs/README.md"
    val doc = runCatching { docsClient.fetchMarkdown(owner, repo, docPath, token) }
    return CrewContent(
        tasks = tasks.getOrDefault(emptyList()),
        tasksFailed = tasks.isFailure,
        notices = notices.getOrDefault(emptyList()),
        noticesFailed = notices.isFailure,
        threads = threads.getOrDefault(emptyList()),
        threadsFailed = threads.isFailure,
        docs = docs.getOrDefault(emptyList()),
        docPath = docPath,
        doc = doc.getOrNull()?.content.orEmpty(),
        docSha = doc.getOrNull()?.sha,
        docFailed = doc.isFailure,
        projectMeta = meta.getOrNull(),
        discussionSetup = setup.getOrNull(),
        currentLogin = login,
    )
}

class CrewWriter(
    private val session: Session,
    private val token: String,
    private val cache: CacheStore,
    private val projectNumber: Int,
) {
    private val transport = UrlHttpTransport()
    private val owner = session.repo.substringBefore('/')
    private val repo = session.repo.substringAfter('/')

    fun createNotice(title: String, body: String, setup: DiscussionSetup): Notice =
        DiscussionsClient(transport).createNotice(setup.repositoryId, setup.categoryId, title, body, token)

    fun updateNotice(id: String, title: String, body: String): Notice =
        DiscussionsClient(transport).updateNotice(id, title, body, token)

    fun deleteNotice(id: String) =
        DiscussionsClient(transport).deleteNotice(id, token)

    fun createTask(title: String, dueOn: String?): TaskCard =
        ProjectsClient(transport).createTask(owner, repo, title, "", projectNumber, token, dueOn)

    fun updateTask(meta: ProjectFieldMeta, card: TaskCard, statusLabel: String, dueOn: String?) {
        val opt = meta.statusOptions.entries.firstOrNull {
            it.key == statusLabel || taskLane(it.key) == taskLane(statusLabel)
        }?.value
        ProjectsClient(transport).updateTaskFields(
            meta.projectId,
            card.id,
            meta.statusFieldId,
            opt,
            meta.dueFieldId,
            dueOn,
            token,
        )
    }

    fun deleteTask(meta: ProjectFieldMeta, card: TaskCard) =
        ProjectsClient(transport).deleteTask(meta.projectId, card.id, owner, repo, card.issueNumber, token)

    fun saveDoc(path: String, content: String, sha: String?): DocFile =
        DocsClient(transport, cache).saveMarkdown(owner, repo, path, content, token, sha)

    fun deleteDoc(path: String, sha: String) =
        DocsClient(transport, cache).deleteDoc(owner, repo, path, sha, token)

    fun openDoc(path: String): DocFile =
        DocsClient(transport, cache).fetchMarkdown(owner, repo, path, token)

    fun postTalk(body: String): ThreadMessage =
        ThreadTalkClient(transport).postComment(owner, repo, 1, body, token)

    fun updateTalk(id: String, body: String): ThreadMessage =
        ThreadTalkClient(transport).updateComment(owner, repo, id, body, token)

    fun deleteTalk(id: String) =
        ThreadTalkClient(transport).deleteComment(owner, repo, id, token)

    fun reactTalk(id: String) =
        ThreadTalkClient(transport).addReaction(owner, repo, id, "+1", token)
}
