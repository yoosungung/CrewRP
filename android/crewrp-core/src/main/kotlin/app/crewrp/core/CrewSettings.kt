package app.crewrp.core

import java.util.Base64
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

@Serializable
data class CrewDiscordSettings(
    val serverId: String,
    val channelId: String,
) {
    val isConfigured: Boolean
        get() = discordConfigured(serverId, channelId)
}

@Serializable
data class CrewSettings(
    val discord: CrewDiscordSettings? = null,
)

data class CrewSettingsFile(
    val settings: CrewSettings,
    val sha: String?,
)

object CrewSettingsPaths {
    const val FILE = ".crewrp/settings.json"
}

class CrewSettingsClient(
    private val transport: HttpTransport,
    private val cache: CacheStore,
    private val apiBase: String = "https://api.github.com",
) {
    private val json = Json {
        ignoreUnknownKeys = true
        prettyPrint = true
    }
    private val rest = ETagRESTClient(transport, cache)

    @Serializable
    private data class ContentDTO(
        val content: String? = null,
        val encoding: String? = null,
        val sha: String? = null,
    )

    fun load(owner: String, repo: String, token: String): CrewSettingsFile? {
        val url = "$apiBase/repos/$owner/$repo/contents/${CrewSettingsPaths.FILE}"
        val response = try {
            rest.get(url, token)
        } catch (e: IllegalArgumentException) {
            if (e.message?.contains("404") == true) return null
            throw e
        }
        val dto = json.decodeFromString(ContentDTO.serializer(), response.body)
        require(dto.encoding == "base64" && dto.content != null)
        val bytes = Base64.getMimeDecoder().decode(dto.content.replace("\n", ""))
        val settings = json.decodeFromString(CrewSettings.serializer(), bytes.toString(Charsets.UTF_8))
        return CrewSettingsFile(settings, dto.sha)
    }

    fun save(
        owner: String,
        repo: String,
        token: String,
        settings: CrewSettings,
        sha: String?,
    ): CrewSettingsFile {
        val encoded = Base64.getEncoder().encodeToString(
            json.encodeToString(CrewSettings.serializer(), settings).toByteArray(Charsets.UTF_8),
        )
        val body = buildJsonObject {
            put("message", "크루 설정 저장")
            put("content", encoded)
            if (sha != null) put("sha", sha)
        }.toString()
        val result = transport.rest(
            "PUT",
            "$apiBase/repos/$owner/$repo/contents/${CrewSettingsPaths.FILE}",
            token,
            body,
        )
        require(result.status in 200..299) { "github http ${result.status}" }
        val newSha = json.parseToJsonElement(result.body).jsonObject["content"]?.jsonObject
            ?.get("sha")?.toString()?.trim('"')
        return CrewSettingsFile(settings, newSha)
    }
}
