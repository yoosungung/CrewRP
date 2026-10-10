@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package app.crewrp.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CalendarMonth
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
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Image
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.MenuAnchorType
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
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setText
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.crewrp.CrewContent
import app.crewrp.core.AccountLink
import app.crewrp.core.AttachmentEntry
import app.crewrp.core.CrewRepo
import app.crewrp.core.DiscussionCategory
import app.crewrp.core.DocBlock
import app.crewrp.core.DocEntry
import app.crewrp.core.DocsLibraryItem
import app.crewrp.core.Notice
import app.crewrp.core.Session
import app.crewrp.core.TaskCard
import app.crewrp.core.TaskLane
import app.crewrp.core.TeamRole
import app.crewrp.core.ThreadMessage
import android.provider.OpenableColumns
import app.crewrp.core.canMutate
import app.crewrp.core.crewDisplayName
import app.crewrp.core.crewOwnerName
import app.crewrp.core.docBlocks
import app.crewrp.core.dueOnInput
import app.crewrp.core.formatDue
import app.crewrp.core.formatDueOnDate
import app.crewrp.core.homeSections
import app.crewrp.core.kanbanUsesStackedLanes
import app.crewrp.core.listedLibrary
import app.crewrp.core.parentDocsPath
import app.crewrp.core.parseDueOnDate
import app.crewrp.core.roleLabel
import app.crewrp.core.taskLane
import app.crewrp.core.taskStatusChoice
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

private fun mimeTypeForFileName(name: String): String =
    when (name.substringAfterLast('.', "").lowercase()) {
        "png" -> "image/png"
        "jpg", "jpeg" -> "image/jpeg"
        "gif" -> "image/gif"
        "webp" -> "image/webp"
        "heic" -> "image/heic"
        "pdf" -> "application/pdf"
        "txt" -> "text/plain"
        "md" -> "text/markdown"
        else -> "application/octet-stream"
    }

private fun libraryIcon(item: DocsLibraryItem): ImageVector =
    when (item) {
        is DocsLibraryItem.Doc -> if (item.entry.isDir) Icons.Filled.Folder else Icons.Filled.Description
        is DocsLibraryItem.Attachment -> {
            val n = item.entry.name.lowercase()
            when {
                n.endsWith(".pdf") -> Icons.Filled.Description
                item.entry.isPreviewable -> Icons.Filled.Image
                else -> Icons.Filled.AttachFile
            }
        }
    }

data class CrewActions(
    val onCreateBoardPost: (categoryId: String, title: String, body: String) -> Unit,
    val onUpdateBoardPost: (Notice, title: String, body: String) -> Unit,
    val onDeleteBoardPost: (Notice) -> Unit,
    val onOpenBoardCategory: (DiscussionCategory) -> Unit,
    val onClearBoardCategory: () -> Unit,
    val onCreateTask: (title: String, body: String, status: String, dueOn: String?) -> Unit,
    val onUpdateTask: (TaskCard, title: String, body: String, status: String, dueOn: String?) -> Unit,
    val onDeleteTask: (TaskCard) -> Unit,
    val onSaveDoc: (path: String, content: String) -> Unit,
    val onDeleteDoc: () -> Unit,
    val onOpenDoc: (path: String) -> Unit,
    val onListDocs: (path: String) -> Unit,
    val onUploadAttachment: (name: String, bytes: ByteArray, contentType: String) -> Unit,
    val onOpenAttachment: (AttachmentEntry) -> Unit,
    val onLoadTaskComments: (issueNumber: Int) -> Unit,
    val onPostTaskComment: (issueNumber: Int, body: String) -> Unit,
    val onUpdateTaskComment: (commentId: String, body: String) -> Unit,
    val onDeleteTaskComment: (commentId: String) -> Unit,
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
    discordLink: AccountLink?,
    discordEnabled: Boolean,
    isAdmin: Boolean,
    serverDraft: String,
    channelDraft: String,
    onServerDraft: (String) -> Unit,
    onChannelDraft: (String) -> Unit,
    actions: CrewActions,
    onRefresh: () -> Unit,
    onLinkDiscord: () -> Unit,
    onUnlinkDiscord: () -> Unit,
    onDiscord: () -> Unit,
    onSaveDiscordSettings: () -> Unit,
    onLoadCrewSettings: () -> Unit,
    onLogout: () -> Unit,
) {
    var tab by remember { mutableIntStateOf(0) }
    var compose by remember { mutableStateOf<ComposeKind?>(null) }
    var editingNotice by remember { mutableStateOf<Notice?>(null) }
    var editingTask by remember { mutableStateOf<TaskCard?>(null) }
    var viewingDoc by remember { mutableStateOf(false) }
    var docsAddMenu by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val pickAttachment = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        val resolver = context.contentResolver
        val name = resolver.query(uri, null, null, null, null)?.use { cursor ->
            val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (cursor.moveToFirst() && idx >= 0) cursor.getString(idx) else null
        } ?: uri.lastPathSegment ?: "attachment.bin"
        val mime = resolver.getType(uri) ?: mimeTypeForFileName(name)
        val bytes = resolver.openInputStream(uri)?.use { it.readBytes() } ?: return@rememberLauncherForActivityResult
        actions.onUploadAttachment(name, bytes, mime)
    }
    val name = crewDisplayName(session.repo)

    LaunchedEffect(tab) {
        if (tab == 3) onLoadCrewSettings()
    }

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
                1 -> FloatingActionButton(onClick = { compose = ComposeKind.Task }) {
                    Icon(Icons.Filled.Add, contentDescription = "작성")
                }
                2 -> Box {
                    FloatingActionButton(onClick = { docsAddMenu = true }) {
                        Icon(Icons.Filled.Add, contentDescription = "추가")
                    }
                    DropdownMenu(expanded = docsAddMenu, onDismissRequest = { docsAddMenu = false }) {
                        DropdownMenuItem(
                            text = { Text("문서 작성") },
                            onClick = {
                                docsAddMenu = false
                                compose = ComposeKind.Doc
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("파일 첨부") },
                            onClick = {
                                docsAddMenu = false
                                pickAttachment.launch(arrayOf("*/*"))
                            },
                        )
                    }
                }
                3 -> if (content.selectedCategory != null) {
                    FloatingActionButton(onClick = { compose = ComposeKind.BoardPost }) {
                        Icon(Icons.Filled.Add, contentDescription = "글 작성")
                    }
                }
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
                0 -> HomeTab(session, content, Modifier.weight(1f))
                1 -> TasksTab(content, Modifier.weight(1f), onRefresh, onOpen = { editingTask = it })
                2 -> DocsTab(
                    content,
                    Modifier.weight(1f),
                    onRefresh,
                    actions,
                    onOpenDetail = { viewingDoc = true },
                )
                else -> TalkTab(
                    content = content,
                    discordLink = discordLink,
                    discordEnabled = discordEnabled,
                    isAdmin = isAdmin,
                    serverDraft = serverDraft,
                    channelDraft = channelDraft,
                    onServerDraft = onServerDraft,
                    onChannelDraft = onChannelDraft,
                    modifier = Modifier.weight(1f),
                    onLink = onLinkDiscord,
                    onUnlink = onUnlinkDiscord,
                    onDiscord = onDiscord,
                    onSaveDiscordSettings = onSaveDiscordSettings,
                    onOpenCategory = actions.onOpenBoardCategory,
                    onClearCategory = actions.onClearBoardCategory,
                    onOpenPost = { editingNotice = it },
                )
            }
        }
    }

    when (val kind = compose) {
        ComposeKind.BoardPost -> FormDialog(
            title = "글 작성",
            onDismiss = { compose = null },
            onSubmit = { t, b ->
                val cat = content.selectedCategory ?: return@FormDialog
                actions.onCreateBoardPost(cat.id, t, b)
                compose = null
            },
        )
        ComposeKind.Task -> TaskFormDialog(
            content = content,
            actions = actions,
            role = session.teamRole,
            onDismiss = { compose = null },
            onSubmit = { t, body, status, due ->
                actions.onCreateTask(t, body, status, due)
                compose = null
            },
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
            title = "글 수정",
            initialTitle = notice.title,
            initialBody = notice.body,
            showDelete = canMutate(session.teamRole, notice.authorLogin, content.currentLogin),
            onDismiss = { editingNotice = null },
            onSubmit = { t, b -> actions.onUpdateBoardPost(notice, t, b); editingNotice = null },
            onDelete = { actions.onDeleteBoardPost(notice); editingNotice = null },
        )
    }
    editingTask?.let { task ->
        TaskFormDialog(
            content = content,
            actions = actions,
            role = session.teamRole,
            task = task,
            showDelete = session.teamRole == TeamRole.ADMIN,
            onDismiss = { editingTask = null },
            onSubmit = { t, body, status, due ->
                actions.onUpdateTask(task, t, body, status, due)
                editingTask = null
            },
            onDelete = { actions.onDeleteTask(task); editingTask = null },
        )
    }
}

private enum class ComposeKind { BoardPost, Task, Doc }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TaskFormDialog(
    content: CrewContent,
    actions: CrewActions,
    role: TeamRole,
    onDismiss: () -> Unit,
    onSubmit: (title: String, body: String, status: String, dueOn: String?) -> Unit,
    task: TaskCard? = null,
    showDelete: Boolean = false,
    onDelete: (() -> Unit)? = null,
) {
    var fieldTitle by remember { mutableStateOf(task?.title.orEmpty()) }
    var fieldBody by remember { mutableStateOf(task?.body.orEmpty()) }
    var status by remember { mutableStateOf(task?.let { taskStatusChoice(it.status) } ?: TaskLane.INBOX.title) }
    var due by remember { mutableStateOf(dueOnInput(task?.dueOn)) }
    var statusExpanded by remember { mutableStateOf(false) }
    var draftComment by remember { mutableStateOf("") }
    var editingComment by remember { mutableStateOf<ThreadMessage?>(null) }
    var editDraft by remember { mutableStateOf("") }
    val issueNumber = task?.issueNumber
    val dialogTitle = fieldTitle.trim().ifEmpty { "새 할 일" }
    LaunchedEffect(issueNumber) {
        if (issueNumber != null) actions.onLoadTaskComments(issueNumber)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(dialogTitle, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        text = {
            Column(
                Modifier.heightIn(max = 480.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    fieldTitle,
                    { fieldTitle = it },
                    label = { Text("제목") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )
                OutlinedTextField(
                    fieldBody,
                    { fieldBody = it },
                    label = { Text("내용") },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 3,
                )
                ExposedDropdownMenuBox(expanded = statusExpanded, onExpandedChange = { statusExpanded = it }) {
                    OutlinedTextField(
                        value = status,
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("상태") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = statusExpanded) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .menuAnchor(type = MenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(expanded = statusExpanded, onDismissRequest = { statusExpanded = false }) {
                        TaskLane.entries.forEach { lane ->
                            DropdownMenuItem(
                                text = { Text(lane.title) },
                                onClick = {
                                    status = lane.title
                                    statusExpanded = false
                                },
                            )
                        }
                    }
                }
                DueOnField(
                    due = due,
                    onDueChange = { due = it },
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
                if (issueNumber != null) {
                    Text("댓글", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
                    if (content.taskComments.isEmpty()) {
                        Text("아직 댓글이 없습니다.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    } else {
                        LazyColumn(Modifier.heightIn(max = 160.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            items(content.taskComments, key = { it.id }) { comment ->
                                Column {
                                    Text("@${comment.author}", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    Text(comment.body, style = MaterialTheme.typography.bodyMedium)
                                    if (canMutate(role, comment.author, content.currentLogin)) {
                                        Row {
                                            TextButton(onClick = {
                                                editingComment = comment
                                                editDraft = comment.body
                                            }) { Text("수정") }
                                            TextButton(onClick = { actions.onDeleteTaskComment(comment.id) }) { Text("삭제") }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    OutlinedTextField(
                        draftComment,
                        { draftComment = it },
                        label = { Text("댓글 작성") },
                        modifier = Modifier.fillMaxWidth(),
                        minLines = 2,
                    )
                    TextButton(
                        onClick = {
                            val text = draftComment.trim()
                            if (text.isNotEmpty()) {
                                actions.onPostTaskComment(issueNumber, text)
                                draftComment = ""
                            }
                        },
                        enabled = draftComment.isNotBlank(),
                    ) { Text("댓글 등록") }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    val trimmed = dueOnInput(due)
                    onSubmit(fieldTitle, fieldBody, status, trimmed.ifBlank { null })
                },
                enabled = fieldTitle.isNotBlank(),
            ) { Text("저장") }
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
    editingComment?.let { comment ->
        AlertDialog(
            onDismissRequest = { editingComment = null },
            title = { Text("댓글 수정") },
            text = {
                OutlinedTextField(editDraft, { editDraft = it }, modifier = Modifier.fillMaxWidth(), minLines = 2)
            },
            confirmButton = {
                TextButton(onClick = {
                    actions.onUpdateTaskComment(comment.id, editDraft)
                    editingComment = null
                }) { Text("저장") }
            },
            dismissButton = { TextButton(onClick = { editingComment = null }) { Text("취소") } },
        )
    }
}

@Composable
private fun DueOnField(
    due: String,
    onDueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var showPicker by remember { mutableStateOf(false) }
    val initialMillis = parseDueOnDate(due)
        ?.atStartOfDay(ZoneOffset.UTC)
        ?.toInstant()
        ?.toEpochMilli()
    Row(
        modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            if (dueOnInput(due).isEmpty()) "납기 없음" else formatDue(due),
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyLarge,
        )
        if (dueOnInput(due).isNotEmpty()) {
            TextButton(onClick = { onDueChange("") }) { Text("지우기") }
        }
        IconButton(onClick = { showPicker = true }) {
            Icon(Icons.Filled.CalendarMonth, contentDescription = "캘린더")
        }
    }
    if (showPicker) {
        val state = rememberDatePickerState(initialSelectedDateMillis = initialMillis)
        DatePickerDialog(
            onDismissRequest = { showPicker = false },
            confirmButton = {
                TextButton(onClick = {
                    state.selectedDateMillis?.let { millis ->
                        val local = Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate()
                        onDueChange(formatDueOnDate(local))
                    }
                    showPicker = false
                }) { Text("선택") }
            },
            dismissButton = {
                TextButton(onClick = { showPicker = false }) { Text("취소") }
            },
        ) {
            DatePicker(state = state)
        }
    }
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
    titleEnabled: Boolean = true,
    showDelete: Boolean = false,
    onDelete: (() -> Unit)? = null,
) {
    var t by remember { mutableStateOf(initialTitle) }
    var b by remember { mutableStateOf(initialBody) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(t, { t = it }, label = { Text(titleLabel) }, enabled = titleEnabled, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(b, { b = it }, label = { Text(bodyLabel) }, modifier = Modifier.fillMaxWidth(), minLines = 3)
            }
        },
        confirmButton = {
            TextButton(onClick = { onSubmit(t, b) }) { Text("저장") }
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
private fun HomeTab(session: Session, content: CrewContent, modifier: Modifier) {
    val today = LocalDate.now().toString()
    val sections = homeSections(content.tasks, today)
    val quiet = sections.today.isEmpty() && sections.upcoming.isEmpty() && content.readme.isEmpty()
    when {
        content.loading && content.tasks.isEmpty() && content.readme.isEmpty() -> LoadingPane(modifier)
        quiet && (content.tasksFailed || content.readmeFailed) -> FailedPane(modifier)
        quiet -> EmptyPane(modifier, "아직 소식이 없습니다", "할 일을 추가하거나 README를 등록해 보세요.")
        else -> LazyColumn(modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
                    Column(Modifier.padding(16.dp)) {
                        Text(session.org, style = MaterialTheme.typography.titleMedium)
                        Text("${crewDisplayName(session.repo)} · ${roleLabel(session.teamRole)}")
                    }
                }
            }
            if (content.readme.isNotEmpty()) {
                item { Text("소개", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary) }
                item {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        docBlocks(content.readme).forEach { block ->
                            when (block) {
                                is DocBlock.Heading -> Text(block.text, style = MaterialTheme.typography.titleMedium)
                                is DocBlock.Bullet -> Text("·  ${block.text}")
                                is DocBlock.Paragraph -> Text(block.text, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
            if (sections.today.isNotEmpty()) {
                item { Text("오늘 할 일", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary) }
                items(sections.today, key = { it.id }) { TaskRow(it) }
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
                    LazyRow(
                        Modifier.weight(1f),
                        contentPadding = PaddingValues(16.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
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
    var searchFocused by remember { mutableStateOf(false) }
    var pendingPath by remember { mutableStateOf<String?>(null) }
    val listed = listedLibrary(
        content.docs,
        content.docsTree,
        content.attachments,
        content.docsDirPath,
        search,
    )
    val parent = parentDocsPath(content.docsDirPath)
    val libraryEmpty = content.docs.isEmpty() && content.attachments.isEmpty()
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    fun dismissSearch() {
        searchFocused = false
        focusManager.clearFocus()
        keyboard?.hide()
    }
    LaunchedEffect(content.docPath, content.doc, pendingPath) {
        val want = pendingPath ?: return@LaunchedEffect
        if (content.docPath == want) {
            onOpenDetail()
            pendingPath = null
        }
    }
    when {
        content.loading && libraryEmpty && !content.docFailed -> LoadingPane(modifier)
        content.docFailed && libraryEmpty -> FailedPane(modifier, onRetry)
        else -> Column(modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (parent != null) {
                    IconButton(onClick = {
                        dismissSearch()
                        actions.onListDocs(parent)
                    }) {
                        Icon(Icons.Filled.KeyboardArrowUp, contentDescription = "상위")
                    }
                }
                OutlinedTextField(
                    search,
                    { search = it },
                    modifier = Modifier
                        .weight(1f)
                        .onFocusChanged { searchFocused = it.isFocused },
                    label = { Text("이름·경로 검색") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { dismissSearch() }),
                )
            }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                if (listed.isEmpty()) {
                    EmptyPane(
                        Modifier.fillMaxSize(),
                        if (libraryEmpty) "자료실이 비어 있습니다" else "검색 결과가 없습니다",
                        if (libraryEmpty) "+ 로 문서·첨부를 추가하세요." else "다른 검색어를 입력해 보세요.",
                    )
                } else {
                    LazyColumn(
                        Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp),
                    ) {
                        items(listed, key = { it.key }) { item ->
                            LibraryRow(
                                item = item,
                                onClick = {
                                    dismissSearch()
                                    when (item) {
                                        is DocsLibraryItem.Doc -> {
                                            val entry = item.entry
                                            if (entry.isDir) {
                                                actions.onListDocs(entry.path)
                                            } else {
                                                pendingPath = entry.path
                                                actions.onOpenDoc(entry.path)
                                            }
                                        }
                                        is DocsLibraryItem.Attachment -> actions.onOpenAttachment(item.entry)
                                    }
                                },
                            )
                        }
                    }
                }
                if (searchFocused) {
                    Box(
                        Modifier
                            .fillMaxSize()
                            .clickable(
                                interactionSource = remember { MutableInteractionSource() },
                                indication = null,
                                onClick = { dismissSearch() },
                            ),
                    )
                }
            }
        }
    }
}

@Composable
private fun LibraryRow(item: DocsLibraryItem, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            libraryIcon(item),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
        )
        Text(item.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
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
    discordLink: AccountLink?,
    discordEnabled: Boolean,
    isAdmin: Boolean,
    serverDraft: String,
    channelDraft: String,
    onServerDraft: (String) -> Unit,
    onChannelDraft: (String) -> Unit,
    modifier: Modifier,
    onLink: () -> Unit,
    onUnlink: () -> Unit,
    onDiscord: () -> Unit,
    onSaveDiscordSettings: () -> Unit,
    onOpenCategory: (DiscussionCategory) -> Unit,
    onClearCategory: () -> Unit,
    onOpenPost: (Notice) -> Unit,
) {
    LazyColumn(
        modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Text("바로 대화", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (discordLink != null) {
                    Text(
                        "연결됨: @${discordLink.username}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (discordEnabled) {
                        Button(onClick = onDiscord, Modifier.fillMaxWidth()) { Text("바로 대화") }
                    } else if (isAdmin) {
                        Text(
                            "이 크루 Discord 서버·채널을 repo에 등록합니다.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        OutlinedTextField(serverDraft, onServerDraft, Modifier.fillMaxWidth(), label = { Text("서버 ID") })
                        OutlinedTextField(channelDraft, onChannelDraft, Modifier.fillMaxWidth(), label = { Text("채널 ID") })
                        Button(onClick = onSaveDiscordSettings, Modifier.fillMaxWidth()) { Text("서버·채널 저장") }
                    } else {
                        Text(
                            "운영진이 Discord 서버·채널을 등록하면 바로 대화를 열 수 있습니다.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    TextButton(onClick = onUnlink) { Text("Discord 연결 해제") }
                } else {
                    Text(
                        "잡담과 음성은 Discord에서 이어갑니다.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Button(onClick = onLink, Modifier.fillMaxWidth()) { Text("Discord 연결") }
                }
            }
        }
        val category = content.selectedCategory
        if (category != null) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(onClick = onClearCategory) { Text("← 게시판") }
                    Text(category.name, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
                }
            }
            when {
                content.boardFailed && content.boardPosts.isEmpty() ->
                    item { Text("글을 불러오지 못했습니다.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                content.boardPosts.isEmpty() ->
                    item { Text("글이 없습니다. + 로 작성하세요.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                else -> items(content.boardPosts, key = { it.id }) { post ->
                    Card(
                        Modifier.fillMaxWidth().clickable { onOpenPost(post) },
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    ) {
                        Column(Modifier.padding(14.dp)) {
                            Text(post.title, style = MaterialTheme.typography.titleMedium)
                            if (post.body.isNotBlank()) {
                                Text(post.body, maxLines = 2, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        } else {
            item {
                Text("게시판", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            }
            when {
                content.boardFailed && content.discussionCategories.isEmpty() ->
                    item { Text("카테고리를 불러오지 못했습니다.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                content.discussionCategories.isEmpty() ->
                    item { Text("게시판 카테고리가 없습니다.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                else -> items(content.discussionCategories, key = { it.id }) { cat ->
                    Card(
                        Modifier.fillMaxWidth().clickable { onOpenCategory(cat) },
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    ) {
                        Text(cat.name, Modifier.padding(14.dp), style = MaterialTheme.typography.titleMedium)
                    }
                }
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
            if (task.body.isNotBlank()) {
                Text(
                    task.body,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
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
