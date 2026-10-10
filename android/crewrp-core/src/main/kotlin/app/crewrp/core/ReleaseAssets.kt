package app.crewrp.core

import java.net.URLEncoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.contentOrNull

data class AttachmentEntry(
    val id: Int,
    val name: String,
    val contentType: String?,
    val size: Int,
    val browserDownloadUrl: String,
    val apiUrl: String,
) {
    val isPreviewable: Boolean get() = attachmentIsPreviewable(name, contentType)
}

sealed class DocsLibraryItem {
    data class Doc(val entry: DocEntry) : DocsLibraryItem()
    data class Attachment(val entry: AttachmentEntry) : DocsLibraryItem()

    val name: String
        get() = when (this) {
            is Doc -> entry.name
            is Attachment -> entry.name
        }

    val key: String
        get() = when (this) {
            is Doc -> "doc:${entry.path}"
            is Attachment -> "att:${entry.id}"
        }
}

fun attachmentIsPreviewable(name: String, contentType: String?): Boolean {
    val lower = name.lowercase()
    if (lower.endsWith(".png") || lower.endsWith(".jpg") || lower.endsWith(".jpeg") ||
        lower.endsWith(".gif") || lower.endsWith(".webp") || lower.endsWith(".pdf") ||
        lower.endsWith(".heic")
    ) {
        return true
    }
    val ct = contentType?.lowercase() ?: return false
    return ct.startsWith("image/") || ct == "application/pdf"
}

fun interface BinaryHttpExchange {
    fun exchange(method: String, url: String, headers: Map<String, String>, body: ByteArray?): HttpResult
}

class ReleaseAssetClient(
    private val transport: HttpTransport,
    private val apiBase: String = "https://api.github.com",
    private val uploadsBase: String = "https://uploads.github.com",
    private val binary: BinaryHttpExchange = BinaryHttpExchange { method, url, headers, body ->
        when (val t = transport) {
            is UrlHttpTransport -> t.exchangeBytes(method, url, headers, body)
            else -> error("binary HTTP requires UrlHttpTransport or injected BinaryHttpExchange")
        }
    },
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun ensureAttachmentRelease(
        owner: String,
        repo: String,
        token: String,
        tag: String = "crewrp-attachments",
    ): Int {
        val get = transport.rest("GET", "$apiBase/repos/$owner/$repo/releases/tags/$tag", token)
        if (get.status == 200) {
            return json.parseToJsonElement(get.body).jsonObject["id"]!!.jsonPrimitive.int
        }
        val create = transport.rest(
            "POST",
            "$apiBase/repos/$owner/$repo/releases",
            token,
            """{"tag_name":"$tag","name":"CrewRP Attachments","draft":false,"prerelease":true}""",
        )
        require(create.status in 200..299) { "github http ${create.status}" }
        return json.parseToJsonElement(create.body).jsonObject["id"]!!.jsonPrimitive.int
    }

    fun listAssets(owner: String, repo: String, releaseId: Int, token: String): List<AttachmentEntry> {
        val result = transport.rest("GET", "$apiBase/repos/$owner/$repo/releases/$releaseId/assets", token)
        require(result.status in 200..299) { "github http ${result.status}" }
        return decodeAssets(result.body)
    }

    fun listAttachments(
        owner: String,
        repo: String,
        token: String,
        tag: String = "crewrp-attachments",
    ): List<AttachmentEntry> {
        val releaseId = ensureAttachmentRelease(owner, repo, token, tag)
        return listAssets(owner, repo, releaseId, token)
    }

    fun upload(
        owner: String,
        repo: String,
        releaseId: Int,
        name: String,
        bytes: ByteArray,
        contentType: String,
        token: String,
    ): AttachmentEntry {
        val encoded = URLEncoder.encode(name, Charsets.UTF_8.name())
        val url = "$uploadsBase/repos/$owner/$repo/releases/$releaseId/assets?name=$encoded"
        val result = binary.exchange(
            "POST",
            url,
            mapOf(
                "Authorization" to "Bearer $token",
                "Content-Type" to contentType,
                "Accept" to "application/vnd.github+json",
            ),
            bytes,
        )
        require(result.status in 200..299) { "github http ${result.status}" }
        return decodeAsset(result.body)
    }

    fun uploadAttachment(
        owner: String,
        repo: String,
        name: String,
        bytes: ByteArray,
        contentType: String,
        token: String,
        tag: String = "crewrp-attachments",
    ): AttachmentEntry {
        val releaseId = ensureAttachmentRelease(owner, repo, token, tag)
        return upload(owner, repo, releaseId, name, bytes, contentType, token)
    }

    fun downloadBytes(asset: AttachmentEntry, token: String): ByteArray {
        val result = binary.exchange(
            "GET",
            asset.apiUrl,
            mapOf(
                "Authorization" to "Bearer $token",
                "Accept" to "application/octet-stream",
            ),
            null,
        )
        require(result.status in 200..299) { "github http ${result.status}" }
        return if (result.bodyBytes.isNotEmpty()) result.bodyBytes else result.body.toByteArray(Charsets.ISO_8859_1)
    }

    private fun decodeAssets(body: String): List<AttachmentEntry> {
        val arr = json.parseToJsonElement(body)
        require(arr is JsonArray) { "expected assets array" }
        return arr.jsonArray.map { decodeAssetElement(it.jsonObject) }
    }

    private fun decodeAsset(body: String): AttachmentEntry =
        decodeAssetElement(json.parseToJsonElement(body).jsonObject)

    private fun decodeAssetElement(obj: kotlinx.serialization.json.JsonObject): AttachmentEntry =
        AttachmentEntry(
            id = obj["id"]!!.jsonPrimitive.int,
            name = obj["name"]!!.jsonPrimitive.content,
            contentType = obj["content_type"]?.jsonPrimitive?.contentOrNull,
            size = obj["size"]!!.jsonPrimitive.int,
            browserDownloadUrl = obj["browser_download_url"]!!.jsonPrimitive.content,
            apiUrl = obj["url"]!!.jsonPrimitive.content,
        )
}
