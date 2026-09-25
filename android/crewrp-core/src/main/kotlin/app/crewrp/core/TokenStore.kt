package app.crewrp.core

interface TokenStore {
    fun saveAccessToken(token: String)
    fun loadAccessToken(): String?
    fun clearAccessToken()
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
