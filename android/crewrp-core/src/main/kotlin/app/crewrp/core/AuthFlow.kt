package app.crewrp.core

data class AuthConfig(
    val clientId: String,
    val redirectUri: String,
    val authBridgeBaseUrl: String,
    val defaultRepoName: String = "crew",
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

    fun completeLogin(callbackUrl: String): List<Organization> {
        val query = URIQuery.parse(callbackUrl)
        val pending = pending ?: error("missing pending login")
        require(query["state"] == pending.state) { "state mismatch" }
        val code = query["code"] ?: error("missing code")
        val token = bridge.exchange(code, pending.codeVerifier, config.redirectUri)
        tokens.saveAccessToken(token.accessToken)
        this.pending = null
        val orgs = membership.listOrganizations(token.accessToken)
        require(orgs.isNotEmpty()) { "no organizations" }
        return orgs
    }

    fun selectOrganization(org: Organization): Session {
        val token = tokens.loadAccessToken() ?: error("missing token")
        val role = membership.resolveRole(org.login, token)
        val session = Session(org.login, "${org.login}/${config.defaultRepoName}", role)
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
