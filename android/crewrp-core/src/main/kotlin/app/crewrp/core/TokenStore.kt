package app.crewrp.core

interface TokenStore {
    fun saveAccessToken(token: String)
    fun loadAccessToken(): String?
    fun clearAccessToken()
}

data class PendingLogin(val state: String, val codeVerifier: String)

interface PendingLoginStore {
    fun save(pending: PendingLogin)
    fun load(): PendingLogin?
    fun clear()
}

class InMemoryTokenStore : TokenStore {
    private var token: String? = null

    override fun saveAccessToken(token: String) {
        this.token = token
    }

    override fun loadAccessToken(): String? = token

    override fun clearAccessToken() {
        token = null
    }
}

class InMemoryPendingLoginStore : PendingLoginStore {
    private var pending: PendingLogin? = null

    override fun save(pending: PendingLogin) {
        this.pending = pending
    }

    override fun load(): PendingLogin? = pending

    override fun clear() {
        pending = null
    }
}
