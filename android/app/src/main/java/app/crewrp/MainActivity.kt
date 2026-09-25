package app.crewrp

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import app.crewrp.core.AuthBridgeClient
import app.crewrp.core.AuthConfig
import app.crewrp.core.AuthFlow
import app.crewrp.core.CacheStore
import app.crewrp.core.CrewRepo
import app.crewrp.core.DiscordDeepLink
import app.crewrp.core.DocsClient
import app.crewrp.core.ETagRESTClient
import app.crewrp.core.GitHubMembershipClient
import app.crewrp.core.Notice
import app.crewrp.core.Session
import app.crewrp.core.ThreadMessage
import app.crewrp.core.TokenStore
import app.crewrp.core.UrlHttpTransport
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread
import org.json.JSONArray
import org.json.JSONObject

class EncryptedPrefsTokenStore(context: Context) : TokenStore {
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
}

class MainActivity : ComponentActivity() {
    private lateinit var flow: AuthFlow
    private lateinit var tokens: TokenStore
    private lateinit var cache: CacheStore
    private var onRepos: ((List<CrewRepo>) -> Unit)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val dbPath = File(filesDir, "crewrp.sqlite").absolutePath
        val transport = UrlHttpTransport()
        val config = AuthConfig(
            clientId = BuildConfig.GITHUB_CLIENT_ID,
            redirectUri = "crewrp://oauth/callback",
            authBridgeBaseUrl = BuildConfig.AUTH_BRIDGE_URL,
        )
        tokens = EncryptedPrefsTokenStore(this)
        cache = CacheStore(dbPath)
        flow = AuthFlow(
            config,
            AuthBridgeClient(config.authBridgeBaseUrl, transport),
            GitHubMembershipClient(transport),
            tokens,
            cache,
        )

        setContent {
            var repos by remember { mutableStateOf<List<CrewRepo>>(emptyList()) }
            var session by remember { mutableStateOf(cache.session()) }
            var error by remember { mutableStateOf<String?>(null) }
            onRepos = { repos = it }

            MaterialTheme {
                when {
                    session != null -> MainTabs(session!!, tokens, cache)
                    repos.isNotEmpty() -> RepoPicker(repos) { repo ->
                        runCatching { flow.registerCrew(repo) }
                            .onSuccess { session = it }
                            .onFailure { error = it.message }
                    }
                    else -> LoginScreen(error) {
                        val challenge = flow.beginLogin()
                        CustomTabsIntent.Builder().build()
                            .launchUrl(this, Uri.parse(challenge.authorizeUrl))
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
        runCatching { flow.completeLogin(data) }
            .onSuccess { onRepos?.invoke(it) }
            .onFailure { /* surfaced next login */ }
    }
}

@Composable
private fun MainTabs(session: Session, tokens: TokenStore, cache: CacheStore) {
    var tab by remember { mutableIntStateOf(0) }
    var doc by remember { mutableStateOf("불러오는 중…") }
    var notices by remember { mutableStateOf<List<Notice>>(emptyList()) }
    var threads by remember { mutableStateOf<List<ThreadMessage>>(emptyList()) }
    val labels = listOf("홈", "할 일", "자료실", "소통")
    val context = LocalContext.current

    LaunchedEffect(session.repo) {
        val token = tokens.loadAccessToken() ?: return@LaunchedEffect
        val parts = session.repo.split("/")
        if (parts.size != 2) return@LaunchedEffect
        val owner = parts[0]
        val repo = parts[1]
        thread {
            runCatching {
                val transport = UrlHttpTransport()
                val text = DocsClient(ETagRESTClient(transport, cache))
                    .fetchMarkdown(owner, repo, "docs/README.md", token)
                    .content
                val discussionBody = transport.exchange(
                    "POST",
                    "https://api.github.com/graphql",
                    mapOf(
                        "Authorization" to "Bearer $token",
                        "Content-Type" to "application/json",
                    ),
                    """{"query":"query{repository(owner:\"$owner\",name:\"$repo\"){discussions(first:5){nodes{id title body}}}}"}""",
                ).body
                val nodes = JSONObject(discussionBody)
                    .optJSONObject("data")
                    ?.optJSONObject("repository")
                    ?.optJSONObject("discussions")
                    ?.optJSONArray("nodes") ?: JSONArray()
                val loaded = buildList {
                    for (i in 0 until nodes.length()) {
                        val n = nodes.getJSONObject(i)
                        add(Notice(n.getString("id"), n.getString("title"), n.optString("body")))
                    }
                }
                val commentsBody = transport.exchange(
                    "GET",
                    "https://api.github.com/repos/$owner/$repo/issues/1/comments",
                    mapOf(
                        "Authorization" to "Bearer $token",
                        "Accept" to "application/vnd.github+json",
                    ),
                    null,
                ).body
                val comments = JSONArray(if (commentsBody.isBlank()) "[]" else commentsBody)
                val msgs = buildList {
                    for (i in 0 until comments.length()) {
                        val c = comments.getJSONObject(i)
                        add(
                            ThreadMessage(
                                c.getLong("id").toString(),
                                c.getString("body"),
                                c.getJSONObject("user").getString("login"),
                            ),
                        )
                    }
                }
                (context as ComponentActivity).runOnUiThread {
                    doc = text
                    notices = loaded
                    threads = msgs
                }
            }.onFailure {
                (context as ComponentActivity).runOnUiThread {
                    doc = "자료를 불러오지 못했습니다: ${it.message}"
                }
            }
        }
    }

    Scaffold(
        bottomBar = {
            NavigationBar {
                labels.forEachIndexed { index, label ->
                    NavigationBarItem(
                        selected = tab == index,
                        onClick = { tab = index },
                        icon = { Text(label.take(1)) },
                        label = { Text(label) },
                    )
                }
            }
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            when (tab) {
                0 -> {
                    Text("홈", style = MaterialTheme.typography.headlineSmall)
                    Text("크루: ${session.org}")
                    Text("역할: ${session.teamRole}")
                    Text("저장소: ${session.repo}")
                    Text("공지", style = MaterialTheme.typography.titleMedium)
                    notices.take(3).forEach { Text("· ${it.title}") }
                }
                1 -> {
                    Text("할 일", style = MaterialTheme.typography.headlineSmall)
                    Text("할 일은 Projects 연결 후 칸반에 표시됩니다.")
                }
                2 -> {
                    Text("자료실", style = MaterialTheme.typography.headlineSmall)
                    Text(doc, modifier = Modifier.verticalScroll(rememberScrollState()))
                }
                else -> {
                    Text("소통", style = MaterialTheme.typography.headlineSmall)
                    threads.forEach { Text("${it.author}: ${it.body}") }
                    Button(onClick = {
                        val url = DiscordDeepLink.voiceChannelUrl(
                            BuildConfig.DISCORD_SERVER_ID,
                            BuildConfig.DISCORD_CHANNEL_ID,
                        )
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                    }) { Text("바로 대화 (Discord)") }
                    Button(onClick = {
                        thread {
                            registerDeviceToken(
                                BuildConfig.PUSH_BRIDGE_URL,
                                session.org,
                                "fcm-token-placeholder",
                            )
                        }
                    }) { Text("알림 기기 등록") }
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

@Composable
private fun LoginScreen(error: String?, onLogin: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("CrewRP", style = MaterialTheme.typography.headlineLarge)
        Text("계정으로 로그인")
        Button(onClick = onLogin) { Text("로그인") }
        if (error != null) Text(error)
    }
}

@Composable
private fun RepoPicker(repos: List<CrewRepo>, onSelect: (CrewRepo) -> Unit) {
    Column(Modifier.fillMaxSize().padding(24.dp)) {
        Text("크루 등록", style = MaterialTheme.typography.headlineSmall)
        Text("관리 권한이 있는 저장소를 골라 크루를 시작합니다.")
        LazyColumn {
            items(repos) { repo ->
                Text(
                    repo.fullName,
                    modifier = Modifier.clickable { onSelect(repo) }.padding(16.dp),
                )
            }
        }
    }
}
