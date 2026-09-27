@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package app.crewrp.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.crewrp.CrewContent
import app.crewrp.core.CrewRepo
import app.crewrp.core.DocBlock
import app.crewrp.core.Notice
import app.crewrp.core.Session
import app.crewrp.core.TaskCard
import app.crewrp.core.TaskLane
import app.crewrp.core.ThreadMessage
import app.crewrp.core.crewDisplayName
import app.crewrp.core.crewOwnerName
import app.crewrp.core.docBlocks
import app.crewrp.core.formatDue
import app.crewrp.core.homeSections
import app.crewrp.core.roleLabel
import app.crewrp.core.taskLane
import java.time.LocalDate

private data class Destination(
    val label: String,
    val selectedIcon: ImageVector,
    val icon: ImageVector,
)

private val destinations = listOf(
    Destination("홈", Icons.Filled.Home, Icons.Outlined.Home),
    Destination("할 일", Icons.Filled.CheckCircle, Icons.Outlined.CheckCircle),
    Destination("자료실", Icons.Filled.Folder, Icons.Outlined.Folder),
    Destination("소통", Icons.AutoMirrored.Filled.Chat, Icons.AutoMirrored.Outlined.Chat),
)

@Composable
fun LoginScreen(error: String?, onLogin: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize().safeDrawingPadding().padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            "크루를 위한 작업 공간",
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
        )
        Spacer(Modifier.padding(top = 8.dp))
        Text("CrewRP", style = MaterialTheme.typography.displaySmall)
        Text(
            "할 일, 공지, 자료를 한곳에서 봅니다.",
            modifier = Modifier.padding(top = 8.dp),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(
            onClick = onLogin,
            modifier = Modifier.fillMaxWidth().padding(top = 28.dp).heightIn(min = 48.dp),
        ) { Text("로그인") }
        if (error != null) {
            Text(
                error,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 16.dp)
                    .background(MaterialTheme.colorScheme.errorContainer, MaterialTheme.shapes.medium)
                    .padding(12.dp),
                color = MaterialTheme.colorScheme.onErrorContainer,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

@Composable
fun CrewStartScreen(repos: List<CrewRepo>, error: String?, onSelect: (CrewRepo) -> Unit) {
    LazyColumn(
        modifier = Modifier.fillMaxSize().safeDrawingPadding(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Text("크루 시작", style = MaterialTheme.typography.headlineMedium)
            Text(
                "운영 권한이 있는 보관소를 고르세요.",
                modifier = Modifier.padding(top = 4.dp, bottom = 8.dp),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (error != null) {
                Text(error, color = MaterialTheme.colorScheme.error)
            }
        }
        items(repos, key = { it.fullName }) { repo ->
            Card(
                modifier = Modifier.fillMaxWidth().clickable { onSelect(repo) },
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
            ) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(crewDisplayName(repo.fullName), style = MaterialTheme.typography.titleMedium)
                    val owner = crewOwnerName(repo.fullName)
                    if (owner.isNotEmpty()) {
                        Text(owner, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CrewShell(
    session: Session,
    content: CrewContent,
    discordEnabled: Boolean,
    onRefresh: () -> Unit,
    onDiscord: () -> Unit,
) {
    var tab by remember { mutableIntStateOf(0) }
    val name = crewDisplayName(session.repo)
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(
                            roleLabel(session.teamRole),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                actions = {
                    IconButton(onClick = onRefresh) {
                        Icon(Icons.Filled.Refresh, contentDescription = "새로고침")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                ),
            )
        },
        bottomBar = {
            NavigationBar {
                destinations.forEachIndexed { index, dest ->
                    NavigationBarItem(
                        selected = tab == index,
                        onClick = { tab = index },
                        icon = { Icon(if (tab == index) dest.selectedIcon else dest.icon, contentDescription = null) },
                        label = { Text(dest.label) },
                    )
                }
            }
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            if (content.loading) {
                LinearProgressIndicator(Modifier.fillMaxWidth())
            }
            when (tab) {
                0 -> HomeTab(session, content, Modifier.weight(1f))
                1 -> TasksTab(content, Modifier.weight(1f), onRefresh)
                2 -> DocsTab(content, Modifier.weight(1f), onRefresh)
                else -> TalkTab(content, discordEnabled, Modifier.weight(1f), onRefresh, onDiscord)
            }
        }
    }
}

@Composable
private fun HomeTab(session: Session, content: CrewContent, modifier: Modifier) {
    val today = LocalDate.now().toString()
    val sections = homeSections(content.tasks, content.notices, today)
    val quiet = sections.today.isEmpty() && sections.upcoming.isEmpty() && sections.notices.isEmpty()
    when {
        content.loading && content.tasks.isEmpty() && content.notices.isEmpty() -> LoadingPane(modifier)
        quiet && (content.tasksFailed || content.noticesFailed) -> FailedPane(modifier)
        quiet -> EmptyPane(modifier, "아직 소식이 없습니다", "공지와 할 일이 생기면 홈에 모입니다.")
        else -> LazyColumn(
            modifier = modifier.fillMaxSize(),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item { CrewSummary(session) }
            if (content.tasksFailed || content.noticesFailed) item { StaleBanner() }
            if (sections.today.isNotEmpty()) {
                item { SectionLabel("오늘 할 일") }
                items(sections.today, key = { it.id }) { TaskRow(it) }
            }
            if (sections.notices.isNotEmpty()) {
                item { SectionLabel("고정 공지") }
                items(sections.notices, key = { it.id }) { NoticeRow(it) }
            }
            if (sections.upcoming.isNotEmpty()) {
                item { SectionLabel("다가오는 할 일") }
                items(sections.upcoming, key = { "up-${it.id}" }) { TaskRow(it) }
            }
        }
    }
}

@Composable
private fun TasksTab(content: CrewContent, modifier: Modifier, onRetry: () -> Unit) {
    var mode by remember { mutableIntStateOf(0) }
    when {
        content.loading && content.tasks.isEmpty() && !content.tasksFailed -> LoadingPane(modifier)
        content.tasksFailed && content.tasks.isEmpty() -> FailedPane(modifier, onRetry)
        content.tasks.isEmpty() -> EmptyPane(modifier, "아직 할 일이 없습니다", "접수된 일이 생기면 칸반에 올라옵니다.")
        else -> Column(modifier.fillMaxSize()) {
            if (content.tasksFailed) StaleBanner()
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(16.dp)) {
                listOf("칸반", "마감일").forEachIndexed { index, label ->
                    SegmentedButton(
                        selected = mode == index,
                        onClick = { mode = index },
                        shape = SegmentedButtonDefaults.itemShape(index, 2),
                    ) { Text(label) }
                }
            }
            if (mode == 0) Kanban(content.tasks, Modifier.weight(1f)) else DueList(content.tasks, Modifier.weight(1f))
        }
    }
}

@Composable
private fun Kanban(tasks: List<TaskCard>, modifier: Modifier) {
    LazyRow(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        items(TaskLane.entries) { lane ->
            val laneTasks = tasks.filter { taskLane(it.status) == lane }
            Surface(
                modifier = Modifier.width(260.dp),
                shape = MaterialTheme.shapes.large,
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
            ) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(lane.title, style = MaterialTheme.typography.titleSmall)
                        Spacer(Modifier.weight(1f))
                        Text("${laneTasks.size}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (laneTasks.isEmpty()) {
                        Text("없음", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    laneTasks.forEach { TaskRow(it) }
                }
            }
        }
    }
}

@Composable
private fun DueList(tasks: List<TaskCard>, modifier: Modifier) {
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        items(tasks, key = { it.id }) { TaskRow(it) }
    }
}

@Composable
private fun DocsTab(content: CrewContent, modifier: Modifier, onRetry: () -> Unit) {
    val blocks = docBlocks(content.doc)
    when {
        content.loading && content.doc.isEmpty() && !content.docFailed -> LoadingPane(modifier)
        content.docFailed && content.doc.isEmpty() -> FailedPane(modifier, onRetry)
        blocks.isEmpty() -> EmptyPane(modifier, "자료실이 비어 있습니다", "정관과 규정이 올라오면 여기에 보입니다.")
        else -> LazyColumn(
            modifier = modifier.fillMaxSize(),
            contentPadding = PaddingValues(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (content.docFailed) item { StaleBanner() }
            items(blocks.size) { index -> DocLine(blocks[index]) }
        }
    }
}

@Composable
private fun TalkTab(
    content: CrewContent,
    discordEnabled: Boolean,
    modifier: Modifier,
    onRetry: () -> Unit,
    onDiscord: () -> Unit,
) {
    Column(modifier.fillMaxSize()) {
        when {
            content.loading && content.threads.isEmpty() && !content.threadsFailed -> LoadingPane(Modifier.weight(1f))
            content.threadsFailed && content.threads.isEmpty() -> FailedPane(Modifier.weight(1f), onRetry)
            content.threads.isEmpty() -> EmptyPane(
                Modifier.weight(1f),
                "스레드 톡이 없습니다",
                "공지와 할 일에 남긴 이야기가 여기에 모입니다.",
            )
            else -> LazyColumn(
                modifier = Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (content.threadsFailed) item { StaleBanner() }
                items(content.threads, key = { it.id }) { Bubble(it) }
            }
        }
        if (discordEnabled) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Button(onClick = onDiscord, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                    Text("바로 대화")
                }
                Text(
                    "음성과 잡담은 Discord에서 이어집니다.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

@Composable
private fun CrewSummary(session: Session) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(session.org, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onPrimaryContainer)
            Text(
                "${crewDisplayName(session.repo)} · ${roleLabel(session.teamRole)}",
                color = MaterialTheme.colorScheme.onPrimaryContainer,
            )
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
}

@Composable
private fun TaskRow(task: TaskCard) {
    val lane = taskLane(task.status)
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(task.title, style = MaterialTheme.typography.titleMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                LaneChip(lane)
                Text(formatDue(task.dueOn), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun LaneChip(lane: TaskLane) {
    val (bg, fg) = when (lane) {
        TaskLane.DOING -> MaterialTheme.colorScheme.primaryContainer to MaterialTheme.colorScheme.onPrimaryContainer
        TaskLane.DONE -> MaterialTheme.colorScheme.secondaryContainer to MaterialTheme.colorScheme.onSecondaryContainer
        TaskLane.INBOX -> MaterialTheme.colorScheme.surfaceVariant to MaterialTheme.colorScheme.onSurfaceVariant
    }
    Surface(color = bg, shape = MaterialTheme.shapes.small) {
        Text(lane.title, modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp), style = MaterialTheme.typography.labelMedium, color = fg)
    }
}

@Composable
private fun NoticeRow(notice: Notice) {
    var open by remember(notice.id) { mutableStateOf(false) }
    Card(
        modifier = Modifier.fillMaxWidth().clickable { open = !open },
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(notice.title, style = MaterialTheme.typography.titleMedium)
            if (notice.body.isNotBlank()) {
                Text(
                    notice.body,
                    maxLines = if (open) Int.MAX_VALUE else 2,
                    overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun Bubble(message: ThreadMessage) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(message.author, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Surface(color = MaterialTheme.colorScheme.surface, shape = MaterialTheme.shapes.medium) {
            Text(message.body, modifier = Modifier.padding(12.dp), style = MaterialTheme.typography.bodyLarge, lineHeight = 22.sp)
        }
    }
}

@Composable
private fun DocLine(block: DocBlock) {
    when (block) {
        is DocBlock.Heading -> Text(block.text, style = MaterialTheme.typography.titleLarge)
        is DocBlock.Bullet -> Text("·  ${block.text}", style = MaterialTheme.typography.bodyLarge, lineHeight = 24.sp)
        is DocBlock.Paragraph -> Text(block.text, style = MaterialTheme.typography.bodyLarge, lineHeight = 24.sp)
    }
}

@Composable
private fun StaleBanner() {
    Text(
        "최신 내용을 불러오지 못했습니다",
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.errorContainer)
            .padding(12.dp),
        color = MaterialTheme.colorScheme.onErrorContainer,
        style = MaterialTheme.typography.bodySmall,
    )
}

@Composable
private fun LoadingPane(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
    }
}

@Composable
private fun EmptyPane(modifier: Modifier = Modifier, title: String, body: String) {
    Column(
        modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(title, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        Text(
            body,
            modifier = Modifier.padding(top = 8.dp),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun FailedPane(modifier: Modifier = Modifier, onRetry: (() -> Unit)? = null) {
    Column(
        modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("내용을 불러오지 못했습니다", style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        Text(
            "연결을 확인한 뒤 다시 시도해 주세요.",
            modifier = Modifier.padding(top = 8.dp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        if (onRetry != null) {
            Button(onClick = onRetry, modifier = Modifier.padding(top = 16.dp).heightIn(min = 48.dp)) {
                Text("다시 시도")
            }
        }
    }
}
