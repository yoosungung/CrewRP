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
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import app.crewrp.core.DiscordDeepLink
import app.crewrp.core.GitHubMembershipClient
import app.crewrp.core.Organization
import app.crewrp.core.Session
import app.crewrp.core.TokenStore
import app.crewrp.core.UrlHttpTransport
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

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
    private var onOrgs: ((List<Organization>) -> Unit)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val dbPath = File(filesDir, "crewrp.sqlite").absolutePath
        val transport = UrlHttpTransport()
        val config = AuthConfig(
            clientId = BuildConfig.GITHUB_CLIENT_ID,
            redirectUri = "crewrp://oauth/callback",
            authBridgeBaseUrl = BuildConfig.AUTH_BRIDGE_URL,
        )
        flow = AuthFlow(
            config,
            AuthBridgeClient(config.authBridgeBaseUrl, transport),
            GitHubMembershipClient(transport),
            EncryptedPrefsTokenStore(this),
            CacheStore(dbPath),
        )

        setContent {
            var orgs by remember { mutableStateOf<List<Organization>>(emptyList()) }
            var session by remember { mutableStateOf<Session?>(null) }
            var error by remember { mutableStateOf<String?>(null) }
            onOrgs = { orgs = it }

            MaterialTheme {
                when {
                    session != null -> MainTabs(session!!)
                    orgs.isNotEmpty() -> OrgPicker(orgs) { org ->
                        runCatching { flow.selectOrganization(org) }
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
            .onSuccess { onOrgs?.invoke(it) }
    }
}

@Composable
private fun MainTabs(session: Session) {
    var tab by remember { mutableIntStateOf(0) }
    val labels = listOf("홈", "할 일", "자료실", "소통")
    val context = LocalContext.current
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
                }
                1 -> {
                    Text("할 일", style = MaterialTheme.typography.headlineSmall)
                    Text("칸반·마감일 목록은 Projects v2 클라이언트와 연결됩니다.")
                }
                2 -> {
                    Text("자료실", style = MaterialTheme.typography.headlineSmall)
                    Text("/docs 마크다운을 앱에서 렌더합니다.")
                }
                else -> {
                    Text("소통", style = MaterialTheme.typography.headlineSmall)
                    Text("스레드 톡 · 알림")
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
private fun OrgPicker(orgs: List<Organization>, onSelect: (Organization) -> Unit) {
    Column(Modifier.fillMaxSize().padding(24.dp)) {
        Text("크루 선택", style = MaterialTheme.typography.headlineSmall)
        LazyColumn {
            items(orgs) { org ->
                Text(org.login, modifier = Modifier.clickable { onSelect(org) }.padding(16.dp))
            }
        }
    }
}
