package app.crewrp.core

import java.util.Base64
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

data class CachedHTTPResponse(
    val statusCode: Int,
    val body: String,
    val etag: String?,
    val fromCache: Boolean,
)

class ETagRESTClient(
    private val transport: HttpTransport,
    private val cache: CacheStore,
) {
    fun get(url: String, token: String): CachedHTTPResponse {
        val headers = mutableMapOf(
            "Authorization" to "Bearer $token",
            "Accept" to "application/vnd.github+json",
            "X-GitHub-Api-Version" to "2022-11-28",
        )
        cache.cacheEntry(url)?.etag?.let { headers["If-None-Match"] = it }
        val result = transport.exchange("GET", url, headers, null)
        if (result.status == 304) {
            val cached = cache.cacheEntry(url) ?: error("missing cache")
            return CachedHTTPResponse(304, cached.body, cached.etag, true)
        }
        require(result.status in 200..299) { "github http ${result.status}" }
        val etag = null // transport abstraction omits headers; callers may still store body
        cache.putCacheEntry(url, result.body, etag)
        return CachedHTTPResponse(result.status, result.body, etag, false)
    }
}

data class DocFile(val path: String, val content: String)

class DocsClient(
    private val rest: ETagRESTClient,
    private val apiBase: String = "https://api.github.com",
) {
    private val json = Json { ignoreUnknownKeys = true }
    @Serializable
    private data class ContentDTO(val path: String, val content: String? = null, val encoding: String? = null)

    fun fetchMarkdown(owner: String, repo: String, path: String, token: String): DocFile {
        val url = "$apiBase/repos/$owner/$repo/contents/$path"
        val response = rest.get(url, token)
        val dto = json.decodeFromString(ContentDTO.serializer(), response.body)
        require(dto.encoding == "base64" && dto.content != null)
        val bytes = Base64.getMimeDecoder().decode(dto.content.replace("\n", ""))
        return DocFile(dto.path, bytes.toString(Charsets.UTF_8))
    }
}

data class TaskCard(val id: String, val title: String, val status: String, val dueOn: String?)

class ProjectsClient(
    private val transport: HttpTransport,
    private val apiBase: String = "https://api.github.com",
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun sortedByDueDate(cards: List<TaskCard>): List<TaskCard> =
        cards.sortedBy { it.dueOn ?: "9999" }

    fun listTasks(org: String, projectNumber: Int, token: String): List<TaskCard> {
        val query = """
            query(${'$'}org:String!,${'$'}number:Int!){
              organization(login:${'$'}org){
                projectV2(number:${'$'}number){
                  items(first:50){
                    nodes{
                      id
                      content{ ... on Issue { title } }
                      fieldValues(first:20){
                        nodes{
                          ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2SingleSelectField { name } } }
                          ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { name } } }
                        }
                      }
                    }
                  }
                }
              }
            }
        """.trimIndent()
        val body = buildJsonObject {
            put("query", query)
            putJsonObject("variables") {
                put("org", org)
                put("number", projectNumber)
            }
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
        return parseTaskCards(json.parseToJsonElement(result.body).jsonObject)
    }

    private fun parseTaskCards(root: JsonObject): List<TaskCard> {
        val project = root["data"]?.jsonObject?.get("organization")?.jsonObject?.get("projectV2")
            ?: return emptyList()
        if (project is JsonNull) return emptyList()
        val nodes = project.jsonObject["items"]?.jsonObject?.get("nodes")?.jsonArray ?: return emptyList()
        return nodes.mapNotNull { element ->
            if (element !is JsonObject) return@mapNotNull null
            val id = element["id"].textOrNull() ?: return@mapNotNull null
            val title = element["content"]?.takeUnless { it is JsonNull }?.jsonObject?.get("title").textOrNull()
                ?: "(제목 없음)"
            var status = "접수"
            var due: String? = null
            val fields = element["fieldValues"]?.jsonObject?.get("nodes")?.jsonArray
            fields?.forEach { fieldEl ->
                if (fieldEl !is JsonObject) return@forEach
                when (fieldEl["field"]?.takeUnless { it is JsonNull }?.jsonObject?.get("name").textOrNull()) {
                    "Status" -> fieldEl["name"].textOrNull()?.let { status = it }
                    "Due" -> due = fieldEl["date"].textOrNull()
                }
            }
            TaskCard(id, title, status, due)
        }
    }
}

data class Notice(val id: String, val title: String, val body: String)

class DiscussionsClient(
    private val transport: HttpTransport,
    private val apiBase: String = "https://api.github.com",
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun listNotices(owner: String, repo: String, token: String): List<Notice> {
        val query = """
            query(${'$'}owner:String!,${'$'}name:String!){
              repository(owner:${'$'}owner,name:${'$'}name){
                discussions(first:20){ nodes { id title body } }
              }
            }
        """.trimIndent()
        val body = buildJsonObject {
            put("query", query)
            putJsonObject("variables") {
                put("owner", owner)
                put("name", repo)
            }
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
        val repository = json.parseToJsonElement(result.body).jsonObject["data"]
            ?.jsonObject?.get("repository") ?: return emptyList()
        if (repository is JsonNull) return emptyList()
        val nodes = repository.jsonObject["discussions"]?.jsonObject?.get("nodes")?.jsonArray
            ?: return emptyList()
        return nodes.mapNotNull { element ->
            if (element !is JsonObject) return@mapNotNull null
            val id = element["id"].textOrNull() ?: return@mapNotNull null
            Notice(id, element["title"].textOrNull().orEmpty(), element["body"].textOrNull().orEmpty())
        }
    }

    fun vote(pollOptionId: String, token: String) {
        val body = buildJsonObject {
            put("query", "mutation(\$input:AddDiscussionPollVoteInput!){ addDiscussionPollVote(input:\$input){ pollOption { id } } }")
            putJsonObject("variables") {
                putJsonObject("input") { put("pollOptionId", pollOptionId) }
            }
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
        require(result.status in 200..299)
    }
}

data class FormField(val id: String, val label: String, val required: Boolean, val type: String)
data class IssueFormTemplate(val name: String, val fields: List<FormField>)

object IssueFormParser {
    fun parse(yaml: String): IssueFormTemplate {
        var name = "서식"
        val fields = mutableListOf<FormField>()
        var currentId: String? = null
        var currentLabel: String? = null
        var currentType = "input"
        var currentRequired = false
        fun flush() {
            val id = currentId
            val label = currentLabel
            if (id != null && label != null) {
                fields += FormField(id, label, currentRequired, currentType)
            }
            currentId = null
            currentLabel = null
            currentType = "input"
            currentRequired = false
        }
        yaml.lineSequence().forEach { line ->
            val trimmed = line.trim()
            when {
                trimmed.startsWith("name:") ->
                    name = trimmed.removePrefix("name:").trim().trim('"')
                trimmed.startsWith("- type:") -> {
                    flush()
                    currentType = trimmed.removePrefix("- type:").trim()
                }
                trimmed.startsWith("id:") -> currentId = trimmed.removePrefix("id:").trim()
                trimmed.startsWith("label:") -> currentLabel = trimmed.removePrefix("label:").trim().trim('"')
                trimmed.startsWith("required:") -> currentRequired = trimmed.contains("true")
            }
        }
        flush()
        return IssueFormTemplate(name, fields)
    }
}

data class ThreadMessage(val id: String, val body: String, val author: String)

object DiscordDeepLink {
    fun voiceChannelUrl(serverId: String, channelId: String): String =
        "https://discord.com/channels/$serverId/$channelId"
}

class ThreadTalkClient(
    private val transport: HttpTransport,
    private val apiBase: String = "https://api.github.com",
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun listIssueComments(owner: String, repo: String, issueNumber: Int, token: String): List<ThreadMessage> {
        val result = transport.exchange(
            "GET",
            "$apiBase/repos/$owner/$repo/issues/$issueNumber/comments",
            mapOf(
                "Authorization" to "Bearer $token",
                "Accept" to "application/vnd.github+json",
                "X-GitHub-Api-Version" to "2022-11-28",
            ),
            null,
        )
        require(result.status in 200..299) { "github http ${result.status}" }
        if (result.body.isBlank()) return emptyList()
        val nodes = json.parseToJsonElement(result.body).jsonArray
        return nodes.mapNotNull { element ->
            if (element !is JsonObject) return@mapNotNull null
            val id = element["id"].textOrNull() ?: return@mapNotNull null
            val author = element["user"]?.takeUnless { it is JsonNull }?.jsonObject?.get("login").textOrNull().orEmpty()
            ThreadMessage(id, element["body"].textOrNull().orEmpty(), author)
        }
    }
}

private fun kotlinx.serialization.json.JsonElement?.textOrNull(): String? {
    if (this == null || this is JsonNull || this !is JsonPrimitive) return null
    return contentOrNull
}
