package app.crewrp

import app.crewrp.core.AttachmentEntry
import app.crewrp.core.CacheStore
import app.crewrp.core.DiscussionCategory
import app.crewrp.core.DiscussionRepoSetup
import app.crewrp.core.DiscussionsClient
import app.crewrp.core.DocEntry
import app.crewrp.core.DocFile
import app.crewrp.core.DocsClient
import app.crewrp.core.GitHubMembershipClient
import app.crewrp.core.GraphQLFreshness
import app.crewrp.core.Notice
import app.crewrp.core.ProjectFieldMeta
import app.crewrp.core.ProjectsClient
import app.crewrp.core.ReleaseAssetClient
import app.crewrp.core.Session
import app.crewrp.core.TaskCard
import app.crewrp.core.ThreadMessage
import app.crewrp.core.ThreadTalkClient
import app.crewrp.core.UrlHttpTransport
import app.crewrp.core.normalizeAssigneeLogin
import app.crewrp.core.taskLane
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.Future

data class CrewContent(
    val tasks: List<TaskCard> = emptyList(),
    val tasksFailed: Boolean = false,
    val readme: String = "",
    val readmeFailed: Boolean = false,
    val discussionCategories: List<DiscussionCategory> = emptyList(),
    val discussionRepositoryId: String? = null,
    val boardFailed: Boolean = false,
    val selectedCategory: DiscussionCategory? = null,
    val boardPosts: List<Notice> = emptyList(),
    val taskComments: List<ThreadMessage> = emptyList(),
    val boardComments: List<ThreadMessage> = emptyList(),
    val docs: List<DocEntry> = emptyList(),
    val docsTree: List<DocEntry> = emptyList(),
    val docsDirPath: String = "docs",
    val attachments: List<AttachmentEntry> = emptyList(),
    val docPath: String = "docs/README.md",
    val doc: String = "",
    val docSha: String? = null,
    val docFailed: Boolean = false,
    val projectMeta: ProjectFieldMeta? = null,
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
        readmeFailed = true,
        boardFailed = true,
        docFailed = true,
    )
    val transport = UrlHttpTransport()
    val pool = Executors.newFixedThreadPool(5)
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
        val readmeF: Future<Pair<String, Boolean>> = pool.submit(
            Callable {
                val text = runCatching {
                    DocsClient(transport, cache).fetchReadme(owner, repo, token).orEmpty()
                }
                text.getOrDefault("") to text.isFailure
            },
        )
        val boardF: Future<Pair<DiscussionRepoSetup?, Boolean>> = pool.submit(
            Callable {
                val setup = runCatching {
                    DiscussionsClient(transport).listCategories(owner, repo, token, cache, forceNetwork)
                }
                setup.getOrNull() to setup.isFailure
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
        val attachmentsF: Future<List<AttachmentEntry>> = pool.submit(
            Callable {
                runCatching {
                    ReleaseAssetClient(transport).listAttachments(owner, repo, token)
                }.getOrDefault(emptyList())
            },
        )

        val tasks = tasksF.get()
        val readme = readmeF.get()
        val board = boardF.get()
        val docs = docsF.get()
        return CrewContent(
            tasks = tasks.first,
            tasksFailed = tasks.second,
            readme = readme.first,
            readmeFailed = readme.second,
            discussionCategories = board.first?.categories.orEmpty(),
            discussionRepositoryId = board.first?.repositoryId,
            boardFailed = board.second,
            docs = docs.entries,
            docsTree = docs.tree,
            docsDirPath = docs.dirPath,
            attachments = attachmentsF.get(),
            docFailed = docs.failed,
            projectMeta = tasks.third,
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

    fun createBoardPost(repositoryId: String, categoryId: String, title: String, body: String): Notice =
        DiscussionsClient(transport).createNotice(repositoryId, categoryId, title, body, token)

    fun updateBoardPost(id: String, title: String, body: String): Notice =
        DiscussionsClient(transport).updateNotice(id, title, body, token)

    fun deleteBoardPost(id: String) =
        DiscussionsClient(transport).deleteNotice(id, token)

    fun listBoardPosts(categoryId: String): List<Notice> =
        DiscussionsClient(transport).listDiscussions(owner, repo, categoryId, token, cache, forceNetwork = true)

    fun createTask(
        title: String,
        body: String,
        statusLabel: String,
        dueOn: String?,
        assignee: String?,
    ): TaskCard {
        val assignees = normalizeAssigneeLogin(assignee)?.let { listOf(it) }.orEmpty()
        return projects.createTask(
            owner,
            repo,
            title,
            body,
            resolvedProjectNumber(),
            token,
            dueOn,
            statusLabel,
            assignees,
        )
    }

    fun updateTask(
        meta: ProjectFieldMeta,
        card: TaskCard,
        title: String,
        body: String,
        statusLabel: String,
        dueOn: String?,
        assignee: String?,
    ) {
        card.issueNumber?.let {
            projects.updateIssue(owner, repo, it, title, body, token)
            val assignees = normalizeAssigneeLogin(assignee)?.let { login -> listOf(login) }.orEmpty()
            projects.setIssueAssignees(owner, repo, it, assignees, token)
        }
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

    fun uploadAttachment(name: String, bytes: ByteArray, contentType: String): AttachmentEntry =
        ReleaseAssetClient(transport).uploadAttachment(owner, repo, name, bytes, contentType, token)

    fun downloadAttachment(asset: AttachmentEntry): ByteArray =
        ReleaseAssetClient(transport).downloadBytes(asset, token)

    fun listTaskComments(issueNumber: Int): List<ThreadMessage> =
        ThreadTalkClient(transport).listIssueComments(owner, repo, issueNumber, token)

    fun postTaskComment(issueNumber: Int, body: String): ThreadMessage =
        ThreadTalkClient(transport).postComment(owner, repo, issueNumber, body, token)

    fun updateTaskComment(commentId: String, body: String): ThreadMessage =
        ThreadTalkClient(transport).updateComment(owner, repo, commentId, body, token)

    fun deleteTaskComment(commentId: String) =
        ThreadTalkClient(transport).deleteComment(owner, repo, commentId, token)

    fun listBoardComments(discussionId: String): List<ThreadMessage> =
        DiscussionsClient(transport).listDiscussionComments(discussionId, token)

    fun postBoardComment(discussionId: String, body: String): ThreadMessage =
        DiscussionsClient(transport).addDiscussionComment(discussionId, body, token)

    fun updateBoardComment(commentId: String, body: String): ThreadMessage =
        DiscussionsClient(transport).updateDiscussionComment(commentId, body, token)

    fun deleteBoardComment(commentId: String) =
        DiscussionsClient(transport).deleteDiscussionComment(commentId, token)
}
