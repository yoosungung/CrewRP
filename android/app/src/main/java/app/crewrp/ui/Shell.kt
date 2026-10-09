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
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setText
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
import app.crewrp.core.TeamRole
import app.crewrp.core.ThreadMessage
import app.crewrp.core.canMutate
import app.crewrp.core.crewDisplayName
import app.crewrp.core.crewOwnerName
import app.crewrp.core.DocEntry
import app.crewrp.core.docBlocks
import app.crewrp.core.dueOnInput
import app.crewrp.core.filterDocs
import app.crewrp.core.formatDue
import app.crewrp.core.homeSections
import app.crewrp.core.kanbanUsesStackedLanes
import app.crewrp.core.parentDocsPath
import app.crewrp.core.roleLabel
import app.crewrp.core.taskLane
import app.crewrp.core.taskStatusChoice
import java.time.LocalDate

data class CrewActions(
    val onCreateNotice: (title: String, body: String) -> Unit,
    val onUpdateNotice: (Notice, title: String, body: String) -> Unit,
    val onDeleteNotice: (Notice) -> Unit,
    val onCreateTask: (title: String, dueOn: String?) -> Unit,
    val onUpdateTask: (TaskCard, status: String, dueOn: String?) -> Unit,
    val onDeleteTask: (TaskCard) -> Unit,
    val onSaveDoc: (path: String, content: String) -> Unit,
    val onDeleteDoc: () -> Unit,
    val onOpenDoc: (path: String) -> Unit,
    val onListDocs: (path: String) -> Unit,
    val onPostTalk: (body: String) -> Unit,
    val onUpdateTalk: (ThreadMessage, body: String) -> Unit,
    val onDeleteTalk: (ThreadMessage) -> Unit,
    val onReactTalk: (ThreadMessage) -> Unit,
)

private data class Destination(val label: String, val selectedIcon: ImageVector, val icon: ImageVector)

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
        Text("크루를 위한 작업 공간", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.padding(top = 8.dp))
        Text("CrewRP", style = MaterialTheme.typography.displaySmall)
        Text(
            "할 일, 공지, 자료를 한곳에서 봅니다.",
            modifier = Modifier.padding(top = 8.dp),
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Button(onClick = onLogin, modifier = Modifier.fillMaxWidth().padding(top = 28.dp).heightIn(min = 48.dp)) {
            Text("로그인")
        }
        if (error != null) {
            Text(
                error,
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp)
                    .background(MaterialTheme.colorScheme.errorContainer, MaterialTheme.shapes.medium)
                    .padding(12.dp),
                color = MaterialTheme.colorScheme.onErrorContainer,
            )
        }
    }
}

@Composable
fun CrewStartScreen(
    repos: List<CrewRepo>,
    error: String?,
    onSelect: (CrewRepo) -> Unit,
    onLogout: () -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize().safeDrawingPadding(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("크루 시작", style = MaterialTheme.typography.headlineMedium)
                TextButton(onClick = onLogout) { Text("로그아웃") }
            }
            Text(
                "운영 권한이 있는 보관소를 고르세요.",
                modifier = Modifier.padding(top = 4.dp, bottom = 8.dp),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (error != null) Text(error, color = MaterialTheme.colorScheme.error)
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

@Composable
fun CrewShell(
    session: Session,
    content: CrewContent,
    discordEnabled: Boolean,
    actions: CrewActions,
    onRefresh: () -> Unit,
    onDiscord: () -> Unit,
    onLogout: () -> Unit,
) {
    var tab by remember { mutableIntStateOf(0) }
    var compose by remember { mutableStateOf<ComposeKind?>(null) }
    var editingNotice by remember { mutableStateOf<Notice?>(null) }
    var editingTask by remember { mutableStateOf<TaskCard?>(null) }
    var editingTalk by remember { mutableStateOf<ThreadMessage?>(null) }
    var viewingDoc by remember { mutableStateOf(false) }
    var talkDraft by remember { mutableStateOf("") }
    val name = crewDisplayName(session.repo)

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(roleLabel(session.teamRole), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                },
                actions = {
                    TextButton(onClick = onLogout) { Text("로그아웃") }
                    IconButton(onClick = onRefresh) { Icon(Icons.Filled.Refresh, contentDescription = "새로고침") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
        floatingActionButton = {
            when (tab) {
                0, 1, 2 -> FloatingActionButton(onClick = {
                    compose = when (tab) {
                        0 -> ComposeKind.Notice
                        1 -> ComposeKind.Task
                        else -> ComposeKind.Doc
                    }
                }) { Icon(Icons.Filled.Add, contentDescription = "작성") }
            }
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
            if (content.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            content.writeError?.let {
                Text(
                    it,
                    modifier = Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.errorContainer).padding(12.dp),
                    color = MaterialTheme.colorScheme.onErrorContainer,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            when (tab) {
                0 -> HomeTab(session, content, Modifier.weight(1f), onOpenNotice = { editingNotice = it })
                1 -> TasksTab(content, Modifier.weight(1f), onRefresh, onOpen = { editingTask = it })
                2 -> DocsTab(
                    content,
                    Modifier.weight(1f),
                    onRefresh,
                    actions,
                    onOpenDetail = { viewingDoc = true },
                )
                else -> TalkTab(
                    content,
                    discordEnabled,
                    talkDraft,
                    { talkDraft = it },
                    {
                        if (talkDraft.isNotBlank()) {
                            actions.onPostTalk(talkDraft.trim())
                            talkDraft = ""
                        }
                    },
                    Modifier.weight(1f),
                    onRefresh,
                    onDiscord,
                    onEdit = { editingTalk = it },
                    onDelete = actions.onDeleteTalk,
                    onReact = actions.onReactTalk,
                    role = session.teamRole,
                    login = content.currentLogin,
                )
            }
        }
    }

    when (val kind = compose) {
        ComposeKind.Notice -> FormDialog(
            title = "공지 작성",
            onDismiss = { compose = null },
            onSubmit = { t, b -> actions.onCreateNotice(t, b); compose = null },
        )
        ComposeKind.Task -> FormDialog(
            title = "할 일 추가",
            dueField = true,
            onDismiss = { compose = null },
            onSubmit = { t, due -> actions.onCreateTask(t, due.takeIf { it.isNotBlank() }); compose = null },
        )
        ComposeKind.Doc -> FormDialog(
            title = "자료 저장",
            titleLabel = "경로 (docs/…)",
            initialTitle = if (content.docsDirPath == "docs") "docs/notes.md" else "${content.docsDirPath}/notes.md",
            bodyLabel = "내용",
            onDismiss = { compose = null },
            onSubmit = { path, body ->
                val p = if (path.startsWith("docs/")) path else "docs/$path"
                actions.onSaveDoc(p, body)
                compose = null
            },
        )
        null -> Unit
    }

    if (viewingDoc) {
        DocDetailDialog(
            content = content,
            role = session.teamRole,
            onDismiss = { viewingDoc = false },
            onSave = { path, body ->
                actions.onSaveDoc(path, body)
                viewingDoc = false
            },
            onDelete = {
                actions.onDeleteDoc()
                viewingDoc = false
            },
        )
    }

    editingNotice?.let { notice ->
        FormDialog(
            title = "공지 수정",
            initialTitle = notice.title,
            initialBody = notice.body,
            showDelete = canMutate(session.teamRole, notice.authorLogin, content.currentLogin),
            onDismiss = { editingNotice = null },
            onSubmit = { t, b -> actions.onUpdateNotice(notice, t, b); editingNotice = null },
            onDelete = { actions.onDeleteNotice(notice); editingNotice = null },
        )
    }
    editingTask?.let { task ->
        TaskEditDialog(
            task = task,
            showDelete = session.teamRole == TeamRole.ADMIN,
            onDismiss = { editingTask = null },
            onSubmit = { status, due ->
                actions.onUpdateTask(task, status, due)
                editingTask = null
            },
            onDelete = { actions.onDeleteTask(task); editingTask = null },
        )
    }
    editingTalk?.let { msg ->
        FormDialog(
            title = "메시지 수정",
            initialTitle = msg.author,
            titleEnabled = false,
            initialBody = msg.body,
            onDismiss = { editingTalk = null },
            onSubmit = { _, b -> actions.onUpdateTalk(msg, b); editingTalk = null },
        )
    }
}

private enum class ComposeKind { Notice, Task, Doc }

@Composable
private fun TaskEditDialog(
    task: TaskCard,
    showDelete: Boolean,
    onDismiss: () -> Unit,
    onSubmit: (status: String, dueOn: String?) -> Unit,
    onDelete: () -> Unit,
) {
    var status by remember { mutableStateOf(taskStatusChoice(task.status)) }
    var due by remember { mutableStateOf(dueOnInput(task.dueOn)) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("할 일 수정") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(task.title, {}, label = { Text("제목") }, enabled = false, modifier = Modifier.fillMaxWidth())
                Text("상태", style = MaterialTheme.typography.labelMedium)
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    TaskLane.entries.forEachIndexed { index, lane ->
                        SegmentedButton(
                            selected = status == lane.title,
                            onClick = { status = lane.title },
                            shape = SegmentedButtonDefaults.itemShape(index, TaskLane.entries.size),
                        ) { Text(lane.title) }
                    }
                }
                OutlinedTextField(
                    due,
                    { due = it },
                    label = { Text("납기 (YYYY-MM-DD)") },
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag("taskDue")
                        .semantics {
                            setText {
                                due = it.text
                                true
                            }
                        },
                )
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val trimmed = dueOnInput(due)
                onSubmit(status, trimmed.ifBlank { null })
            }) { Text("저장") }
        },
        dismissButton = {
            Row {
                if (showDelete) {
                    TextButton(onClick = onDelete) { Text("삭제") }
                }
                TextButton(onClick = onDismiss) { Text("닫기") }
            }
        },
    )
}

@Composable
private fun FormDialog(
    title: String,
    onDismiss: () -> Unit,
    onSubmit: (String, String) -> Unit,
    titleLabel: String = "제목",
    bodyLabel: String = "본문",
    initialTitle: String = "",
    initialBody: String = "",
    initialDue: String = "",
    dueField: Boolean = false,
    titleEnabled: Boolean = true,
    showDelete: Boolean = false,
    onDelete: (() -> Unit)? = null,
) {
    var t by remember { mutableStateOf(initialTitle) }
    var b by remember { mutableStateOf(if (dueField) initialDue else initialBody) }
    var status by remember { mutableStateOf(initialBody) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(t, { t = it }, label = { Text(titleLabel) }, enabled = titleEnabled, modifier = Modifier.fillMaxWidth())
                if (dueField) {
                    OutlinedTextField(status, { status = it }, label = { Text(bodyLabel) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(b, { b = it }, label = { Text("마감 (YYYY-MM-DD)") }, modifier = Modifier.fillMaxWidth())
                } else {
                    OutlinedTextField(b, { b = it }, label = { Text(bodyLabel) }, modifier = Modifier.fillMaxWidth(), minLines = 3)
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                if (dueField) onSubmit(t, b) else onSubmit(t, b)
            }) { Text("저장") }
        },
        dismissButton = {
            Row {
                if (showDelete && onDelete != null) {
                    TextButton(onClick = onDelete) { Text("삭제") }
                }
                TextButton(onClick = onDismiss) { Text("닫기") }
            }
        },
    )
}

@Composable
private fun HomeTab(session: Session, content: CrewContent, modifier: Modifier, onOpenNotice: (Notice) -> Unit) {
    val today = LocalDate.now().toString()
    val sections = homeSections(content.tasks, content.notices, today)
    val quiet = sections.today.isEmpty() && sections.upcoming.isEmpty() && sections.notices.isEmpty()
    when {
        content.loading && content.tasks.isEmpty() && content.notices.isEmpty() -> LoadingPane(modifier)
        quiet && (content.tasksFailed || content.noticesFailed) -> FailedPane(modifier)
        quiet -> EmptyPane(modifier, "아직 소식이 없습니다", "공지와 할 일이 생기면 홈에 모입니다.")
        else -> LazyColumn(modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
                    Column(Modifier.padding(16.dp)) {
                        Text(session.org, style = MaterialTheme.typography.titleMedium)
                        Text("${crewDisplayName(session.repo)} · ${roleLabel(session.teamRole)}")
                    }
                }
            }
            if (sections.today.isNotEmpty()) {
                item { Text("오늘 할 일", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary) }
                items(sections.today, key = { it.id }) { TaskRow(it) }
            }
            if (sections.notices.isNotEmpty()) {
                item { Text("고정 공지", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary) }
                items(sections.notices, key = { it.id }) { notice ->
                    Card(
                        Modifier.fillMaxWidth().clickable { onOpenNotice(notice) },
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    ) {
                        Column(Modifier.padding(14.dp)) {
                            Text(notice.title, style = MaterialTheme.typography.titleMedium)
                            if (notice.body.isNotBlank()) {
                                Text(notice.body, maxLines = 2, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
            if (sections.upcoming.isNotEmpty()) {
                item { Text("다가오는 할 일", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary) }
                items(sections.upcoming, key = { "up-${it.id}" }) { TaskRow(it) }
            }
        }
    }
}

@Composable
private fun TasksTab(content: CrewContent, modifier: Modifier, onRetry: () -> Unit, onOpen: (TaskCard) -> Unit) {
    var mode by remember { mutableIntStateOf(0) }
    val compact = LocalConfiguration.current.screenWidthDp < 600
    val stacked = kanbanUsesStackedLanes(compact)
    when {
        content.loading && content.tasks.isEmpty() && !content.tasksFailed -> LoadingPane(modifier)
        content.tasksFailed && content.tasks.isEmpty() -> FailedPane(modifier, onRetry)
        content.tasks.isEmpty() -> EmptyPane(modifier, "아직 할 일이 없습니다", "+ 로 새 할 일을 추가하세요.")
        else -> Column(modifier.fillMaxSize()) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(16.dp)) {
                listOf("칸반", "마감일").forEachIndexed { index, label ->
                    SegmentedButton(
                        selected = mode == index,
                        onClick = { mode = index },
                        shape = SegmentedButtonDefaults.itemShape(index, 2),
                    ) { Text(label) }
                }
            }
            if (mode == 0) {
                if (stacked) {
                    LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        items(TaskLane.entries) { lane ->
                            KanbanLane(content.tasks, lane, Modifier.fillMaxWidth(), onOpen)
                        }
                    }
                } else {
                    LazyRow(Modifier.weight(1f), contentPadding = PaddingValues(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        items(TaskLane.entries) { lane ->
                            KanbanLane(content.tasks, lane, Modifier.width(260.dp), onOpen)
                        }
                    }
                }
            } else {
                LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    items(content.tasks, key = { it.id }) { card ->
                        Box(Modifier.clickable { onOpen(card) }) { TaskRow(card) }
                    }
                }
            }
        }
    }
}

@Composable
private fun KanbanLane(tasks: List<TaskCard>, lane: TaskLane, modifier: Modifier, onOpen: (TaskCard) -> Unit) {
    val laneTasks = tasks.filter { taskLane(it.status) == lane }
    Surface(modifier, shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("${lane.title} ${laneTasks.size}", style = MaterialTheme.typography.titleSmall)
            laneTasks.forEach { card ->
                Box(Modifier.clickable { onOpen(card) }) { TaskRow(card) }
            }
        }
    }
}

@Composable
private fun DocsTab(
    content: CrewContent,
    modifier: Modifier,
    onRetry: () -> Unit,
    actions: CrewActions,
    onOpenDetail: () -> Unit,
) {
    var search by remember { mutableStateOf("") }
    var pendingPath by remember { mutableStateOf<String?>(null) }
    val listed = filterDocs(content.docs, search)
    val parent = parentDocsPath(content.docsDirPath)
    LaunchedEffect(content.docPath, content.doc, pendingPath) {
        val want = pendingPath ?: return@LaunchedEffect
        if (content.docPath == want) {
            onOpenDetail()
            pendingPath = null
        }
    }
    when {
        content.loading && content.docs.isEmpty() && !content.docFailed -> LoadingPane(modifier)
        content.docFailed && content.docs.isEmpty() -> FailedPane(modifier, onRetry)
        else -> Column(modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (parent != null) {
                    IconButton(onClick = { actions.onListDocs(parent) }) {
                        Icon(Icons.Filled.KeyboardArrowUp, contentDescription = "상위")
                    }
                }
                OutlinedTextField(
                    search,
                    { search = it },
                    modifier = Modifier.weight(1f),
                    label = { Text("이름·경로 검색") },
                    singleLine = true,
                )
            }
            if (listed.isEmpty()) {
                EmptyPane(
                    Modifier.weight(1f),
                    if (content.docs.isEmpty()) "자료실이 비어 있습니다" else "검색 결과가 없습니다",
                    if (content.docs.isEmpty()) "+ 로 자료를 추가하세요." else "다른 검색어를 입력해 보세요.",
                )
            } else {
                LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp)) {
                    items(listed, key = { it.path }) { entry ->
                        DocRow(
                            entry = entry,
                            onClick = {
                                if (entry.isDir) {
                                    actions.onListDocs(entry.path)
                                } else {
                                    pendingPath = entry.path
                                    actions.onOpenDoc(entry.path)
                                }
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun DocRow(entry: DocEntry, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            if (entry.isDir) Icons.Filled.Folder else Icons.Filled.Description,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
        )
        Text(entry.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun DocDetailDialog(
    content: CrewContent,
    role: TeamRole,
    onDismiss: () -> Unit,
    onSave: (path: String, body: String) -> Unit,
    onDelete: () -> Unit,
) {
    var editing by remember { mutableStateOf(false) }
    var draft by remember(content.docPath, content.doc) { mutableStateOf(content.doc) }
    val blocks = docBlocks(content.doc)
    val title = content.docPath.substringAfterLast('/')
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            if (editing) {
                OutlinedTextField(draft, { draft = it }, modifier = Modifier.fillMaxWidth(), minLines = 10)
            } else if (blocks.isEmpty()) {
                Text("내용이 없습니다")
            } else {
                LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.heightIn(max = 360.dp)) {
                    items(blocks.size) { i ->
                        when (val block = blocks[i]) {
                            is DocBlock.Heading -> Text(block.text, style = MaterialTheme.typography.titleMedium)
                            is DocBlock.Bullet -> Text("·  ${block.text}", style = MaterialTheme.typography.bodyMedium)
                            is DocBlock.Paragraph -> Text(block.text, style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                }
            }
        },
        confirmButton = {
            if (editing) {
                TextButton(onClick = { onSave(content.docPath, draft) }) { Text("저장") }
            } else if (role == TeamRole.ADMIN || role == TeamRole.MEMBER) {
                TextButton(onClick = { editing = true }) { Text("편집") }
            }
        },
        dismissButton = {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (!editing && role == TeamRole.ADMIN && content.docSha != null) {
                    TextButton(onClick = onDelete) { Text("삭제") }
                }
                TextButton(onClick = {
                    if (editing) {
                        editing = false
                        draft = content.doc
                    } else {
                        onDismiss()
                    }
                }) { Text(if (editing) "취소" else "닫기") }
            }
        },
    )
}

@Composable
private fun TalkTab(
    content: CrewContent,
    discordEnabled: Boolean,
    draft: String,
    onDraft: (String) -> Unit,
    onSend: () -> Unit,
    modifier: Modifier,
    onRetry: () -> Unit,
    onDiscord: () -> Unit,
    onEdit: (ThreadMessage) -> Unit,
    onDelete: (ThreadMessage) -> Unit,
    onReact: (ThreadMessage) -> Unit,
    role: TeamRole,
    login: String?,
) {
    Column(modifier.fillMaxSize()) {
        when {
            content.loading && content.threads.isEmpty() && !content.threadsFailed -> LoadingPane(Modifier.weight(1f))
            content.threadsFailed && content.threads.isEmpty() -> FailedPane(Modifier.weight(1f), onRetry)
            content.threads.isEmpty() -> EmptyPane(Modifier.weight(1f), "스레드 톡이 없습니다", "아래에 메시지를 남겨 보세요.")
            else -> LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                items(content.threads, key = { it.id }) { msg ->
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(msg.author, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Surface(color = MaterialTheme.colorScheme.surface, shape = MaterialTheme.shapes.medium) {
                            Text(msg.body, Modifier.padding(12.dp), style = MaterialTheme.typography.bodyLarge, lineHeight = 22.sp)
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            TextButton(onClick = { onReact(msg) }) { Text("좋아요") }
                            if (canMutate(role, msg.author, login)) {
                                TextButton(onClick = { onEdit(msg) }) { Text("수정") }
                                TextButton(onClick = { onDelete(msg) }) { Text("삭제") }
                            }
                        }
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(draft, onDraft, modifier = Modifier.weight(1f), label = { Text("메시지") })
            Spacer(Modifier.width(8.dp))
            Button(onClick = onSend) { Text("보내기") }
        }
        if (discordEnabled) {
            Button(onClick = onDiscord, Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 12.dp)) {
                Text("바로 대화")
            }
        }
    }
}

@Composable
private fun TaskRow(task: TaskCard) {
    val lane = taskLane(task.status)
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(task.title, style = MaterialTheme.typography.titleMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Surface(color = MaterialTheme.colorScheme.primaryContainer, shape = MaterialTheme.shapes.small) {
                    Text(lane.title, Modifier.padding(horizontal = 8.dp, vertical = 2.dp), style = MaterialTheme.typography.labelMedium)
                }
                Text(formatDue(task.dueOn), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable private fun LoadingPane(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
}

@Composable
private fun EmptyPane(modifier: Modifier = Modifier, title: String, body: String) {
    Column(modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Text(title, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        Text(body, Modifier.padding(top = 8.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
    }
}

@Composable
private fun FailedPane(modifier: Modifier = Modifier, onRetry: (() -> Unit)? = null) {
    Column(modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Text("내용을 불러오지 못했습니다", style = MaterialTheme.typography.titleMedium)
        if (onRetry != null) {
            Button(onClick = onRetry, Modifier.padding(top = 16.dp)) { Text("다시 시도") }
        }
    }
}
