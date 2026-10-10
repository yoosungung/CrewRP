package app.crewrp.core

import java.util.Base64
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

data class DiscussionSetup(val repositoryId: String, val categoryId: String)

data class DiscussionCategory(val id: String, val name: String)

data class DiscussionRepoSetup(val repositoryId: String, val categories: List<DiscussionCategory>)

@Serializable
data class DocEntry(val path: String, val name: String, val sha: String?, val isDir: Boolean)

data class GitTreeNode(val path: String, val type: String, val sha: String? = null)

/** Git Trees 응답에서 `/docs` 이하 blob·tree만 DocEntry로 남긴다. */
fun docsEntriesFromGitTree(nodes: List<GitTreeNode>, prefix: String = "docs"): List<DocEntry> {
    val root = prefix.trim('/')
    if (root.isEmpty()) return emptyList()
    return nodes.mapNotNull { node ->
        val path = node.path.trim('/')
        if (path != root && !path.startsWith("$root/")) return@mapNotNull null
        if (node.type != "blob" && node.type != "tree") return@mapNotNull null
        DocEntry(path, path.substringAfterLast('/'), node.sha, node.type == "tree")
    }
}

data class ProjectFieldMeta(
    val projectId: String,
    val statusFieldId: String?,
    val dueFieldId: String?,
    val statusOptions: Map<String, String>,
)

internal object Graphql {
    private val json = Json { ignoreUnknownKeys = true }

    fun post(
        transport: HttpTransport,
        apiBase: String,
        token: String,
        query: String,
        variables: JsonObject = buildJsonObject { },
    ): JsonObject {
        val body = buildJsonObject {
            put("query", query)
            put("variables", variables)
        }.toString()
        val result = transport.exchange(
            "POST",
            "$apiBase/graphql",
            mapOf(
                "Authorization" to "Bearer $token",
                "Content-Type" to "application/json",
            ),
            body,
        )
        require(result.status in 200..299) { "github http ${result.status}" }
        val root = json.parseToJsonElement(result.body).jsonObject
        val errors = root["errors"] as? JsonArray
        val data = root["data"]
        // Org+user dual queries often return NOT_FOUND on one branch while the other has data.
        if (errors != null && errors.isNotEmpty() && (data == null || data is JsonNull)) {
            error("graphql: ${errors.first()}")
        }
        return root
    }

    fun text(el: kotlinx.serialization.json.JsonElement?): String? {
        if (el == null || el is JsonNull || el !is JsonPrimitive) return null
        return el.contentOrNull
    }
}

internal fun HttpTransport.rest(
    method: String,
    url: String,
    token: String,
    body: String? = null,
    contentType: String = "application/json",
): HttpResult {
    val headers = mutableMapOf(
        "Authorization" to "Bearer $token",
        "Accept" to "application/vnd.github+json",
        "X-GitHub-Api-Version" to "2022-11-28",
    )
    if (body != null) headers["Content-Type"] = contentType
    return exchange(method, url, headers, body)
}
