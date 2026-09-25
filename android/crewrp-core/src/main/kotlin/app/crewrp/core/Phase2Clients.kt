package app.crewrp.core

import java.util.Base64
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
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
    fun sortedByDueDate(cards: List<TaskCard>): List<TaskCard> =
        cards.sortedBy { it.dueOn ?: "9999" }
}

data class Notice(val id: String, val title: String, val body: String)

class DiscussionsClient(
    private val transport: HttpTransport,
    private val apiBase: String = "https://api.github.com",
) {
    private val json = Json { ignoreUnknownKeys = true }
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
