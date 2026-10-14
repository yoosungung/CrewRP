package app.crewrp.core

import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

data class StudySubject(
    val id: String,
    val title: String,
)

data class StudyCourseSummary(
    val id: String,
    val title: String,
)

data class RecentStudyEntry(
    val subjectId: String,
    val courseId: String,
    val title: String,
    val openedAtEpochSec: Long,
)

const val STUDY_ROOT = ".crewrp/study"
const val RECENT_STUDY_CACHE_KEY = "crewrp://study/recent"
const val RECENT_STUDY_MAX = 10

fun subjectsPath(): String = "$STUDY_ROOT/subjects.json"

fun coursesPath(subjectId: String): String = "$STUDY_ROOT/$subjectId/courses.json"

fun courseAssetPath(subjectId: String, courseId: String): String =
    "$STUDY_ROOT/$subjectId/$courseId/course.json"

fun conceptsPath(subjectId: String, courseId: String): String =
    "$STUDY_ROOT/$subjectId/$courseId/concepts.json"

fun parseSubjectsJson(json: String): List<StudySubject> {
    val arr = JSONArray(json)
    val out = mutableListOf<StudySubject>()
    for (i in 0 until arr.length()) {
        val o = arr.getJSONObject(i)
        val id = o.optString("id").trim()
        if (id.isEmpty()) continue
        out += StudySubject(id, o.optString("title").ifBlank { id })
    }
    return out
}

fun subjectsToJson(subjects: List<StudySubject>): String {
    val arr = JSONArray()
    for (s in subjects) {
        arr.put(JSONObject().put("id", s.id).put("title", s.title))
    }
    return arr.toString(2) + "\n"
}

fun parseCourseSummariesJson(json: String): List<StudyCourseSummary> {
    val arr = JSONArray(json)
    val out = mutableListOf<StudyCourseSummary>()
    for (i in 0 until arr.length()) {
        val o = arr.getJSONObject(i)
        val id = o.optString("id").trim()
        if (id.isEmpty()) continue
        out += StudyCourseSummary(id, o.optString("title").ifBlank { id })
    }
    return out
}

fun courseSummariesToJson(courses: List<StudyCourseSummary>): String {
    val arr = JSONArray()
    for (c in courses) {
        arr.put(JSONObject().put("id", c.id).put("title", c.title))
    }
    return arr.toString(2) + "\n"
}

fun parseRecentStudyJson(json: String): List<RecentStudyEntry> {
    if (json.isBlank()) return emptyList()
    val arr = JSONArray(json)
    val out = mutableListOf<RecentStudyEntry>()
    for (i in 0 until arr.length()) {
        val o = arr.getJSONObject(i)
        out += RecentStudyEntry(
            subjectId = o.getString("subjectId"),
            courseId = o.getString("courseId"),
            title = o.optString("title"),
            openedAtEpochSec = o.optLong("openedAtEpochSec"),
        )
    }
    return out
}

fun recentStudyToJson(entries: List<RecentStudyEntry>): String {
    val arr = JSONArray()
    for (e in entries) {
        arr.put(
            JSONObject()
                .put("subjectId", e.subjectId)
                .put("courseId", e.courseId)
                .put("title", e.title)
                .put("openedAtEpochSec", e.openedAtEpochSec),
        )
    }
    return arr.toString()
}

fun loadRecentStudy(cache: CacheStore): List<RecentStudyEntry> {
    val body = cache.cacheEntry(RECENT_STUDY_CACHE_KEY)?.body ?: return emptyList()
    return runCatching { parseRecentStudyJson(body) }.getOrDefault(emptyList())
}

fun recordRecentStudy(
    cache: CacheStore,
    entry: RecentStudyEntry,
    max: Int = RECENT_STUDY_MAX,
): List<RecentStudyEntry> {
    val next = listOf(entry) + loadRecentStudy(cache).filterNot {
        it.subjectId == entry.subjectId && it.courseId == entry.courseId
    }
    val trimmed = next.take(max)
    cache.putCacheEntry(RECENT_STUDY_CACHE_KEY, recentStudyToJson(trimmed), null)
    return trimmed
}

class StudyCatalogClient(
    private val transport: HttpTransport,
    private val apiBase: String = "https://api.github.com",
) {
    fun fetchText(owner: String, repo: String, path: String, token: String): Pair<String, String?>? {
        val url = "$apiBase/repos/$owner/$repo/contents/$path"
        val headers = mapOf(
            "Authorization" to "Bearer $token",
            "Accept" to "application/vnd.github+json",
            "X-GitHub-Api-Version" to "2022-11-28",
        )
        val result = transport.exchange("GET", url, headers, null)
        if (result.status == 404) return null
        require(result.status in 200..299) { "github http ${result.status}" }
        val obj = JSONObject(result.body)
        val encoding = obj.optString("encoding")
        val content = obj.optString("content")
        val sha = obj.optString("sha").ifBlank { null }
        require(encoding == "base64" && content.isNotBlank()) { "expected base64 content" }
        val bytes = Base64.getMimeDecoder().decode(content.replace("\n", ""))
        return bytes.toString(Charsets.UTF_8) to sha
    }

    fun putText(
        owner: String,
        repo: String,
        path: String,
        content: String,
        token: String,
        sha: String?,
        message: String = "학습 저장",
    ): String? {
        require(path.startsWith("$STUDY_ROOT/")) { "path must be under $STUDY_ROOT/" }
        val encoded = Base64.getEncoder().encodeToString(content.toByteArray(Charsets.UTF_8))
        val body = JSONObject()
            .put("message", message)
            .put("content", encoded)
        if (sha != null) body.put("sha", sha)
        val result = transport.rest(
            "PUT",
            "$apiBase/repos/$owner/$repo/contents/$path",
            token,
            body.toString(),
        )
        require(result.status in 200..299) { "github http ${result.status}" }
        return JSONObject(result.body).optJSONObject("content")?.optString("sha")?.ifBlank { null }
    }

    fun listSubjects(owner: String, repo: String, token: String): List<StudySubject> {
        val text = fetchText(owner, repo, subjectsPath(), token)?.first ?: return emptyList()
        return parseSubjectsJson(text)
    }

    fun listCourses(owner: String, repo: String, subjectId: String, token: String): List<StudyCourseSummary> {
        val text = fetchText(owner, repo, coursesPath(subjectId), token)?.first ?: return emptyList()
        return parseCourseSummariesJson(text)
    }

    fun loadCourseAsset(owner: String, repo: String, subjectId: String, courseId: String, token: String): CourseAsset? {
        val text = fetchText(owner, repo, courseAssetPath(subjectId, courseId), token)?.first ?: return null
        return CourseAsset.parse(text)
    }
}
