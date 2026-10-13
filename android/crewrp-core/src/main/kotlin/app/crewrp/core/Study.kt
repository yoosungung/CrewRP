package app.crewrp.core

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.util.UUID

data class CourseRef(
    val id: String,
    val title: String,
    val subject: String,
    val playbackUrl: String,
)

data class SourceSpan(
    val id: String,
    val courseId: String,
    val concept: String,
    val startSec: Int,
    val endSec: Int,
    val slideLabel: String = "",
)

enum class PathPlacement { PLANNED, SKIPPED, CURRENT, DETOUR }

data class PathItem(
    val sourceSpanId: String,
    val placement: PathPlacement,
    val returnToSpanId: String? = null,
)

enum class TutorScope {
    IN_LECTURE,
    OUT_OF_SCOPE,
    ;

    companion object {
        fun fromJson(raw: String?): TutorScope = when (raw) {
            "out_of_scope" -> OUT_OF_SCOPE
            else -> IN_LECTURE
        }
    }
}

enum class FormulaVerdict { CORRECT, INCORRECT }

data class TutorTurn(
    val id: String,
    val sourceSpanId: String,
    val question: String,
    val escalationStep: Int,
    val citations: List<String>,
    val scope: TutorScope,
    val formulaVerdict: FormulaVerdict? = null,
    val privateThought: String? = null,
)

data class ReviewCard(
    val id: String,
    val sourceSpanId: String,
    val summary: String,
    val createdAtEpochSec: Long,
    val fadesAtEpochSec: Long,
)

enum class StudySplitRatio(val label: String, val mediaWeight: Int, val tutorWeight: Int) {
    MEDIA_HEAVY("7:3", 7, 3),
    BALANCED("5:5", 5, 5),
    TUTOR_HEAVY("3:7", 3, 7),
    ;

    val mediaFraction: Double get() = mediaWeight.toDouble() / (mediaWeight + tutorWeight)

    companion object {
        fun snap(mediaFraction: Double): StudySplitRatio =
            entries.minBy { kotlin.math.abs(it.mediaFraction - mediaFraction) }
    }
}

fun studyCanvasStacksVertically(width: Double, height: Double): Boolean = height >= width

/** YouTube embed URL에 `start` 초를 붙인다. CitationSelected → 재로드용. */
fun embedPlaybackUrl(base: String, startSec: Int?): String {
    if (startSec == null || startSec <= 0) return base
    return try {
        val uri = URI(base)
        val params = linkedMapOf<String, String>()
        uri.query?.split('&')?.filter { it.isNotBlank() }?.forEach { part ->
            val eq = part.indexOf('=')
            if (eq > 0) params[part.substring(0, eq)] = part.substring(eq + 1)
            else params[part] = ""
        }
        params["start"] = startSec.toString()
        val query = params.entries.joinToString("&") { (k, v) -> if (v.isEmpty()) k else "$k=$v" }
        URI(uri.scheme, uri.authority, uri.path, query, uri.fragment).toString()
    } catch (_: Exception) {
        if ('?' in base) "$base&start=$startSec" else "$base?start=$startSec"
    }
}

class CourseAssetException(message: String) : Exception(message)

data class BundledTutorPrompt(
    val sourceSpanId: String,
    val escalationStep: Int,
    val question: String,
    val citations: List<String>,
    val privateThought: String? = null,
    val scope: TutorScope = TutorScope.IN_LECTURE,
)

data class CourseAsset(
    val course: CourseRef,
    val spans: List<SourceSpan>,
    val tutorPrompts: List<BundledTutorPrompt> = emptyList(),
) {
    fun span(id: String): SourceSpan? = spans.firstOrNull { it.id == id }

    fun startSecForCitation(id: String): Int? = span(id)?.startSec

    companion object {
        fun parse(json: String): CourseAsset {
            val root = try {
                JSONObject(json)
            } catch (_: Exception) {
                throw CourseAssetException("invalidJSON")
            }
            val courseObj = root.optJSONObject("course") ?: throw CourseAssetException("missingCourse")
            val id = courseObj.optString("id").trim()
            if (id.isEmpty()) throw CourseAssetException("emptyCourseId")
            val playbackUrl = courseObj.optString("playbackUrl").trim()
            if (playbackUrl.isEmpty()) throw CourseAssetException("emptyPlaybackURL")
            val course = CourseRef(
                id = id,
                title = courseObj.optString("title"),
                subject = courseObj.optString("subject"),
                playbackUrl = playbackUrl,
            )
            val spans = mutableListOf<SourceSpan>()
            val spansArr = root.optJSONArray("spans") ?: JSONArray()
            for (i in 0 until spansArr.length()) {
                val s = spansArr.getJSONObject(i)
                spans += SourceSpan(
                    id = s.getString("id"),
                    courseId = s.getString("courseId"),
                    concept = s.optString("concept"),
                    startSec = s.optInt("startSec"),
                    endSec = s.optInt("endSec"),
                    slideLabel = s.optString("slideLabel"),
                )
            }
            val prompts = mutableListOf<BundledTutorPrompt>()
            val promptsArr = root.optJSONArray("tutorPrompts") ?: JSONArray()
            for (i in 0 until promptsArr.length()) {
                val p = promptsArr.getJSONObject(i)
                val cites = mutableListOf<String>()
                val cArr = p.optJSONArray("citations") ?: JSONArray()
                for (j in 0 until cArr.length()) cites += cArr.getString(j)
                prompts += BundledTutorPrompt(
                    sourceSpanId = p.getString("sourceSpanId"),
                    escalationStep = p.optInt("escalationStep", 1),
                    question = p.getString("question"),
                    citations = cites,
                    privateThought = p.optString("privateThought").ifBlank { null },
                    scope = TutorScope.fromJson(p.optString("scope").ifBlank { null }),
                )
            }
            return CourseAsset(course, spans, prompts)
        }

        fun loadBundled(): CourseAsset = parse(BundledStudyJson.CS_ALGO_INTRO)
    }
}

object TutorContract {
    private val banned = listOf("정답은", "풀이:", "답:", "the answer is", "solution:", "정답:")

    fun isValid(turn: TutorTurn): Boolean {
        val q = turn.question.trim()
        if (q.isEmpty()) return false
        if (turn.escalationStep !in 1..3) return false
        val lower = q.lowercase()
        if (banned.any { lower.contains(it.lowercase()) }) return false
        return when (turn.scope) {
            TutorScope.OUT_OF_SCOPE -> turn.citations.isEmpty()
            TutorScope.IN_LECTURE -> turn.citations.isNotEmpty()
        }
    }
}

class BundledTutorClient(private val asset: CourseAsset) {
    fun turn(sourceSpanId: String, escalationStep: Int): TutorTurn {
        val step = escalationStep.coerceIn(1, 3)
        val prompt = asset.tutorPrompts.firstOrNull { it.sourceSpanId == sourceSpanId && it.escalationStep == step }
            ?: asset.tutorPrompts.firstOrNull { it.sourceSpanId == sourceSpanId }
        if (prompt != null) {
            val turn = TutorTurn(
                id = "bundled-$sourceSpanId-$step",
                sourceSpanId = sourceSpanId,
                question = prompt.question,
                escalationStep = step,
                citations = prompt.citations,
                scope = prompt.scope,
                privateThought = prompt.privateThought,
            )
            check(TutorContract.isValid(turn)) { "bundled prompt violates contract" }
            return turn
        }
        return TutorTurn(
            id = "oos-$sourceSpanId-${UUID.randomUUID()}",
            sourceSpanId = sourceSpanId,
            question = "이 강의에서 짚을 장면이 없습니다. 경로의 다음 장면으로 이동해 보세요.",
            escalationStep = step,
            citations = emptyList(),
            scope = TutorScope.OUT_OF_SCOPE,
        )
    }
}

/** MIT 6.006 L1 (공개 YouTube). 자막·슬라이드 라벨을 배치 1회로 고정한 정적 자산. */
internal object BundledStudyJson {
    val CS_ALGO_INTRO = """
    {
      "course": {
        "id": "cs-algo-intro-01",
        "title": "알고리즘이란 — MIT 6.006 Lecture 1",
        "subject": "CS",
        "playbackUrl": "https://www.youtube.com/embed/HtSuA80QTyo"
      },
      "spans": [
        {
          "id": "span-what-is-algo",
          "courseId": "cs-algo-intro-01",
          "concept": "알고리즘의 정의",
          "startSec": 60,
          "endSec": 240,
          "slideLabel": "What is an algorithm?"
        },
        {
          "id": "span-peak-finding",
          "courseId": "cs-algo-intro-01",
          "concept": "봉우리 찾기",
          "startSec": 480,
          "endSec": 780,
          "slideLabel": "Peak finding"
        },
        {
          "id": "span-asymptotic",
          "courseId": "cs-algo-intro-01",
          "concept": "점근적 복잡도",
          "startSec": 1200,
          "endSec": 1500,
          "slideLabel": "Asymptotic notation"
        }
      ],
      "tutorPrompts": [
        {
          "sourceSpanId": "span-what-is-algo",
          "escalationStep": 1,
          "question": "이 장면에서 알고리즘을 ‘입력 → ? → 출력’으로 말할 때, 가운데에 무엇이 와야 할까요?",
          "citations": ["span-what-is-algo"],
          "privateThought": "절차·규칙 쪽을 유도",
          "scope": "in_lecture"
        },
        {
          "sourceSpanId": "span-what-is-algo",
          "escalationStep": 2,
          "question": "요리 레시피와 비슷한 점이 있다면, 어떤 ‘단계’가 요리법과 대응될까요?",
          "citations": ["span-what-is-algo"],
          "scope": "in_lecture"
        },
        {
          "sourceSpanId": "span-what-is-algo",
          "escalationStep": 3,
          "question": "방금 떠올린 단서를 한 문장으로만 말해 볼래요? 힌트는 더 주지 않을게요.",
          "citations": ["span-what-is-algo"],
          "scope": "in_lecture"
        },
        {
          "sourceSpanId": "span-peak-finding",
          "escalationStep": 1,
          "question": "1차원 배열에서 ‘봉우리’라면, 이웃과 비교할 때 어떤 조건을 만족해야 할까요?",
          "citations": ["span-peak-finding"],
          "scope": "in_lecture"
        },
        {
          "sourceSpanId": "span-peak-finding",
          "escalationStep": 2,
          "question": "배열 전체를 훑지 않고 가운데부터 본다면, 어느 쪽으로 좁혀 가면 될까요?",
          "citations": ["span-peak-finding", "span-what-is-algo"],
          "scope": "in_lecture"
        },
        {
          "sourceSpanId": "span-peak-finding",
          "escalationStep": 3,
          "question": "직전에 생각한 ‘좁히는 방향’을 직접 설명해 보세요.",
          "citations": ["span-peak-finding"],
          "scope": "in_lecture"
        },
        {
          "sourceSpanId": "span-asymptotic",
          "escalationStep": 1,
          "question": "입력이 커질 때 ‘얼마나 느려지는지’를 한 글자로 적는다면, 무엇을 보고 고를까요?",
          "citations": ["span-asymptotic"],
          "scope": "in_lecture"
        },
        {
          "sourceSpanId": "span-asymptotic",
          "escalationStep": 2,
          "question": "상수배 차이와 ‘자릿수가 바뀌는’ 차이 중, 점근 표기가 더 신경 쓰는 쪽은?",
          "citations": ["span-asymptotic"],
          "scope": "in_lecture"
        },
        {
          "sourceSpanId": "span-asymptotic",
          "escalationStep": 3,
          "question": "방금 고른 기준을 강의 장면 기준으로만 한 줄로 말해 보세요.",
          "citations": ["span-asymptotic"],
          "scope": "in_lecture"
        }
      ]
    }
    """.trimIndent()
}
