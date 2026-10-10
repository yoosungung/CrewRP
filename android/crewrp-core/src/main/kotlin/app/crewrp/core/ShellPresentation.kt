package app.crewrp.core

enum class TaskLane(val title: String) {
    INBOX("접수"),
    DOING("진행 중"),
    DONE("완료"),
}

fun taskLane(status: String): TaskLane {
    val normalized = status.trim().lowercase()
    return when {
        normalized in setOf("완료", "done", "complete", "completed") -> TaskLane.DONE
        normalized.contains("진행") || normalized in setOf("in progress", "doing", "in_progress") -> TaskLane.DOING
        else -> TaskLane.INBOX
    }
}

/** compact(폰)는 레인 세로 섹션, 와이드는 다열 칸반. */
fun kanbanUsesStackedLanes(compact: Boolean): Boolean = compact

fun taskStatusChoice(status: String): String = taskLane(status).title

/** 상세 납기 입력값. Projects Due는 YYYY-MM-DD. */
fun dueOnInput(iso: String?): String = iso?.take(10).orEmpty()

fun roleLabel(role: TeamRole): String = if (role == TeamRole.ADMIN) "운영진" else "멤버"

/** 쓰기 API 실패 문구. 스코프 부족이면 재로그인을 안내한다. */
fun writeFailureMessage(detail: String): String {
    val lower = detail.lowercase()
    if ("scope" in lower || "resource not accessible" in lower) {
        return "권한이 부족합니다. 다시 로그인해 주세요."
    }
    if ("http 401" in lower || "github http 401" in lower) {
        return "로그인이 만료되었습니다. 다시 로그인해 주세요."
    }
    if ("http 403" in lower || "github http 403" in lower) {
        return "권한이 부족합니다. 다시 로그인해 주세요."
    }
    if ("http 404" in lower || "github http 404" in lower) {
        return "대상이 없습니다. 잠시 후 다시 시도해 주세요."
    }
    if ("http 429" in lower || "github http 429" in lower) {
        return "요청이 많습니다. 잠시 후 다시 시도해 주세요."
    }
    return "저장하지 못했습니다. 잠시 후 다시 시도해 주세요."
}

/** 운영진은 전부, 멤버는 본인 작성분만 수정·삭제. */
fun canMutate(role: TeamRole, authorLogin: String?, currentLogin: String?): Boolean {
    if (role == TeamRole.ADMIN) return true
    if (currentLogin.isNullOrBlank() || authorLogin.isNullOrBlank()) return false
    return authorLogin.equals(currentLogin, ignoreCase = true)
}

fun crewDisplayName(repo: String): String = repo.substringAfter('/', repo).ifBlank { repo }

fun crewOwnerName(repo: String): String = if ('/' in repo) repo.substringBefore('/') else ""

fun discordConfigured(serverId: String, channelId: String): Boolean {
    fun ready(value: String) = value.isNotBlank() && !value.contains("REPLACE", ignoreCase = true)
    return ready(serverId) && ready(channelId)
}

fun formatDue(iso: String?): String {
    if (iso.isNullOrBlank()) return "마감 없음"
    val parts = iso.split("-")
    if (parts.size != 3) return iso
    val month = parts[1].toIntOrNull() ?: return iso
    val day = parts[2].take(2).toIntOrNull() ?: return iso
    return "${month}월 ${day}일"
}

data class HomeSections(
    val today: List<TaskCard>,
    val upcoming: List<TaskCard>,
    val notices: List<Notice>,
)

fun homeSections(tasks: List<TaskCard>, notices: List<Notice>, today: String): HomeSections {
    val todayTasks = tasks.filter { it.dueOn?.startsWith(today) == true }
    val upcoming = tasks
        .filter { card ->
            val due = card.dueOn?.take(10) ?: return@filter false
            due > today && taskLane(card.status) != TaskLane.DONE
        }
        .sortedBy { it.dueOn }
        .take(3)
    return HomeSections(todayTasks, upcoming, notices.take(3))
}

sealed interface DocBlock {
    data class Heading(val text: String) : DocBlock
    data class Bullet(val text: String) : DocBlock
    data class Paragraph(val text: String) : DocBlock
}

fun docBlocks(markdown: String): List<DocBlock> {
    val blocks = mutableListOf<DocBlock>()
    val paragraph = StringBuilder()
    fun flush() {
        val text = paragraph.toString().trim()
        if (text.isNotEmpty()) blocks += DocBlock.Paragraph(text)
        paragraph.clear()
    }
    for (raw in markdown.lines()) {
        val line = raw.trim()
        when {
            line.isEmpty() -> flush()
            line.startsWith("#") -> {
                flush()
                val text = line.trimStart('#').trim()
                if (text.isNotEmpty()) blocks += DocBlock.Heading(text)
            }
            line.startsWith("- ") || line.startsWith("* ") -> {
                flush()
                blocks += DocBlock.Bullet(line.drop(2).trim())
            }
            else -> {
                if (paragraph.isNotEmpty()) paragraph.append(' ')
                paragraph.append(line)
            }
        }
    }
    flush()
    return blocks
}

/** 현재 목록에서 이름·경로 부분 일치(대소문자 무시). 빈 쿼리는 전체. 폴더 우선·이름 정렬. */
fun filterDocs(entries: List<DocEntry>, query: String): List<DocEntry> {
    val q = query.trim()
    val filtered = if (q.isEmpty()) {
        entries
    } else {
        entries.filter { it.name.contains(q, ignoreCase = true) || it.path.contains(q, ignoreCase = true) }
    }
    return filtered.sortedWith(compareByDescending<DocEntry> { it.isDir }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.name })
}

/** 검색어 없으면 현재 폴더 목록, 있으면 Trees 재귀 인덱스에서 필터. */
fun listedDocs(folderEntries: List<DocEntry>, treeEntries: List<DocEntry>, query: String): List<DocEntry> {
    val q = query.trim()
    return if (q.isEmpty()) filterDocs(folderEntries, "") else filterDocs(treeEntries, q)
}

/** `/docs` 루트면 null. 그 외 상위 path (Contents API list 대상). */
fun parentDocsPath(path: String): String? {
    val trimmed = path.trim('/').trimEnd('/')
    if (trimmed.isEmpty() || trimmed == "docs") return null
    val slash = trimmed.lastIndexOf('/')
    if (slash <= 0) return null
    return trimmed.substring(0, slash).ifEmpty { null }
}
