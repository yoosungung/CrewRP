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

fun roleLabel(role: TeamRole): String = if (role == TeamRole.ADMIN) "운영진" else "멤버"

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
