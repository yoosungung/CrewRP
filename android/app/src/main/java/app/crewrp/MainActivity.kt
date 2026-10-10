package app.crewrp

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import app.crewrp.core.AccountLink
import app.crewrp.core.AuthBridgeClient
import app.crewrp.core.AuthConfig
import app.crewrp.core.AuthFlow
import app.crewrp.core.CacheStore
import app.crewrp.core.CrewDiscordSettings
import app.crewrp.core.CrewRepo
import app.crewrp.core.CrewSettings
import app.crewrp.core.CrewSettingsClient
import app.crewrp.core.CrewSettingsFile
import app.crewrp.core.DiscordAuthConfig
import app.crewrp.core.DiscordDeepLink
import app.crewrp.core.DiscordLinkFlow
import app.crewrp.core.PendingLogin
import app.crewrp.core.PendingLoginStore
import app.crewrp.core.Session
import app.crewrp.core.TeamRole
import app.crewrp.core.TokenStore
import app.crewrp.core.UrlHttpTransport
import app.crewrp.core.discordConfigured
import app.crewrp.core.writeFailureMessage
import app.crewrp.ui.CrewActions
import app.crewrp.ui.CrewRPTheme
import app.crewrp.ui.CrewShell
import app.crewrp.ui.CrewStartScreen
import app.crewrp.ui.LoginScreen
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

class EncryptedPrefsTokenStore(context: Context) : TokenStore, PendingLoginStore {
    private val prefs = EncryptedSharedPreferences.create(
        context,
        "crewrp_tokens",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    override fun saveAccessToken(token: String) {
        prefs.edit().putString("access_token", token).apply()
    }

    override fun loadAccessToken(): String? = prefs.getString("access_token", null)

    override fun clearAccessToken() {
        prefs.edit().remove("access_token").apply()
    }

    override fun save(pending: PendingLogin) {
        prefs.edit()
            .putString("oauth_state", pending.state)
            .putString("oauth_verifier", pending.codeVerifier)
            .apply()
    }

    override fun load(): PendingLogin? {
        val state = prefs.getString("oauth_state", null) ?: return null
        val verifier = prefs.getString("oauth_verifier", null) ?: return null
        return PendingLogin(state, verifier)
    }

    override fun clear() {
        prefs.edit().remove("oauth_state").remove("oauth_verifier").apply()
    }

    fun discordPending(): PendingLoginStore = object : PendingLoginStore {
        override fun save(pending: PendingLogin) {
            prefs.edit()
                .putString("discord_oauth_state", pending.state)
                .putString("discord_oauth_verifier", pending.codeVerifier)
                .apply()
        }

        override fun load(): PendingLogin? {
            val state = prefs.getString("discord_oauth_state", null) ?: return null
            val verifier = prefs.getString("discord_oauth_verifier", null) ?: return null
            return PendingLogin(state, verifier)
        }

        override fun clear() {
            prefs.edit().remove("discord_oauth_state").remove("discord_oauth_verifier").apply()
        }
    }
}

class MainActivity : ComponentActivity() {
    private lateinit var flow: AuthFlow
    private lateinit var discordFlow: DiscordLinkFlow
    private lateinit var tokens: EncryptedPrefsTokenStore
    private lateinit var cache: CacheStore
    private var onRepos: ((List<CrewRepo>) -> Unit)? = null
    private var onLoginError: ((String) -> Unit)? = null
    private var onDiscordLinked: ((AccountLink) -> Unit)? = null
    private var onDiscordLinkError: ((String) -> Unit)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val transport = UrlHttpTransport()
        val config = AuthConfig(
            clientId = BuildConfig.GITHUB_CLIENT_ID,
            redirectUri = "crewrp://oauth/callback",
            authBridgeBaseUrl = BuildConfig.AUTH_BRIDGE_URL,
        )
        tokens = EncryptedPrefsTokenStore(this)
        cache = AndroidCacheStore(this)
        val bridge = AuthBridgeClient(config.authBridgeBaseUrl, transport)
        flow = AuthFlow(
            config,
            bridge,
            app.crewrp.core.GitHubMembershipClient(transport),
            tokens,
            cache,
            tokens,
        )
        discordFlow = DiscordLinkFlow(
            DiscordAuthConfig(
                clientId = BuildConfig.DISCORD_CLIENT_ID,
                authBridgeBaseUrl = config.authBridgeBaseUrl,
            ),
            bridge,
            cache,
            tokens.discordPending(),
        )

        setContent {
            var repos by remember { mutableStateOf<List<CrewRepo>>(emptyList()) }
            var session by remember { mutableStateOf(cache.session()) }
            var error by remember { mutableStateOf<String?>(null) }
            var content by remember { mutableStateOf(CrewContent(loading = session != null)) }
            var discordLink by remember { mutableStateOf(discordFlow.linkedDiscord()) }
            var crewSettings by remember { mutableStateOf<CrewSettingsFile?>(null) }
            var serverDraft by remember { mutableStateOf("") }
            var channelDraft by remember { mutableStateOf("") }
            var refreshTick by remember { mutableIntStateOf(0) }
            var loadId by remember { mutableIntStateOf(0) }
            var deviceRegistered by remember { mutableStateOf(false) }

            fun loadCrewSettings(activeSession: Session) {
                val token = tokens.loadAccessToken() ?: return
                val parts = activeSession.repo.split("/")
                if (parts.size != 2) return
                thread {
                    runCatching {
                        CrewSettingsClient(transport, cache).load(parts[0], parts[1], token)
                    }.onSuccess { file ->
                        runOnUiThread {
                            crewSettings = file
                            file?.settings?.discord?.let {
                                serverDraft = it.serverId
                                channelDraft = it.channelId
                            }
                        }
                    }.onFailure { Log.e("CrewRP", "crew settings load failed", it) }
                }
            }
            onRepos = {
                repos = it
                error = if (it.isEmpty()) "운영 권한이 있는 보관소가 없습니다." else null
            }
            onLoginError = { error = it }
            onDiscordLinked = { discordLink = it }
            onDiscordLinkError = { msg ->
                content = content.copy(writeError = msg)
            }

            val active = session
            LaunchedEffect(active?.repo, refreshTick) {
                if (active == null) return@LaunchedEffect
                val token = tokens.loadAccessToken()
                if (token == null) {
                    content = CrewContent(
                        tasksFailed = true,
                        noticesFailed = true,
                        docFailed = true,
                    )
                    return@LaunchedEffect
                }
                val previous = content
                content = previous.copy(loading = true)
                val request = loadId + 1
                loadId = request
                thread {
                    val loaded = fetchCrewContent(
                        active,
                        token,
                        cache,
                        BuildConfig.PROJECT_NUMBER.toIntOrNull() ?: 1,
                        forceNetwork = refreshTick > 0,
                        docsDirPath = previous.docsDirPath,
                    )
                    runOnUiThread {
                        if (request != loadId) return@runOnUiThread
                        content = loaded.copy(
                            tasks = if (loaded.tasksFailed && previous.tasks.isNotEmpty()) previous.tasks else loaded.tasks,
                            notices = if (loaded.noticesFailed && previous.notices.isNotEmpty()) previous.notices else loaded.notices,
                            docs = if (loaded.docFailed && previous.docs.isNotEmpty()) previous.docs else loaded.docs,
                            docsTree = if (loaded.docFailed && previous.docsTree.isNotEmpty()) previous.docsTree else loaded.docsTree,
                            docsDirPath = if (loaded.docFailed && previous.docs.isNotEmpty()) previous.docsDirPath else loaded.docsDirPath,
                            doc = previous.doc,
                            docPath = previous.docPath,
                            docSha = previous.docSha,
                        )
                    }
                }
                if (!deviceRegistered) {
                    deviceRegistered = true
                    thread {
                        registerDeviceToken(BuildConfig.PUSH_BRIDGE_URL, active.org, "fcm-token-placeholder")
                    }
                }
            }

            CrewRPTheme {
                when {
                    active != null -> {
                        fun runWrite(refresh: Boolean = true, block: (CrewWriter) -> Unit) {
                            val token = tokens.loadAccessToken() ?: return
                            thread {
                                runCatching {
                                    block(
                                        CrewWriter(
                                            active,
                                            token,
                                            cache,
                                            BuildConfig.PROJECT_NUMBER.toIntOrNull() ?: 1,
                                        ),
                                    )
                                }.onSuccess {
                                    runOnUiThread {
                                        content = content.copy(writeError = null)
                                        if (refresh) refreshTick += 1
                                    }
                                }.onFailure { err ->
                                    Log.e("CrewRP", "write failed", err)
                                    runOnUiThread {
                                        content = content.copy(writeError = writeFailureMessage(err.message ?: err.toString()))
                                    }
                                }
                            }
                        }
                        CrewShell(
                            session = active,
                            content = content,
                            discordLink = discordLink,
                            discordEnabled = crewSettings?.settings?.discord?.isConfigured == true,
                            isAdmin = active.teamRole == TeamRole.ADMIN,
                            serverDraft = serverDraft,
                            channelDraft = channelDraft,
                            onServerDraft = { serverDraft = it },
                            onChannelDraft = { channelDraft = it },
                            actions = CrewActions(
                                onCreateNotice = { title, body ->
                                    val setup = content.discussionSetup ?: return@CrewActions
                                    runWrite { it.createNotice(title, body, setup) }
                                },
                                onUpdateNotice = { notice, title, body ->
                                    runWrite { it.updateNotice(notice.id, title, body) }
                                },
                                onDeleteNotice = { notice -> runWrite { it.deleteNotice(notice.id) } },
                                onCreateTask = { title, body, status, due ->
                                    runWrite { it.createTask(title, body, status, due) }
                                },
                                onUpdateTask = { card, title, body, status, due ->
                                    val meta = content.projectMeta ?: return@CrewActions
                                    runWrite { it.updateTask(meta, card, title, body, status, due) }
                                },
                                onDeleteTask = { card ->
                                    val meta = content.projectMeta ?: return@CrewActions
                                    runWrite { it.deleteTask(meta, card) }
                                },
                                onSaveDoc = { path, text ->
                                    runWrite {
                                        it.saveDoc(path, text, if (path == content.docPath) content.docSha else null)
                                    }
                                },
                                onDeleteDoc = {
                                    val sha = content.docSha ?: return@CrewActions
                                    runWrite { it.deleteDoc(content.docPath, sha) }
                                },
                                onOpenDoc = { path ->
                                    runWrite(refresh = false) { writer ->
                                        val file = writer.openDoc(path)
                                        runOnUiThread {
                                            content = content.copy(
                                                docPath = file.path,
                                                doc = file.content,
                                                docSha = file.sha,
                                                docFailed = false,
                                                writeError = null,
                                            )
                                        }
                                    }
                                },
                                onListDocs = { path ->
                                    runWrite(refresh = false) { writer ->
                                        val entries = writer.listDocs(path)
                                        runOnUiThread {
                                            content = content.copy(
                                                docs = entries,
                                                docsDirPath = path,
                                                docFailed = false,
                                                writeError = null,
                                            )
                                        }
                                    }
                                },
                            ),
                            onRefresh = { refreshTick += 1 },
                            onLinkDiscord = {
                                content = content.copy(writeError = null)
                                val challenge = discordFlow.beginLink()
                                startActivity(
                                    Intent(Intent.ACTION_VIEW, Uri.parse(challenge.authorizeUrl)).apply {
                                        addCategory(Intent.CATEGORY_BROWSABLE)
                                    },
                                )
                            },
                            onUnlinkDiscord = {
                                discordFlow.unlink()
                                discordLink = null
                            },
                            onDiscord = {
                                val discord = crewSettings?.settings?.discord
                                if (discord != null && discord.isConfigured) {
                                    val url = DiscordDeepLink.voiceChannelUrl(discord.serverId, discord.channelId)
                                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                                }
                            },
                            onSaveDiscordSettings = {
                                val server = serverDraft.trim()
                                val channel = channelDraft.trim()
                                if (!discordConfigured(server, channel)) {
                                    content = content.copy(writeError = "서버 ID와 채널 ID를 모두 입력해 주세요.")
                                    return@CrewShell
                                }
                                val token = tokens.loadAccessToken() ?: return@CrewShell
                                val parts = active.repo.split("/")
                                if (parts.size != 2) return@CrewShell
                                thread {
                                    runCatching {
                                        CrewSettingsClient(transport, cache).save(
                                            parts[0],
                                            parts[1],
                                            token,
                                            CrewSettings(CrewDiscordSettings(server, channel)),
                                            crewSettings?.sha,
                                        )
                                    }.onSuccess { file ->
                                        runOnUiThread {
                                            crewSettings = file
                                            content = content.copy(writeError = null)
                                        }
                                    }.onFailure { err ->
                                        Log.e("CrewRP", "crew settings save failed", err)
                                        runOnUiThread {
                                            content = content.copy(
                                                writeError = writeFailureMessage(err.message ?: err.toString()),
                                            )
                                        }
                                    }
                                }
                            },
                            onLoadCrewSettings = { loadCrewSettings(active) },
                            onLogout = {
                                flow.logout()
                                session = null
                                repos = emptyList()
                                content = CrewContent()
                                discordLink = null
                                crewSettings = null
                                serverDraft = ""
                                channelDraft = ""
                                error = null
                                deviceRegistered = false
                            },
                        )
                    }
                    repos.isNotEmpty() -> CrewStartScreen(
                        repos = repos,
                        error = error,
                        onSelect = { repo ->
                            error = null
                            thread {
                                runCatching { flow.registerCrew(repo) }
                                    .onSuccess { registered ->
                                        runOnUiThread {
                                            session = registered
                                            content = CrewContent(loading = true)
                                            error = null
                                        }
                                    }
                                    .onFailure { err ->
                                        Log.e("CrewRP", "register crew failed", err)
                                        runOnUiThread {
                                            error = "크루를 시작하지 못했습니다. 잠시 후 다시 시도해 주세요."
                                        }
                                    }
                            }
                        },
                        onLogout = {
                            flow.logout()
                            session = null
                            repos = emptyList()
                            content = CrewContent()
                            error = null
                            deviceRegistered = false
                        },
                    )
                    else -> LoginScreen(error) {
                        error = null
                        val challenge = flow.beginLogin()
                        // Custom Tabs + Chrome password-fill accessory often hides the soft
                        // keyboard on username/email; external browser shows IME reliably.
                        startActivity(
                            Intent(Intent.ACTION_VIEW, Uri.parse(challenge.authorizeUrl)).apply {
                                addCategory(Intent.CATEGORY_BROWSABLE)
                            },
                        )
                    }
                }
            }
        }
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val data = intent?.data?.toString() ?: return
        when {
            data.startsWith("discord-") || data.startsWith("crewrp://oauth/discord") -> {
                intent.data = null
                thread {
                    runCatching { discordFlow.completeLink(data) }
                        .onSuccess { link -> runOnUiThread { onDiscordLinked?.invoke(link) } }
                        .onFailure { err ->
                            Log.e("CrewRP", "discord link failed", err)
                            runOnUiThread {
                                onDiscordLinkError?.invoke("Discord 연결에 실패했습니다. 잠시 후 다시 시도해 주세요.")
                            }
                        }
                }
            }
            data.startsWith("crewrp://oauth/callback") -> {
                intent.data = null
                thread {
                    runCatching { flow.completeLogin(data) }
                        .onSuccess { repos -> runOnUiThread { onRepos?.invoke(repos) } }
                        .onFailure { err ->
                            Log.e("CrewRP", "oauth complete failed", err)
                            runOnUiThread {
                                onLoginError?.invoke("로그인에 실패했습니다. 잠시 후 다시 시도해 주세요.")
                            }
                        }
                }
            }
        }
    }
}

private fun registerDeviceToken(baseUrl: String, userId: String, token: String) {
    val connection = (URL(baseUrl.trimEnd('/') + "/devices").openConnection() as HttpURLConnection).apply {
        requestMethod = "POST"
        doOutput = true
        setRequestProperty("Content-Type", "application/json")
        outputStream.use {
            it.write("""{"userId":"$userId","token":"$token"}""".toByteArray())
        }
    }
    connection.responseCode
}
