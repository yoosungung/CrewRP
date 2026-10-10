package app.crewrp

import app.crewrp.core.CacheStore
import app.crewrp.core.DiscussionSetup
import app.crewrp.core.DiscussionsClient
import app.crewrp.core.DocEntry
import app.crewrp.core.DocFile
import app.crewrp.core.DocsClient
import app.crewrp.core.GitHubMembershipClient
import app.crewrp.core.GraphQLFreshness
import app.crewrp.core.Notice
import app.crewrp.core.ProjectFieldMeta
import app.crewrp.core.ProjectsClient
import app.crewrp.core.Session
import app.crewrp.core.TaskCard
import app.crewrp.core.UrlHttpTransport
import app.crewrp.core.taskLane
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.Future

data class CrewContent(
    val tasks: List<TaskCard> = emptyList(),
    val tasksFailed: Boolean = false,
    val notices: List<Notice> = emptyList(),
    val noticesFailed: Boolean = false,
    val docs: List<DocEntry> = emptyList(),
    val docsTree: List<DocEntry> = emptyList(),
    val docsDirPath: String = "docs",
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

fun fetchCrewContent(
    session: Session,
    token: String,
    cache: CacheStore,
    projectNumber: Int,
    forceNetwork: Boolean = false,
    docsDirPath: String = "docs",
): CrewContent {
    val (owner, repo) = parts(session) ?: return CrewContent(
        tasksFailed = true,
        noticesFailed = true,
        docFailed = true,
    )
    val transport = UrlHttpTransport()
    val pool = Executors.newFixedThreadPool(4)
    try {
        val loginF: Future<String?> = pool.submit(
            Callable {
                runCatching { GitHubMembershipClient(transport).currentUser(token).login }.getOrNull()
            },
        )
        val tasksF: Future<Triple<List<TaskCard>, Boolean, ProjectFieldMeta?>> = pool.submit(
            Callable {
                val projects = ProjectsClient(transport)
                val queryName = GraphQLFreshness.listTasksQueryName(session.org, projectNumber)
                val number = if (!forceNetwork && GraphQLFreshness.freshBody(cache, queryName) != null) {
                    projectNumber
                } else {
                    runCatching { projects.resolveProjectNumber(session.org, projectNumber, token) }
                        .getOrDefault(projectNumber)
                }
                val tasks = runCatching {
                    projects.sortedByDueDate(
                        projects.listTasks(session.org, number, token, cache, forceNetwork),
                    )
                }
                val meta = runCatching { projects.loadFieldMeta(session.org, number, token) }
                Triple(tasks.getOrDefault(emptyList()), tasks.isFailure, meta.getOrNull())
            },
        )
        val noticesF: Future<Triple<List<Notice>, Boolean, DiscussionSetup?>> = pool.submit(
            Callable {
                val discussions = DiscussionsClient(transport)
                val notices = runCatching {
                    discussions.listNotices(owner, repo, token, cache, forceNetwork)
                }
                val setup = runCatching { discussions.resolveSetup(owner, repo, token) }
                Triple(notices.getOrDefault(emptyList()), notices.isFailure, setup.getOrNull())
            },
        )
        val docsF: Future<DocsBundle> = pool.submit(
            Callable {
                val docsClient = DocsClient(transport, cache)
                val docs = runCatching { docsClient.listDocs(owner, repo, token, docsDirPath) }
                val tree = runCatching {
                    docsClient.listDocsTree(owner, repo, token, forceNetwork = forceNetwork)
                }
                DocsBundle(
                    docs.getOrDefault(emptyList()),
                    tree.getOrDefault(emptyList()),
                    docsDirPath,
                    docs.isFailure,
                )
            },
        )

        val tasks = tasksF.get()
        val notices = noticesF.get()
        val docs = docsF.get()
        return CrewContent(
            tasks = tasks.first,
            tasksFailed = tasks.second,
            notices = notices.first,
            noticesFailed = notices.second,
            docs = docs.entries,
            docsTree = docs.tree,
            docsDirPath = docs.dirPath,
            docFailed = docs.failed,
            projectMeta = tasks.third,
            discussionSetup = notices.third,
            currentLogin = loginF.get(),
        )
    } finally {
        pool.shutdownNow()
    }
}

private data class DocsBundle(
    val entries: List<DocEntry>,
    val tree: List<DocEntry>,
    val dirPath: String,
    val failed: Boolean,
)

class CrewWriter(
    private val session: Session,
    private val token: String,
    private val cache: CacheStore,
    private val projectNumber: Int,
) {
    private val transport = UrlHttpTransport()
    private val owner = session.repo.substringBefore('/')
    private val repo = session.repo.substringAfter('/')
    private val projects = ProjectsClient(transport)

    private fun resolvedProjectNumber(): Int =
        projects.resolveProjectNumber(session.org, projectNumber, token)

    fun createNotice(title: String, body: String, setup: DiscussionSetup): Notice =
        DiscussionsClient(transport).createNotice(setup.repositoryId, setup.categoryId, title, body, token)

    fun updateNotice(id: String, title: String, body: String): Notice =
        DiscussionsClient(transport).updateNotice(id, title, body, token)

    fun deleteNotice(id: String) =
        DiscussionsClient(transport).deleteNotice(id, token)

    fun createTask(title: String, body: String, statusLabel: String, dueOn: String?): TaskCard =
        projects.createTask(owner, repo, title, body, resolvedProjectNumber(), token, dueOn, statusLabel)

    fun updateTask(
        meta: ProjectFieldMeta,
        card: TaskCard,
        title: String,
        body: String,
        statusLabel: String,
        dueOn: String?,
    ) {
        card.issueNumber?.let { projects.updateIssue(owner, repo, it, title, body, token) }
        val ready = if (dueOn != null) {
            projects.ensureDueDateField(meta, session.org, resolvedProjectNumber(), token)
        } else {
            meta
        }
        val opt = ready.statusOptions.entries.firstOrNull {
            it.key == statusLabel || taskLane(it.key) == taskLane(statusLabel)
        }?.value
        ProjectsClient(transport).updateTaskFields(
            ready.projectId,
            card.id,
            ready.statusFieldId,
            opt,
            ready.dueFieldId,
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

    fun listDocs(path: String): List<DocEntry> =
        DocsClient(transport, cache).listDocs(owner, repo, token, path)
}
