package app.crewrp.core

data class DiscordAuthConfig(
    val clientId: String,
    val redirectUri: String = "",
    val authBridgeBaseUrl: String,
) {
    val resolvedRedirectUri: String
        get() = redirectUri.ifBlank { DiscordOAuth.mobileRedirectUri(clientId) }
}

class DiscordLinkFlow(
    private val config: DiscordAuthConfig,
    private val bridge: AuthBridgeClient,
    private val cache: CacheStore,
    private val pendingStore: PendingLoginStore = InMemoryPendingLoginStore(),
) {
    fun beginLink(): LoginChallenge {
        val pkce = PKCE.generate()
        val state = PKCE.generate().verifier
        val redirect = config.resolvedRedirectUri
        val url = DiscordOAuth.authorizeUrl(
            clientId = config.clientId,
            redirectUri = redirect,
            state = state,
            codeChallenge = pkce.challenge,
        )
        pendingStore.save(PendingLogin(state, pkce.verifier))
        return LoginChallenge(url, state, pkce.verifier)
    }

    fun completeLink(callbackUrl: String): AccountLink {
        val query = URIQuery.parse(callbackUrl)
        val pending = pendingStore.load() ?: error("missing pending login")
        require(query["state"] == pending.state) { "state mismatch" }
        val code = query["code"] ?: error("missing code")
        val identity = bridge.exchangeDiscord(code, pending.codeVerifier, config.resolvedRedirectUri)
        pendingStore.clear()
        val link = AccountLink(
            provider = AccountLink.DISCORD,
            userId = identity.id,
            username = identity.username,
        )
        cache.putAccountLink(link)
        return link
    }

    fun linkedDiscord(): AccountLink? = cache.accountLink(AccountLink.DISCORD)

    fun unlink() {
        pendingStore.clear()
        cache.clearAccountLink(AccountLink.DISCORD)
    }
}
