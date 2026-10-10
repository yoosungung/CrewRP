package app.crewrp.core

import java.time.Instant
import java.util.Base64
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
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
        val etag = result.header("ETag") ?: result.header("Etag")
        runCatching { cache.putCacheEntry(url, result.body, etag) }
        return CachedHTTPResponse(result.status, result.body, etag, false)
    }
}

data class DocFile(val path: String, val content: String, val sha: String? = null)

class DocsClient(
    private val transport: HttpTransport,
    private val cache: CacheStore,
    private val apiBase: String = "https://api.github.com",
) {
    private val rest = ETagRESTClient(transport, cache)
    private val json = Json { ignoreUnknownKeys = true }

    @Serializable
    private data class ContentDTO(
        val path: String,
        val name: String? = null,
        val content: String? = null,
        val encoding: String? = null,
        val sha: String? = null,
        val type: String? = null,
    )

    fun listDocs(owner: String, repo: String, token: String, path: String = "docs"): List<DocEntry> {
        val response = try {
            rest.get("$apiBase/repos/$owner/$repo/contents/$path", token)
        } catch (e: IllegalArgumentException) {
            if (e.message?.contains("404") == true) return emptyList()
            throw e
        }
        if (response.statusCode == 404) return emptyList()
        val el = json.parseToJsonElement(response.body)
        if (el !is kotlinx.serialization.json.JsonArray) return emptyList()
        return el.mapNotNull { node ->
            if (node !is JsonObject) return@mapNotNull null
            val p = node["path"].textOrNull() ?: return@mapNotNull null
            val name = node["name"].textOrNull() ?: p.substringAfterLast('/')
            val type = node["type"].textOrNull()
            DocEntry(p, name, node["sha"].textOrNull(), type == "dir")
        }
    }

    /** `/docs` 이하 재귀 목록(검색 인덱스). TTL·tree SHA로 네트워크를 줄인다. */
    fun listDocsTree(
        owner: String,
        repo: String,
        token: String,
        prefix: String = "docs",
        forceNetwork: Boolean = false,
        now: Instant = Instant.now(),
    ): List<DocEntry> {
        val queryName = GraphQLFreshness.docsTreeQueryName(owner, repo)
        if (!forceNetwork) {
            GraphQLFreshness.freshBody(cache, queryName, now)?.let { body ->
                return runCatching {
                    json.decodeFromString(ListSerializer(DocEntry.serializer()), body)
                }.getOrNull() ?: emptyList()
            }
        }

        val branch = try {
            defaultBranch(owner, repo, token)
        } catch (e: IllegalArgumentException) {
            if (e.message?.contains("404") == true) return emptyList()
            throw e
        }

        if (!forceNetwork) {
            val storedSha = GraphQLFreshness.storedCursor(cache, queryName)
            val cached = GraphQLFreshness.cachedBody(cache, queryName)
            if (storedSha != null && cached != null) {
                val entries = runCatching {
                    json.decodeFromString(ListSerializer(DocEntry.serializer()), cached)
                }.getOrNull()
                if (entries != null) {
                    try {
                        val shallow = fetchGitTree(owner, repo, branch, token, recursive = false)
                        if (shallow.first == storedSha) {
                            GraphQLFreshness.store(cache, queryName, cached, now, storedSha)
                            return entries
                        }
                    } catch (e: IllegalArgumentException) {
                        if (e.message?.contains("404") == true) return emptyList()
                    }
                }
            }
        }

        val tree = try {
            fetchGitTree(owner, repo, branch, token, recursive = true)
        } catch (e: IllegalArgumentException) {
            if (e.message?.contains("404") == true) return emptyList()
            throw e
        }
        val entries = docsEntriesFromGitTree(tree.second, prefix)
        val body = json.encodeToString(ListSerializer(DocEntry.serializer()), entries)
        GraphQLFreshness.store(cache, queryName, body, now, tree.first)
        return entries
    }

    private fun defaultBranch(owner: String, repo: String, token: String): String {
        val response = rest.get("$apiBase/repos/$owner/$repo", token)
        return json.parseToJsonElement(response.body).jsonObject["default_branch"]?.jsonPrimitive?.content
            ?: error("missing default_branch")
    }

    private fun fetchGitTree(
        owner: String,
        repo: String,
        ref: String,
        token: String,
        recursive: Boolean,
    ): Pair<String, List<GitTreeNode>> {
        val url = buildString {
            append("$apiBase/repos/$owner/$repo/git/trees/$ref")
            if (recursive) append("?recursive=1")
        }
        val response = rest.get(url, token)
        val obj = json.parseToJsonElement(response.body).jsonObject
        val sha = obj["sha"]?.jsonPrimitive?.content ?: error("missing tree sha")
        val nodes = obj["tree"]?.jsonArray.orEmpty().mapNotNull { el ->
            if (el !is JsonObject) return@mapNotNull null
            val path = el["path"].textOrNull() ?: return@mapNotNull null
            val type = el["type"].textOrNull() ?: return@mapNotNull null
            GitTreeNode(path, type, el["sha"].textOrNull())
        }
        return sha to nodes
    }

    fun fetchMarkdown(owner: String, repo: String, path: String, token: String): DocFile {
        val url = "$apiBase/repos/$owner/$repo/contents/$path"
        val response = rest.get(url, token)
        val dto = json.decodeFromString(ContentDTO.serializer(), response.body)
        require(dto.encoding == "base64" && dto.content != null)
        val bytes = Base64.getMimeDecoder().decode(dto.content.replace("\n", ""))
        return DocFile(dto.path, bytes.toString(Charsets.UTF_8), dto.sha)
    }

    fun saveMarkdown(owner: String, repo: String, path: String, content: String, token: String, sha: String?): DocFile {
        require(path.startsWith("docs/")) { "path must be under docs/" }
        val encoded = Base64.getEncoder().encodeToString(content.toByteArray(Charsets.UTF_8))
        val body = buildJsonObject {
            put("message", "자료 저장")
            put("content", encoded)
            if (sha != null) put("sha", sha)
        }.toString()
        val result = transport.rest("PUT", "$apiBase/repos/$owner/$repo/contents/$path", token, body)
        require(result.status in 200..299) { "github http ${result.status}" }
        val contentObj = json.parseToJsonElement(result.body).jsonObject["content"]?.jsonObject
        val newSha = contentObj?.get("sha").textOrNull()
        return DocFile(path, content, newSha)
    }

    fun deleteDoc(owner: String, repo: String, path: String, sha: String, token: String) {
        require(path.startsWith("docs/")) { "path must be under docs/" }
        val body = buildJsonObject {
            put("message", "자료 삭제")
            put("sha", sha)
        }.toString()
        val result = transport.rest("DELETE", "$apiBase/repos/$owner/$repo/contents/$path", token, body)
        require(result.status in 200..299) { "github http ${result.status}" }
    }
}

internal fun isProjectsDueFieldName(name: String?): Boolean {
    val n = name?.trim() ?: return false
    return n.equals("Due", ignoreCase = true) ||
        n.equals("Date", ignoreCase = true) ||
        n.equals("Due date", ignoreCase = true)
}

@Serializable
data class TaskCard(
    val id: String,
    val title: String,
    val status: String,
    val dueOn: String?,
    val issueNumber: Int? = null,
    val contentId: String? = null,
    val body: String = "",
)

class ProjectsClient(
    private val transport: HttpTransport,
    private val apiBase: String = "https://api.github.com",
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun sortedByDueDate(cards: List<TaskCard>): List<TaskCard> =
        cards.sortedBy { it.dueOn ?: "9999" }

    /** Lowest Projects v2 number for a user/org login, or null if none. */
    fun firstProjectNumber(owner: String, token: String): Int? {
        val query = """
            query(${'$'}login:String!){
              organization(login:${'$'}login){ projectsV2(first:20){ nodes{ number } } }
              user(login:${'$'}login){ projectsV2(first:20){ nodes{ number } } }
            }
        """.trimIndent()
        val root = Graphql.post(
            transport,
            apiBase,
            token,
            query,
            buildJsonObject { put("login", owner) },
        )
        val data = root["data"]?.jsonObject ?: return null
        fun numbers(key: String): List<Int> {
            val nodes = data[key]?.takeUnless { it is JsonNull }?.jsonObject
                ?.get("projectsV2")?.takeUnless { it is JsonNull }?.jsonObject
                ?.get("nodes")?.jsonArray ?: return emptyList()
            return nodes.mapNotNull { (it as? JsonObject)?.get("number")?.jsonPrimitive?.intOrNull }
        }
        return (numbers("organization") + numbers("user")).minOrNull()
    }

    /**
     * Prefer [preferred] when that Projects v2 exists; otherwise the lowest existing
     * number, or create a user project named "CrewRP".
     */
    fun resolveProjectNumber(owner: String, preferred: Int, token: String): Int {
        if (loadFieldMeta(owner, preferred, token) != null) return preferred
        return firstProjectNumber(owner, token) ?: createUserProject(owner, "CrewRP", token)
    }

    /** Creates a user-owned Project v2 and returns its number. */
    fun createUserProject(ownerLogin: String, title: String, token: String): Int {
        val idRoot = Graphql.post(
            transport,
            apiBase,
            token,
            """query(${'$'}login:String!){ user(login:${'$'}login){ id } }""",
            buildJsonObject { put("login", ownerLogin) },
        )
        val ownerId = idRoot["data"]?.jsonObject?.get("user")?.jsonObject?.get("id").textOrNull()
            ?: error("missing user id")
        val created = Graphql.post(
            transport,
            apiBase,
            token,
            """
            mutation(${'$'}ownerId:ID!,${'$'}title:String!){
              createProjectV2(input:{ownerId:${'$'}ownerId,title:${'$'}title}){
                projectV2 { number }
              }
            }
            """.trimIndent(),
            buildJsonObject {
                put("ownerId", ownerId)
                put("title", title)
            },
        )
        return created["data"]?.jsonObject
            ?.get("createProjectV2")?.jsonObject
            ?.get("projectV2")?.jsonObject
            ?.get("number")?.jsonPrimitive?.intOrNull
            ?: error("missing project number")
    }

    fun listTasks(
        owner: String,
        projectNumber: Int,
        token: String,
        cache: CacheStore? = null,
        forceNetwork: Boolean = false,
        now: Instant = Instant.now(),
    ): List<TaskCard> {
        val queryName = GraphQLFreshness.listTasksQueryName(owner, projectNumber)
        if (!forceNetwork && cache != null) {
            GraphQLFreshness.freshBody(cache, queryName, now)?.let { body ->
                return json.decodeFromString(ListSerializer(TaskCard.serializer()), body)
            }
        }
        val cards = queryProjectItems("organization", owner, projectNumber, token)
            ?: queryProjectItems("user", owner, projectNumber, token)
            ?: emptyList()
        if (cache != null) {
            GraphQLFreshness.store(
                cache,
                queryName,
                json.encodeToString(ListSerializer(TaskCard.serializer()), cards),
                now,
            )
        }
        return cards
    }

    fun loadFieldMeta(owner: String, projectNumber: Int, token: String): ProjectFieldMeta? {
        val query = """
            query(${'$'}login:String!,${'$'}number:Int!){
              organization(login:${'$'}login){
                projectV2(number:${'$'}number){
                  id
                  fields(first:50){
                    nodes{
                      ... on ProjectV2SingleSelectField { id name options { id name } }
                  ... on ProjectV2Field { id name dataType }
                  ... on ProjectV2FieldCommon { id name }
                    }
                  }
                }
              }
              user(login:${'$'}login){
                projectV2(number:${'$'}number){
                  id
                  fields(first:50){
                    nodes{
                      ... on ProjectV2SingleSelectField { id name options { id name } }
                  ... on ProjectV2Field { id name dataType }
                  ... on ProjectV2FieldCommon { id name }
                    }
                  }
                }
              }
            }
        """.trimIndent()
        val root = Graphql.post(
            transport,
            apiBase,
            token,
            query,
            buildJsonObject {
                put("login", owner)
                put("number", projectNumber)
            },
        )
        val data = root["data"]?.jsonObject ?: return null
        val project = data["organization"]?.takeUnless { it is JsonNull }?.jsonObject?.get("projectV2")
            ?.takeUnless { it is JsonNull }?.jsonObject
            ?: data["user"]?.takeUnless { it is JsonNull }?.jsonObject?.get("projectV2")
                ?.takeUnless { it is JsonNull }?.jsonObject
            ?: return null
        val projectId = project["id"].textOrNull() ?: return null
        var statusFieldId: String? = null
        var dueFieldId: String? = null
        var dateFieldId: String? = null
        val options = mutableMapOf<String, String>()
        project["fields"]?.jsonObject?.get("nodes")?.jsonArray?.forEach { node ->
            if (node !is JsonObject) return@forEach
            val fieldName = node["name"].textOrNull()
            val dataType = node["dataType"].textOrNull()
            when {
                fieldName == "Status" -> {
                    statusFieldId = node["id"].textOrNull()
                    node["options"]?.jsonArray?.forEach { opt ->
                        val o = opt as? JsonObject ?: return@forEach
                        val name = o["name"].textOrNull() ?: return@forEach
                        val id = o["id"].textOrNull() ?: return@forEach
                        options[name] = id
                    }
                }
                isProjectsDueFieldName(fieldName) -> dueFieldId = node["id"].textOrNull()
                dataType.equals("DATE", ignoreCase = true) && dateFieldId == null ->
                    dateFieldId = node["id"].textOrNull()
            }
        }
        return ProjectFieldMeta(projectId, statusFieldId, dueFieldId ?: dateFieldId, options)
    }

    fun ensureDueDateField(meta: ProjectFieldMeta, owner: String, projectNumber: Int, token: String): ProjectFieldMeta {
        if (meta.dueFieldId != null) return meta
        Graphql.post(
            transport,
            apiBase,
            token,
            """
            mutation(${'$'}projectId:ID!){
              createProjectV2Field(input:{projectId:${'$'}projectId,dataType:DATE,name:"Due date"}){
                projectV2Field { ... on ProjectV2Field { id name } }
              }
            }
            """.trimIndent(),
            buildJsonObject { put("projectId", meta.projectId) },
        )
        return loadFieldMeta(owner, projectNumber, token) ?: meta
    }

    fun createTask(
        owner: String,
        repo: String,
        title: String,
        body: String,
        projectNumber: Int,
        token: String,
        dueOn: String? = null,
        statusLabel: String = "접수",
    ): TaskCard {
        val issueBody = buildJsonObject {
            put("title", title)
            put("body", body)
        }.toString()
        val created = transport.rest("POST", "$apiBase/repos/$owner/$repo/issues", token, issueBody)
        require(created.status in 200..299) { "github http ${created.status}" }
        val issue = json.parseToJsonElement(created.body).jsonObject
        val number = issue["number"]?.jsonPrimitive?.content?.toIntOrNull() ?: error("missing issue number")
        val nodeId = issue["node_id"].textOrNull() ?: error("missing node_id")
        val meta = try {
            val loaded = loadFieldMeta(owner, projectNumber, token) ?: error("missing project")
            ensureDueDateField(loaded, owner, projectNumber, token)
        } catch (e: Throwable) {
            // Avoid orphan issues when project scope/meta is missing.
            runCatching {
                transport.rest(
                    "PATCH",
                    "$apiBase/repos/$owner/$repo/issues/$number",
                    token,
                    """{"state":"closed"}""",
                )
            }
            throw e
        }
        val added = Graphql.post(
            transport,
            apiBase,
            token,
            """
            mutation(${'$'}projectId:ID!,${'$'}contentId:ID!){
              addProjectV2ItemById(input:{projectId:${'$'}projectId,contentId:${'$'}contentId}){
                item { id }
              }
            }
            """.trimIndent(),
            buildJsonObject {
                put("projectId", meta.projectId)
                put("contentId", nodeId)
            },
        )
        val itemId = added["data"]?.jsonObject
            ?.get("addProjectV2ItemById")?.jsonObject
            ?.get("item")?.jsonObject
            ?.get("id").textOrNull()
            ?: error("missing project item")
        val statusOpt = meta.statusOptions.entries.firstOrNull {
            it.key == statusLabel || taskLane(it.key) == taskLane(statusLabel)
        }?.value
        updateTaskFields(
            projectId = meta.projectId,
            itemId = itemId,
            statusFieldId = meta.statusFieldId,
            statusOptionId = statusOpt,
            dueFieldId = meta.dueFieldId,
            dueOn = dueOn,
            token = token,
        )
        return TaskCard(itemId, title, statusLabel, dueOn, number, nodeId, body)
    }

    fun updateIssue(owner: String, repo: String, issueNumber: Int, title: String, body: String, token: String) {
        val payload = buildJsonObject {
            put("title", title)
            put("body", body)
        }.toString()
        val result = transport.rest("PATCH", "$apiBase/repos/$owner/$repo/issues/$issueNumber", token, payload)
        require(result.status in 200..299) { "github http ${result.status}" }
    }

    fun updateTaskFields(
        projectId: String,
        itemId: String,
        statusFieldId: String?,
        statusOptionId: String?,
        dueFieldId: String?,
        dueOn: String?,
        token: String,
    ) {
        if (statusFieldId != null && statusOptionId != null) {
            Graphql.post(
                transport,
                apiBase,
                token,
                """
                mutation(${'$'}input:UpdateProjectV2ItemFieldValueInput!){
                  updateProjectV2ItemFieldValue(input:${'$'}input){ projectV2Item { id } }
                }
                """.trimIndent(),
                buildJsonObject {
                    putJsonObject("input") {
                        put("projectId", projectId)
                        put("itemId", itemId)
                        put("fieldId", statusFieldId)
                        putJsonObject("value") { put("singleSelectOptionId", statusOptionId) }
                    }
                },
            )
        }
        if (dueFieldId != null && dueOn != null) {
            Graphql.post(
                transport,
                apiBase,
                token,
                """
                mutation(${'$'}input:UpdateProjectV2ItemFieldValueInput!){
                  updateProjectV2ItemFieldValue(input:${'$'}input){ projectV2Item { id } }
                }
                """.trimIndent(),
                buildJsonObject {
                    putJsonObject("input") {
                        put("projectId", projectId)
                        put("itemId", itemId)
                        put("fieldId", dueFieldId)
                        putJsonObject("value") { put("date", dueOn) }
                    }
                },
            )
        }
    }

    fun deleteTask(projectId: String, itemId: String, owner: String, repo: String, issueNumber: Int?, token: String) {
        Graphql.post(
            transport,
            apiBase,
            token,
            """
            mutation(${'$'}input:DeleteProjectV2ItemInput!){
              deleteProjectV2Item(input:${'$'}input){ deletedItemId }
            }
            """.trimIndent(),
            buildJsonObject {
                putJsonObject("input") {
                    put("projectId", projectId)
                    put("itemId", itemId)
                }
            },
        )
        if (issueNumber != null) {
            transport.rest(
                "PATCH",
                "$apiBase/repos/$owner/$repo/issues/$issueNumber",
                token,
                """{"state":"closed"}""",
            )
        }
    }

    private fun queryProjectItems(kind: String, login: String, projectNumber: Int, token: String): List<TaskCard>? {
        val rootField = if (kind == "organization") "organization" else "user"
        val query = """
            query(${'$'}login:String!,${'$'}number:Int!){
              $rootField(login:${'$'}login){
                projectV2(number:${'$'}number){
                  items(first:50){
                    nodes{
                      id
                      content{
                        ... on Issue { title body number id }
                      }
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
        val root = Graphql.post(
            transport,
            apiBase,
            token,
            query,
            buildJsonObject {
                put("login", login)
                put("number", projectNumber)
            },
        )
        val container = root["data"]?.jsonObject?.get(rootField)
        if (container == null || container is JsonNull) return null
        val project = container.jsonObject["projectV2"]
        if (project == null || project is JsonNull) return null
        return parseTaskCards(project.jsonObject)
    }

    private fun parseTaskCards(project: JsonObject): List<TaskCard> {
        val nodes = project["items"]?.jsonObject?.get("nodes")?.jsonArray ?: return emptyList()
        return nodes.mapNotNull { element ->
            if (element !is JsonObject) return@mapNotNull null
            val id = element["id"].textOrNull() ?: return@mapNotNull null
            val content = element["content"]?.takeUnless { it is JsonNull }?.jsonObject
            val title = content?.get("title").textOrNull() ?: "(제목 없음)"
            val body = content?.get("body").textOrNull().orEmpty()
            val issueNumber = content?.get("number")?.let {
                (it as? JsonPrimitive)?.content?.toIntOrNull()
            }
            val contentId = content?.get("id").textOrNull()
            var status = "접수"
            var due: String? = null
            element["fieldValues"]?.jsonObject?.get("nodes")?.jsonArray?.forEach { fieldEl ->
                if (fieldEl !is JsonObject) return@forEach
                val fieldName = fieldEl["field"]?.takeUnless { it is JsonNull }?.jsonObject?.get("name").textOrNull()
                when {
                    fieldName == "Status" -> fieldEl["name"].textOrNull()?.let { status = it }
                    isProjectsDueFieldName(fieldName) -> due = fieldEl["date"].textOrNull()
                    due == null -> fieldEl["date"].textOrNull()?.let { due = it }
                }
            }
            TaskCard(id, title, status, due, issueNumber, contentId, body)
        }
    }
}

@Serializable
data class Notice(val id: String, val title: String, val body: String, val authorLogin: String? = null)

class DiscussionsClient(
    private val transport: HttpTransport,
    private val apiBase: String = "https://api.github.com",
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun listNotices(
        owner: String,
        repo: String,
        token: String,
        cache: CacheStore? = null,
        forceNetwork: Boolean = false,
        now: Instant = Instant.now(),
    ): List<Notice> {
        val queryName = GraphQLFreshness.listNoticesQueryName(owner, repo)
        if (!forceNetwork && cache != null) {
            GraphQLFreshness.freshBody(cache, queryName, now)?.let { body ->
                return json.decodeFromString(ListSerializer(Notice.serializer()), body)
            }
        }
        val root = Graphql.post(
            transport,
            apiBase,
            token,
            """
            query(${'$'}owner:String!,${'$'}name:String!){
              repository(owner:${'$'}owner,name:${'$'}name){
                discussions(first:20){ nodes { id title body author { login } } }
              }
            }
            """.trimIndent(),
            buildJsonObject {
                put("owner", owner)
                put("name", repo)
            },
        )
        val repository = root["data"]?.jsonObject?.get("repository") ?: return emptyList()
        if (repository is JsonNull) return emptyList()
        val nodes = repository.jsonObject["discussions"]?.jsonObject?.get("nodes")?.jsonArray
            ?: return emptyList()
        val notices = nodes.mapNotNull { element ->
            if (element !is JsonObject) return@mapNotNull null
            val id = element["id"].textOrNull() ?: return@mapNotNull null
            Notice(
                id,
                element["title"].textOrNull().orEmpty(),
                element["body"].textOrNull().orEmpty(),
                element["author"]?.takeUnless { it is JsonNull }?.jsonObject?.get("login").textOrNull(),
            )
        }
        if (cache != null) {
            GraphQLFreshness.store(
                cache,
                queryName,
                json.encodeToString(ListSerializer(Notice.serializer()), notices),
                now,
            )
        }
        return notices
    }

    fun getNotice(id: String, token: String): Notice {
        val root = Graphql.post(
            transport,
            apiBase,
            token,
            """
            query(${'$'}id:ID!){
              node(id:${'$'}id){
                ... on Discussion { id title body author { login } }
              }
            }
            """.trimIndent(),
            buildJsonObject { put("id", id) },
        )
        val node = root["data"]?.jsonObject?.get("node")?.jsonObject ?: error("missing notice")
        return Notice(
            node["id"].textOrNull().orEmpty(),
            node["title"].textOrNull().orEmpty(),
            node["body"].textOrNull().orEmpty(),
            node["author"]?.takeUnless { it is JsonNull }?.jsonObject?.get("login").textOrNull(),
        )
    }

    fun resolveSetup(owner: String, repo: String, token: String): DiscussionSetup {
        val root = Graphql.post(
            transport,
            apiBase,
            token,
            """
            query(${'$'}owner:String!,${'$'}name:String!){
              repository(owner:${'$'}owner,name:${'$'}name){
                id
                discussionCategories(first:20){ nodes { id name } }
              }
            }
            """.trimIndent(),
            buildJsonObject {
                put("owner", owner)
                put("name", repo)
            },
        )
        val repository = root["data"]?.jsonObject?.get("repository")?.jsonObject
            ?: error("missing repository")
        val repoId = repository["id"].textOrNull() ?: error("missing repository id")
        val categories = repository["discussionCategories"]?.jsonObject?.get("nodes")?.jsonArray.orEmpty()
            .mapNotNull { el ->
                val o = el as? JsonObject ?: return@mapNotNull null
                val id = o["id"].textOrNull() ?: return@mapNotNull null
                id to o["name"].textOrNull().orEmpty()
            }
        val preferred = categories.firstOrNull { it.second.contains("공지") }
            ?: categories.firstOrNull()
            ?: error("no discussion category")
        return DiscussionSetup(repoId, preferred.first)
    }

    fun createNotice(repositoryId: String, categoryId: String, title: String, body: String, token: String): Notice {
        val root = Graphql.post(
            transport,
            apiBase,
            token,
            """
            mutation(${'$'}input:CreateDiscussionInput!){
              createDiscussion(input:${'$'}input){ discussion { id title body author { login } } }
            }
            """.trimIndent(),
            buildJsonObject {
                putJsonObject("input") {
                    put("repositoryId", repositoryId)
                    put("categoryId", categoryId)
                    put("title", title)
                    put("body", body)
                }
            },
        )
        val d = root["data"]?.jsonObject?.get("createDiscussion")?.jsonObject?.get("discussion")?.jsonObject
            ?: error("create failed")
        return Notice(
            d["id"].textOrNull().orEmpty(),
            d["title"].textOrNull().orEmpty(),
            d["body"].textOrNull().orEmpty(),
            d["author"]?.takeUnless { it is JsonNull }?.jsonObject?.get("login").textOrNull(),
        )
    }

    fun updateNotice(id: String, title: String, body: String, token: String): Notice {
        val root = Graphql.post(
            transport,
            apiBase,
            token,
            """
            mutation(${'$'}input:UpdateDiscussionInput!){
              updateDiscussion(input:${'$'}input){ discussion { id title body author { login } } }
            }
            """.trimIndent(),
            buildJsonObject {
                putJsonObject("input") {
                    put("discussionId", id)
                    put("title", title)
                    put("body", body)
                }
            },
        )
        val d = root["data"]?.jsonObject?.get("updateDiscussion")?.jsonObject?.get("discussion")?.jsonObject
            ?: error("update failed")
        return Notice(
            d["id"].textOrNull().orEmpty(),
            d["title"].textOrNull().orEmpty(),
            d["body"].textOrNull().orEmpty(),
            d["author"]?.takeUnless { it is JsonNull }?.jsonObject?.get("login").textOrNull(),
        )
    }

    fun deleteNotice(id: String, token: String) {
        Graphql.post(
            transport,
            apiBase,
            token,
            """
            mutation(${'$'}input:DeleteDiscussionInput!){
              deleteDiscussion(input:${'$'}input){ discussion { id } }
            }
            """.trimIndent(),
            buildJsonObject {
                putJsonObject("input") { put("id", id) }
            },
        )
    }

    fun vote(pollOptionId: String, token: String) {
        Graphql.post(
            transport,
            apiBase,
            token,
            "mutation(\$input:AddDiscussionPollVoteInput!){ addDiscussionPollVote(input:\$input){ pollOption { id } } }",
            buildJsonObject {
                putJsonObject("input") { put("pollOptionId", pollOptionId) }
            },
        )
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

class IssueFormsClient(
    private val transport: HttpTransport,
    private val apiBase: String = "https://api.github.com",
) {
    fun createIssue(owner: String, repo: String, title: String, body: String, token: String): Int {
        val result = transport.rest(
            "POST",
            "$apiBase/repos/$owner/$repo/issues",
            token,
            buildJsonObject {
                put("title", title)
                put("body", body)
            }.toString(),
        )
        require(result.status in 200..299) { "github http ${result.status}" }
        return Json { ignoreUnknownKeys = true }
            .parseToJsonElement(result.body).jsonObject["number"]
            ?.jsonPrimitive?.content?.toIntOrNull()
            ?: error("missing number")
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

    companion object {
        const val TALK_ISSUE_TITLE = "스레드 톡"
    }

    /** Finds the dedicated talk issue (title `스레드 톡`), else issue `#1`, else creates one. */
    fun ensureTalkIssueNumber(owner: String, repo: String, token: String): Int {
        findOpenIssue(owner, repo, TALK_ISSUE_TITLE, token)?.let { return it }
        if (issueExists(owner, repo, 1, token)) return 1
        return createIssue(owner, repo, TALK_ISSUE_TITLE, "크루 스레드 톡", token)
    }

    private fun findOpenIssue(owner: String, repo: String, title: String, token: String): Int? {
        val result = transport.rest(
            "GET",
            "$apiBase/repos/$owner/$repo/issues?state=open&per_page=50",
            token,
        )
        require(result.status in 200..299) { "github http ${result.status}" }
        if (result.body.isBlank()) return null
        return json.parseToJsonElement(result.body).jsonArray.firstNotNullOfOrNull { element ->
            val o = element as? JsonObject ?: return@firstNotNullOfOrNull null
            if (o["title"].textOrNull() == title) o["number"]?.jsonPrimitive?.intOrNull else null
        }
    }

    private fun issueExists(owner: String, repo: String, number: Int, token: String): Boolean {
        val result = transport.rest("GET", "$apiBase/repos/$owner/$repo/issues/$number", token)
        if (result.status == 404) return false
        require(result.status in 200..299) { "github http ${result.status}" }
        return true
    }

    private fun createIssue(owner: String, repo: String, title: String, body: String, token: String): Int {
        val result = transport.rest(
            "POST",
            "$apiBase/repos/$owner/$repo/issues",
            token,
            buildJsonObject {
                put("title", title)
                put("body", body)
            }.toString(),
        )
        require(result.status in 200..299) { "github http ${result.status}" }
        return json.parseToJsonElement(result.body).jsonObject["number"]?.jsonPrimitive?.intOrNull
            ?: error("missing issue number")
    }

    fun listIssueComments(owner: String, repo: String, issueNumber: Int, token: String): List<ThreadMessage> {
        val result = transport.rest(
            "GET",
            "$apiBase/repos/$owner/$repo/issues/$issueNumber/comments",
            token,
        )
        require(result.status in 200..299) { "github http ${result.status}" }
        if (result.body.isBlank()) return emptyList()
        return json.parseToJsonElement(result.body).jsonArray.mapNotNull { element ->
            if (element !is JsonObject) return@mapNotNull null
            val id = element["id"].textOrNull() ?: return@mapNotNull null
            val author = element["user"]?.takeUnless { it is JsonNull }?.jsonObject?.get("login").textOrNull().orEmpty()
            ThreadMessage(id, element["body"].textOrNull().orEmpty(), author)
        }
    }

    fun postComment(owner: String, repo: String, issueNumber: Int, body: String, token: String): ThreadMessage {
        val result = transport.rest(
            "POST",
            "$apiBase/repos/$owner/$repo/issues/$issueNumber/comments",
            token,
            buildJsonObject { put("body", body) }.toString(),
        )
        require(result.status in 200..299) { "github http ${result.status}" }
        val o = json.parseToJsonElement(result.body).jsonObject
        return ThreadMessage(
            o["id"].textOrNull().orEmpty(),
            o["body"].textOrNull().orEmpty(),
            o["user"]?.jsonObject?.get("login").textOrNull().orEmpty(),
        )
    }

    fun updateComment(owner: String, repo: String, commentId: String, body: String, token: String): ThreadMessage {
        val result = transport.rest(
            "PATCH",
            "$apiBase/repos/$owner/$repo/issues/comments/$commentId",
            token,
            buildJsonObject { put("body", body) }.toString(),
        )
        require(result.status in 200..299) { "github http ${result.status}" }
        val o = json.parseToJsonElement(result.body).jsonObject
        return ThreadMessage(
            o["id"].textOrNull().orEmpty(),
            o["body"].textOrNull().orEmpty(),
            o["user"]?.jsonObject?.get("login").textOrNull().orEmpty(),
        )
    }

    fun deleteComment(owner: String, repo: String, commentId: String, token: String) {
        val result = transport.rest(
            "DELETE",
            "$apiBase/repos/$owner/$repo/issues/comments/$commentId",
            token,
        )
        require(result.status in 200..299) { "github http ${result.status}" }
    }

    fun addReaction(owner: String, repo: String, commentId: String, content: String, token: String) {
        val result = transport.rest(
            "POST",
            "$apiBase/repos/$owner/$repo/issues/comments/$commentId/reactions",
            token,
            buildJsonObject { put("content", content) }.toString(),
        )
        require(result.status in 200..299) { "github http ${result.status}" }
    }
}

private fun kotlinx.serialization.json.JsonElement?.textOrNull(): String? {
    if (this == null || this is JsonNull || this !is JsonPrimitive) return null
    return contentOrNull
}
