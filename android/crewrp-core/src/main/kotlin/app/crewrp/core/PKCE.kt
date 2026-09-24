package app.crewrp.core

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

data class PKCEPair(val verifier: String, val challenge: String)

object PKCE {
    fun generate(): PKCEPair {
        val verifier = randomVerifier()
        return PKCEPair(verifier, challenge(verifier))
    }

    fun challenge(verifier: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII))
        return base64Url(digest)
    }

    private fun randomVerifier(): String {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        return base64Url(bytes)
    }

    private fun base64Url(bytes: ByteArray): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
}

object GitHubOAuth {
    fun authorizeUrl(
        clientId: String,
        redirectUri: String,
        state: String,
        codeChallenge: String,
        scope: String = "read:org repo",
    ): String {
        val params = linkedMapOf(
            "client_id" to clientId,
            "redirect_uri" to redirectUri,
            "scope" to scope,
            "state" to state,
            "response_type" to "code",
            "code_challenge" to codeChallenge,
            "code_challenge_method" to "S256",
        )
        val query = params.entries.joinToString("&") { (k, v) ->
            "${encode(k)}=${encode(v)}"
        }
        return "https://github.com/login/oauth/authorize?$query"
    }

    private fun encode(value: String): String =
        java.net.URLEncoder.encode(value, Charsets.UTF_8)
}
