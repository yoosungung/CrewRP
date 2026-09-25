package app.crewrp.core

data class AuthConfig(
    val clientId: String,
    val redirectUri: String,
    val authBridgeBaseUrl: String,
)

data class LoginChallenge(
    val authorizeUrl: String,
    val state: String,
    val codeVerifier: String,
)

class AuthFlow(
    private val config: AuthConfig,
    private val bridge: AuthBridgeClient,
    private val membership: GitHubMembershipClient,
    private val tokens: TokenStore,
    private val cache: CacheStore,
) {
    private var pending: LoginChallenge? = null

    fun beginLogin(): LoginChallenge {
        val pkce = PKCE.generate()
        val state = PKCE.generate().verifier
        val url = GitHubOAuth.authorizeUrl(
            clientId = config.clientId,
            redirectUri = config.redirectUri,
            state = state,
            codeChallenge = pkce.challenge,
        )
        return LoginChallenge(url, state, pkce.verifier).also { pending = it }
    }

    fun completeLogin(callbackUrl: String): List<CrewRepo> {
        val query = URIQuery.parse(callbackUrl)
        val pending = pending ?: error("missing pending login")
        require(query["state"] == pending.state) { "state mismatch" }
        val code = query["code"] ?: error("missing code")
        val token = bridge.exchange(code, pending.codeVerifier, config.redirectUri)
        tokens.saveAccessToken(token.accessToken)
        this.pending = null
        val repos = membership.listRegistrableRepos(token.accessToken)
        require(repos.isNotEmpty()) { "no registrable repos" }
        return repos
    }

    fun registerCrew(repo: CrewRepo): Session {
        val token = tokens.loadAccessToken() ?: error("missing token")
        val role = membership.resolveRole(repo.owner, token, isRepoAdmin = true)
        val session = Session(repo.owner, repo.fullName, role)
        cache.putSession(session)
        return session
    }
}

internal object URIQuery {
    fun parse(url: String): Map<String, String> {
        val q = url.substringAfter('?', missingDelimiterValue = "")
        if (q.isEmpty()) return emptyMap()
        return q.split('&').mapNotNull { part ->
            val idx = part.indexOf('=')
            if (idx < 0) null
            else {
                val key = java.net.URLDecoder.decode(part.substring(0, idx), Charsets.UTF_8)
                val value = java.net.URLDecoder.decode(part.substring(idx + 1), Charsets.UTF_8)
                key to value
            }
        }.toMap()
    }
}
