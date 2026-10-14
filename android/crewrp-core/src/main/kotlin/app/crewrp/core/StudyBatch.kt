package app.crewrp.core

import org.json.JSONArray
import org.json.JSONObject

data class ConceptMarker(
    val concept: String,
    val startSec: Int,
    val slideLabel: String = "",
)

data class SubtitleCue(
    val startSec: Double,
    val endSec: Double,
    val text: String,
)

class StudyBatchException(message: String) : Exception(message)

private val TIME =
    Regex("""(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})""")

/** SRT/WebVTT → 시각 큐. 배치 전용(런타임은 SourceSpan JSON). */
fun parseSubtitles(raw: String): List<SubtitleCue> {
    val blocks = raw
        .removePrefix("\uFEFF")
        .split(Regex("""\r?\n\r?\n"""))
        .map { it.trim() }
        .filter { it.isNotEmpty() }
    val cues = mutableListOf<SubtitleCue>()
    for (block in blocks) {
        if (block.startsWith("WEBVTT", ignoreCase = true) ||
            block.startsWith("NOTE", ignoreCase = true) ||
            block.startsWith("STYLE", ignoreCase = true)
        ) {
            continue
        }
        val lines = block.split(Regex("""\r?\n"""))
        val timeLineIdx = lines.indexOfFirst { TIME.containsMatchIn(it) }
        if (timeLineIdx < 0) continue
        val m = TIME.find(lines[timeLineIdx])?.groupValues ?: continue
        val startSec = toSec(m[1], m[2], m[3], m[4])
        val endSec = toSec(m[5], m[6], m[7], m[8])
        val text = lines.drop(timeLineIdx + 1).joinToString(" ").replace(Regex("<[^>]+>"), "").trim()
        if (text.isEmpty()) continue
        cues += SubtitleCue(startSec, endSec, text)
    }
    return cues
}

fun lectureEndSec(cues: List<SubtitleCue>): Double {
    if (cues.isEmpty()) throw StudyBatchException("no subtitle cues")
    return cues.last().endSec
}

/** 개념 마커 + 자막 끝 → 정적 SourceSpan[]. 런타임 인덱싱 없음. */
fun buildSourceSpans(
    courseId: String,
    markers: List<ConceptMarker>,
    cues: List<SubtitleCue>,
): List<SourceSpan> {
    if (markers.isEmpty()) throw StudyBatchException("markers required")
    val sorted = markers.sortedBy { it.startSec }
    for (i in 1 until sorted.size) {
        if (sorted[i].startSec < sorted[i - 1].startSec) {
            throw StudyBatchException("markers must be non-decreasing by startSec")
        }
        if (sorted[i].startSec == sorted[i - 1].startSec) {
            throw StudyBatchException("duplicate marker startSec at ${sorted[i].startSec}")
        }
    }
    val end = lectureEndSec(cues)
    return sorted.mapIndexed { i, marker ->
        val endSec = if (i + 1 < sorted.size) sorted[i + 1].startSec.toDouble() else end
        if (endSec <= marker.startSec) {
            throw StudyBatchException(
                "invalid range for \"${marker.concept}\": ${marker.startSec}..$endSec",
            )
        }
        SourceSpan(
            id = spanId(courseId, i),
            courseId = courseId,
            concept = marker.concept,
            startSec = marker.startSec,
            endSec = endSec.toInt(),
            slideLabel = marker.slideLabel,
        )
    }
}

fun assertValidSourceSpans(spans: List<SourceSpan>, courseId: String) {
    if (spans.isEmpty()) throw StudyBatchException("spans empty")
    var prevEnd = Int.MIN_VALUE
    for (span in spans) {
        if (span.courseId != courseId) {
            throw StudyBatchException("courseId mismatch: ${span.courseId} !== $courseId")
        }
        if (span.id.isBlank() || span.concept.isBlank()) {
            throw StudyBatchException("id and concept required")
        }
        if (span.endSec <= span.startSec) {
            throw StudyBatchException("endSec must be > startSec for ${span.id}")
        }
        if (span.startSec < prevEnd) {
            throw StudyBatchException("order/overlap at ${span.id}")
        }
        prevEnd = span.endSec
    }
}

fun buildCourseAssetFromBatch(
    course: CourseRef,
    markers: List<ConceptMarker>,
    subtitleRaw: String,
): CourseAsset {
    val cues = parseSubtitles(subtitleRaw)
    val spans = buildSourceSpans(course.id, markers, cues)
    assertValidSourceSpans(spans, course.id)
    return CourseAsset(
        course = course,
        spans = spans,
        tutorPrompts = emptyList(),
        knowledgeEdges = StudyPath.linearEdges(spans.map { it.id }),
    )
}

fun parseConceptMarkersJson(json: String): List<ConceptMarker> {
    val arr = JSONArray(json)
    val out = mutableListOf<ConceptMarker>()
    for (i in 0 until arr.length()) {
        val o = arr.getJSONObject(i)
        out += ConceptMarker(
            concept = o.getString("concept"),
            startSec = o.getInt("startSec"),
            slideLabel = o.optString("slideLabel"),
        )
    }
    return out
}

fun conceptMarkersToJson(markers: List<ConceptMarker>): String {
    val arr = JSONArray()
    for (m in markers) {
        val o = JSONObject()
        o.put("concept", m.concept)
        o.put("startSec", m.startSec)
        if (m.slideLabel.isNotBlank()) o.put("slideLabel", m.slideLabel)
        arr.put(o)
    }
    return arr.toString(2)
}

fun CourseAsset.toJson(): String {
    val root = JSONObject()
    root.put(
        "course",
        JSONObject()
            .put("id", course.id)
            .put("title", course.title)
            .put("subject", course.subject)
            .put("playbackUrl", course.playbackUrl),
    )
    val spansArr = JSONArray()
    for (s in spans) {
        spansArr.put(
            JSONObject()
                .put("id", s.id)
                .put("courseId", s.courseId)
                .put("concept", s.concept)
                .put("startSec", s.startSec)
                .put("endSec", s.endSec)
                .put("slideLabel", s.slideLabel),
        )
    }
    root.put("spans", spansArr)
    val edgesArr = JSONArray()
    for (e in knowledgeEdges) {
        edgesArr.put(JSONObject().put("from", e.fromSpanId).put("to", e.toSpanId))
    }
    root.put("knowledgeEdges", edgesArr)
    val promptsArr = JSONArray()
    for (p in tutorPrompts) {
        val cites = JSONArray()
        p.citations.forEach { cites.put(it) }
        val o = JSONObject()
            .put("sourceSpanId", p.sourceSpanId)
            .put("escalationStep", p.escalationStep)
            .put("question", p.question)
            .put("citations", cites)
            .put(
                "scope",
                when (p.scope) {
                    TutorScope.OUT_OF_SCOPE -> "out_of_scope"
                    TutorScope.IN_LECTURE -> "in_lecture"
                },
            )
        if (!p.privateThought.isNullOrBlank()) o.put("privateThought", p.privateThought)
        promptsArr.put(o)
    }
    if (promptsArr.length() > 0) root.put("tutorPrompts", promptsArr)
    return root.toString(2)
}

private fun toSec(h: String, m: String, s: String, ms: String): Double =
    h.toInt() * 3600.0 + m.toInt() * 60.0 + s.toInt() + ms.toInt() / 1000.0

private fun spanId(courseId: String, index: Int): String =
    "$courseId:span-${(index + 1).toString().padStart(3, '0')}"
