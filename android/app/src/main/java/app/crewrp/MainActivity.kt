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
import app.crewrp.core.AuthBridgeClient
import app.crewrp.core.AuthConfig
import app.crewrp.core.AuthFlow
import app.crewrp.core.CacheStore
import app.crewrp.core.CrewRepo
import app.crewrp.core.DiscordDeepLink
import app.crewrp.core.PendingLogin
import app.crewrp.core.PendingLoginStore
import app.crewrp.core.Session
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
}

class MainActivity : ComponentActivity() {
    private lateinit var flow: AuthFlow
    private lateinit var tokens: EncryptedPrefsTokenStore
    private lateinit var cache: CacheStore
    private var onRepos: ((List<CrewRepo>) -> Unit)? = null
    private var onLoginError: ((String) -> Unit)? = null

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
        flow = AuthFlow(
            config,
            AuthBridgeClient(config.authBridgeBaseUrl, transport),
            app.crewrp.core.GitHubMembershipClient(transport),
            tokens,
            cache,
            tokens,
        )

        setContent {
            var repos by remember { mutableStateOf<List<CrewRepo>>(emptyList()) }
            var session by remember { mutableStateOf(cache.session()) }
            var error by remember { mutableStateOf<String?>(null) }
            var content by remember { mutableStateOf(CrewContent(loading = session != null)) }
            var refreshTick by remember { mutableIntStateOf(0) }
            var loadId by remember { mutableIntStateOf(0) }
            var deviceRegistered by remember { mutableStateOf(false) }
            onRepos = {
                repos = it
                error = if (it.isEmpty()) "운영 권한이 있는 보관소가 없습니다." else null
            }
            onLoginError = { error = it }

            val active = session
            LaunchedEffect(active?.repo, refreshTick) {
                if (active == null) return@LaunchedEffect
                val token = tokens.loadAccessToken()
                if (token == null) {
                    content = CrewContent(
                        tasksFailed = true,
                        noticesFailed = true,
                        threadsFailed = true,
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
                    )
                    runOnUiThread {
                        if (request != loadId) return@runOnUiThread
                        content = loaded.copy(
                            tasks = if (loaded.tasksFailed && previous.tasks.isNotEmpty()) previous.tasks else loaded.tasks,
                            notices = if (loaded.noticesFailed && previous.notices.isNotEmpty()) previous.notices else loaded.notices,
                            threads = if (loaded.threadsFailed && previous.threads.isNotEmpty()) previous.threads else loaded.threads,
                            doc = if (loaded.docFailed && previous.doc.isNotEmpty()) previous.doc else loaded.doc,
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
                            discordEnabled = discordConfigured(
                                BuildConfig.DISCORD_SERVER_ID,
                                BuildConfig.DISCORD_CHANNEL_ID,
                            ),
                            actions = CrewActions(
                                onCreateNotice = { title, body ->
                                    val setup = content.discussionSetup ?: return@CrewActions
                                    runWrite { it.createNotice(title, body, setup) }
                                },
                                onUpdateNotice = { notice, title, body ->
                                    runWrite { it.updateNotice(notice.id, title, body) }
                                },
                                onDeleteNotice = { notice -> runWrite { it.deleteNotice(notice.id) } },
                                onCreateTask = { title, due -> runWrite { it.createTask(title, due) } },
                                onUpdateTask = { card, status, due ->
                                    val meta = content.projectMeta ?: return@CrewActions
                                    runWrite { it.updateTask(meta, card, status, due) }
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
                                onPostTalk = { body -> runWrite { it.postTalk(body) } },
                                onUpdateTalk = { msg, body -> runWrite { it.updateTalk(msg.id, body) } },
                                onDeleteTalk = { msg -> runWrite { it.deleteTalk(msg.id) } },
                                onReactTalk = { msg -> runWrite { it.reactTalk(msg.id) } },
                            ),
                            onRefresh = { refreshTick += 1 },
                            onDiscord = {
                                val url = DiscordDeepLink.voiceChannelUrl(
                                    BuildConfig.DISCORD_SERVER_ID,
                                    BuildConfig.DISCORD_CHANNEL_ID,
                                )
                                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
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
        if (!data.startsWith("crewrp://oauth/callback")) return
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
