package app.crewrp.core

import java.net.HttpURLConnection
import java.net.URL
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

fun interface HttpTransport {
    fun exchange(method: String, url: String, headers: Map<String, String>, body: String?): HttpResult
}

data class HttpResult(val status: Int, val body: String)

class UrlHttpTransport : HttpTransport {
    override fun exchange(method: String, url: String, headers: Map<String, String>, body: String?): HttpResult {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            doInput = true
            headers.forEach { (k, v) -> setRequestProperty(k, v) }
            if (body != null) {
                doOutput = true
                outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
        }
        val status = connection.responseCode
        val stream = if (status in 200..299) connection.inputStream else connection.errorStream
        val text = stream?.bufferedReader()?.readText().orEmpty()
        return HttpResult(status, text)
    }
}

@Serializable
data class TokenExchangeResult(
    @SerialName("access_token") val accessToken: String,
    @SerialName("token_type") val tokenType: String? = null,
    val scope: String? = null,
)

class AuthBridgeClient(
    private val baseUrl: String,
    private val transport: HttpTransport,
) {
    private val json = Json { ignoreUnknownKeys = true }
    fun exchange(code: String, codeVerifier: String, redirectUri: String): TokenExchangeResult {
        val body = """{"code":"$code","code_verifier":"$codeVerifier","redirect_uri":"$redirectUri"}"""
        val result = transport.exchange(
            method = "POST",
            url = baseUrl.trimEnd('/') + "/oauth/token",
            headers = mapOf("Content-Type" to "application/json"),
            body = body,
        )
        if (result.status !in 200..299) {
            error("auth-bridge http ${result.status}")
        }
        if ("\"error\"" in result.body) {
            error("auth-bridge github error: ${result.body}")
        }
        return json.decodeFromString(TokenExchangeResult.serializer(), result.body)
    }
}

@Serializable
data class Organization(val login: String, val id: Int)

@Serializable
data class CrewRepo(
    val owner: String,
    val name: String,
    val fullName: String,
    val isPrivate: Boolean,
)

@Serializable
data class Team(val slug: String, val id: Int, val name: String)

@Serializable
data class GitHubUser(val login: String, val id: Int)

@Serializable
private data class TeamDTO(
    val id: Int,
    val slug: String,
    val name: String,
    val organization: OrgLogin,
) {
    @Serializable
    data class OrgLogin(val login: String)
}

@Serializable
private data class RepoDTO(
    val name: String,
    @SerialName("full_name") val fullName: String,
    @SerialName("private") val isPrivate: Boolean,
    val permissions: Perms? = null,
    val owner: Owner,
) {
    @Serializable
    data class Perms(val admin: Boolean? = null)

    @Serializable
    data class Owner(val login: String)
}

class GitHubMembershipClient(
    private val transport: HttpTransport,
    private val apiBase: String = "https://api.github.com",
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun currentUser(token: String): GitHubUser {
        val result = get("user", token)
        return json.decodeFromString(GitHubUser.serializer(), result)
    }

    fun listOrganizations(token: String): List<Organization> {
        val result = get("user/orgs", token)
        return json.decodeFromString(kotlinx.serialization.builtins.ListSerializer(Organization.serializer()), result)
    }

    fun listRegistrableRepos(token: String): List<CrewRepo> {
        val result = get("user/repos?per_page=100&affiliation=owner,organization_member", token)
        val dtos = json.decodeFromString(kotlinx.serialization.builtins.ListSerializer(RepoDTO.serializer()), result)
        return dtos
            .filter { it.isPrivate && it.permissions?.admin == true }
            .map { CrewRepo(it.owner.login, it.name, it.fullName, it.isPrivate) }
    }

    fun listTeamsForOrg(org: String, token: String): List<Team> {
        val result = get("user/teams", token)
        val dtos = json.decodeFromString(kotlinx.serialization.builtins.ListSerializer(TeamDTO.serializer()), result)
        return dtos
            .filter { it.organization.login.equals(org, ignoreCase = true) }
            .map { Team(it.slug, it.id, it.name) }
    }

    fun resolveRole(owner: String, token: String, isRepoAdmin: Boolean): TeamRole {
        val fromTeams = TeamRole.resolve(listTeamsForOrg(owner, token).map { it.slug })
        if (fromTeams != TeamRole.NONE) return fromTeams
        return if (isRepoAdmin) TeamRole.ADMIN else TeamRole.NONE
    }

    private fun get(path: String, token: String): String {
        val result = transport.exchange(
            method = "GET",
            url = apiBase.trimEnd('/') + "/" + path.trimStart('/'),
            headers = mapOf(
                "Authorization" to "Bearer $token",
                "Accept" to "application/vnd.github+json",
                "X-GitHub-Api-Version" to "2022-11-28",
            ),
            body = null,
        )
        if (result.status !in 200..299) {
            error("github http ${result.status}")
        }
        return result.body
    }
}
