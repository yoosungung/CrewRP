package app.crewrp.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class StudyBatchTest {
    private val courseId = "demo-course"
    private val cues = listOf(
        SubtitleCue(0.0, 10.0, "intro"),
        SubtitleCue(10.0, 40.0, "functions"),
        SubtitleCue(40.0, 60.0, "bugs"),
    )
    private val markers = listOf(
        ConceptMarker("Creating Code", 0, "Creating Code"),
        ConceptMarker("Functions", 10, "Functions"),
        ConceptMarker("Bugs", 40, "Bugs"),
    )

    @Test
    fun parseSubtitlesReadsVttCues() {
        val raw = """
            WEBVTT

            00:00:00.000 --> 00:00:03.000
            Hello

            00:00:03.000 --> 00:00:10.000
            World
        """.trimIndent()
        val parsed = parseSubtitles(raw)
        assertEquals(2, parsed.size)
        assertEquals(0.0, parsed[0].startSec)
        assertEquals(3.0, parsed[0].endSec)
        assertEquals("Hello", parsed[0].text)
        assertEquals("World", parsed[1].text)
    }

    @Test
    fun buildSourceSpansMapsMarkers() {
        val spans = buildSourceSpans(courseId, markers, cues)
        assertEquals(3, spans.size)
        assertEquals("$courseId:span-001", spans[0].id)
        assertEquals(0, spans[0].startSec)
        assertEquals(10, spans[0].endSec)
        assertEquals(10, spans[1].startSec)
        assertEquals(40, spans[1].endSec)
        assertEquals(60, spans[2].endSec)
        assertValidSourceSpans(spans, courseId)
    }

    @Test
    fun buildCourseAssetAddsLinearEdges() {
        val course = CourseRef(courseId, "Demo", "CS", "https://www.youtube.com/embed/x")
        val vtt = """
            WEBVTT

            00:00:00.000 --> 00:01:00.000
            whole lecture
        """.trimIndent()
        val asset = buildCourseAssetFromBatch(course, markers, vtt)
        assertEquals(3, asset.spans.size)
        assertEquals(2, asset.knowledgeEdges.size)
        assertEquals(asset.spans[0].id, asset.knowledgeEdges[0].fromSpanId)
        assertEquals(asset.spans[1].id, asset.knowledgeEdges[0].toSpanId)
        val roundTrip = CourseAsset.parse(asset.toJson())
        assertEquals(asset.course.id, roundTrip.course.id)
        assertEquals(asset.spans.size, roundTrip.spans.size)
    }

    @Test
    fun rejectEmptyMarkers() {
        assertFailsWith<StudyBatchException> {
            buildSourceSpans(courseId, emptyList(), cues)
        }
    }

    @Test
    fun draftConceptMarkersPrefersChapters() {
        val draft = draftConceptMarkers(
            listOf(VideoChapter("Intro", 0), VideoChapter("Peak", 120)),
            listOf(SubtitleCue(0.0, 600.0, "long")),
            windowSec = 180,
        )
        assertEquals(listOf("Intro", "Peak"), draft.map { it.concept })
        assertEquals(listOf(0, 120), draft.map { it.startSec })
    }

    @Test
    fun draftConceptMarkersWindowsCuesWhenNoChapters() {
        val draft = draftConceptMarkers(
            emptyList(),
            listOf(
                SubtitleCue(0.0, 10.0, "hello world here"),
                SubtitleCue(100.0, 110.0, "mid"),
                SubtitleCue(200.0, 210.0, "later part"),
            ),
            windowSec = 180,
        )
        assertEquals(2, draft.size)
        assertEquals(0, draft[0].startSec)
        assertTrue(draft[0].concept.startsWith("hello"))
        assertEquals(200, draft[1].startSec)
    }

    @Test
    fun youtubeVideoIdFromEmbedAndWatch() {
        assertEquals("HtSuA80QTyo", youtubeVideoId("https://www.youtube.com/embed/HtSuA80QTyo"))
        assertEquals("HtSuA80QTyo", youtubeVideoId("https://www.youtube.com/watch?v=HtSuA80QTyo&t=9"))
        assertEquals("HtSuA80QTyo", youtubeVideoId("https://youtu.be/HtSuA80QTyo"))
        assertEquals(null, youtubeVideoId("https://example.com/x"))
    }

    @Test
    fun parseYouTubeWatchPayloadExtractsChaptersAndCaptionUrl() {
        val html = """
            <html><script>var ytInitialPlayerResponse = {"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[{"baseUrl":"https://www.youtube.com/api/timedtext?v=abc","languageCode":"en"}]}},"markersMap":[{"key":"DESCRIPTION_CHAPTERS","value":{"chapters":[{"chapterRenderer":{"title":{"simpleText":"Intro"},"timeRangeStartMillis":0}},{"chapterRenderer":{"title":{"simpleText":"Next"},"timeRangeStartMillis":120000}}]}}]};</script></html>
        """.trimIndent()
        val parsed = parseYouTubeWatchPayload(html)
        assertEquals(listOf("Intro", "Next"), parsed.chapters.map { it.title })
        assertEquals(listOf(0, 120), parsed.chapters.map { it.startSec })
        assertTrue(parsed.captionTrackUrl!!.contains("timedtext"))
    }
}

class StudyCatalogTest {
    @Test
    fun recentStudyDedupesAndCaps() {
        val cache = JdbcCacheStore(":memory:")
        recordRecentStudy(cache, RecentStudyEntry("cs", "a", "A", 1), max = 2)
        recordRecentStudy(cache, RecentStudyEntry("cs", "b", "B", 2), max = 2)
        val recent = recordRecentStudy(cache, RecentStudyEntry("cs", "a", "A2", 3), max = 2)
        assertEquals(listOf("a", "b"), recent.map { it.courseId })
        assertEquals("A2", recent[0].title)
        assertTrue(loadRecentStudy(cache).size <= 2)
    }

    @Test
    fun subjectsRoundTrip() {
        val json = subjectsToJson(listOf(StudySubject("cs", "CS")))
        assertEquals(listOf(StudySubject("cs", "CS")), parseSubjectsJson(json))
    }

    @Test
    fun studyPathsUnderRoot() {
        assertTrue(subjectsPath().startsWith(".crewrp/study"))
        assertEquals(".crewrp/study/cs/courses.json", coursesPath("cs"))
        assertEquals(".crewrp/study/cs/c1/course.json", courseAssetPath("cs", "c1"))
    }
}

class StudyShellTabIndexTest {
    @Test
    fun tabOrderHomeTasksStudyDocsTalk() {
        assertEquals(1, SHELL_TASKS_TAB_INDEX)
        assertEquals(2, SHELL_STUDY_TAB_INDEX)
        assertEquals(3, SHELL_DOCS_TAB_INDEX)
        assertEquals(4, SHELL_TALK_TAB_INDEX)
    }

    @Test
    fun studyEmptyCopyHasNoBundledFallback() {
        assertTrue(STUDY_EMPTY_RECENT_MESSAGE.isNotEmpty())
        assertTrue(STUDY_EMPTY_CATALOG_MESSAGE.isNotEmpty())
        assertTrue(STUDY_EMPTY_HOME_SUBTITLE.isNotEmpty())
        assertTrue(!STUDY_EMPTY_RECENT_MESSAGE.contains("번들"))
        assertTrue(!STUDY_EMPTY_CATALOG_MESSAGE.contains("번들"))
    }
}
