package app.crewrp

import app.crewrp.core.CacheStore
import app.crewrp.core.DiscussionsClient
import app.crewrp.core.DocsClient
import app.crewrp.core.ETagRESTClient
import app.crewrp.core.Notice
import app.crewrp.core.ProjectsClient
import app.crewrp.core.Session
import app.crewrp.core.TaskCard
import app.crewrp.core.ThreadMessage
import app.crewrp.core.ThreadTalkClient
import app.crewrp.core.UrlHttpTransport

data class CrewContent(
    val tasks: List<TaskCard> = emptyList(),
    val tasksFailed: Boolean = false,
    val notices: List<Notice> = emptyList(),
    val noticesFailed: Boolean = false,
    val threads: List<ThreadMessage> = emptyList(),
    val threadsFailed: Boolean = false,
    val doc: String = "",
    val docFailed: Boolean = false,
    val loading: Boolean = false,
)

fun fetchCrewContent(session: Session, token: String, cache: CacheStore, projectNumber: Int): CrewContent {
    val parts = session.repo.split("/")
    if (parts.size != 2) {
        return CrewContent(tasksFailed = true, noticesFailed = true, threadsFailed = true, docFailed = true)
    }
    val owner = parts[0]
    val repo = parts[1]
    val transport = UrlHttpTransport()
    val tasks = runCatching {
        val projects = ProjectsClient(transport)
        projects.sortedByDueDate(projects.listTasks(session.org, projectNumber, token))
    }
    val notices = runCatching { DiscussionsClient(transport).listNotices(owner, repo, token) }
    val threads = runCatching { ThreadTalkClient(transport).listIssueComments(owner, repo, 1, token) }
    val doc = runCatching {
        DocsClient(ETagRESTClient(transport, cache))
            .fetchMarkdown(owner, repo, "docs/README.md", token)
            .content
    }
    return CrewContent(
        tasks = tasks.getOrDefault(emptyList()),
        tasksFailed = tasks.isFailure,
        notices = notices.getOrDefault(emptyList()),
        noticesFailed = notices.isFailure,
        threads = threads.getOrDefault(emptyList()),
        threadsFailed = threads.isFailure,
        doc = doc.getOrDefault(""),
        docFailed = doc.isFailure,
    )
}
