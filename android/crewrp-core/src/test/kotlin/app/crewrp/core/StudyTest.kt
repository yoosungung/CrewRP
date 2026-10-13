package app.crewrp.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StudyCourseAssetTest {
    @Test
    fun bundledCsCourseLoadsIdPlaybackUrlAndSpans() {
        val asset = CourseAsset.loadBundled()
        assertEquals("cs-algo-intro-01", asset.course.id)
        assertEquals("CS", asset.course.subject)
        assertTrue(asset.course.playbackUrl.contains("youtube.com/embed/"))
        assertTrue(asset.spans.isNotEmpty())
        assertTrue(asset.spans.all { it.courseId == asset.course.id })
        assertTrue(asset.spans.first().startSec >= 0)
    }

    @Test
    fun parseRejectsEmptyCourseId() {
        assertFailsWith<CourseAssetException> {
            CourseAsset.parse(
                """{"course":{"id":"","title":"t","subject":"CS","playbackUrl":"https://x"},"spans":[]}""",
            )
        }
    }
}

class StudyPlaybackUrlTest {
    @Test
    fun appendsStartSecondsForCitationJump() {
        val base = "https://www.youtube.com/embed/HtSuA80QTyo"
        assertEquals(
            "https://www.youtube.com/embed/HtSuA80QTyo?start=90",
            embedPlaybackUrl(base, 90),
        )
        assertEquals(
            "https://www.youtube.com/embed/HtSuA80QTyo?rel=0&start=12",
            embedPlaybackUrl("$base?rel=0", 12),
        )
        assertEquals(base, embedPlaybackUrl(base, null))
        assertEquals(base, embedPlaybackUrl(base, 0))
    }

    @Test
    fun embedRefererIdentifiesAppForYouTubeWebView() {
        assertEquals("https://app.crewrp", YOUTUBE_EMBED_REFERER)
        val headers = youtubeEmbedRequestHeaders()
        assertEquals(YOUTUBE_EMBED_REFERER, headers["Referer"])
        assertEquals("strict-origin-when-cross-origin", headers["Referrer-Policy"])
    }

    @Test
    fun embedHtmlIncludesEscapedPlaybackUrlAndReferrerPolicy() {
        val html = youtubeEmbedHtml("https://www.youtube.com/embed/HtSuA80QTyo?start=90")
        assertTrue(html.contains("HtSuA80QTyo"))
        assertTrue(html.contains("start=90"))
        assertTrue(html.contains("enablejsapi=1"))
        assertTrue(html.contains("origin=https://app.crewrp"))
        assertTrue(html.contains("referrerpolicy=\"strict-origin-when-cross-origin\""))
        assertTrue(html.contains("crewrpUnmute"))
        assertTrue(html.contains("<iframe"))
    }

    @Test
    fun embedPlayerUrlAddsJsApiAndOrigin() {
        val url = youtubeEmbedPlayerUrl("https://www.youtube.com/embed/HtSuA80QTyo?start=12")
        assertTrue(url.contains("enablejsapi=1"))
        assertTrue(url.contains("origin=https://app.crewrp"))
        assertTrue(url.contains("start=12"))
    }
}

class StudySplitRatioTest {
    @Test
    fun weightsMatchProductSnaps() {
        assertEquals(7, StudySplitRatio.MEDIA_HEAVY.mediaWeight)
        assertEquals(3, StudySplitRatio.MEDIA_HEAVY.tutorWeight)
        assertEquals(5, StudySplitRatio.BALANCED.mediaWeight)
        assertEquals(3, StudySplitRatio.TUTOR_HEAVY.mediaWeight)
    }

    @Test
    fun portraitStacksVertically() {
        assertTrue(studyCanvasStacksVertically(390.0, 844.0))
        assertFalse(studyCanvasStacksVertically(844.0, 390.0))
    }

    @Test
    fun snapsContinuousFractionToNearestRatio() {
        assertEquals(StudySplitRatio.MEDIA_HEAVY, StudySplitRatio.snap(0.75))
        assertEquals(StudySplitRatio.BALANCED, StudySplitRatio.snap(0.5))
        assertEquals(StudySplitRatio.TUTOR_HEAVY, StudySplitRatio.snap(0.25))
    }
}

class TutorTurnContractTest {
    @Test
    fun acceptsOneGuidingQuestionWithCitations() {
        val asset = CourseAsset.loadBundled()
        val turn = BundledTutorClient(asset).turn(asset.spans[0].id, 1)
        assertTrue(TutorContract.isValid(turn))
        assertTrue(turn.question.isNotEmpty())
        assertEquals(1, turn.escalationStep)
        assertTrue(turn.citations.isNotEmpty())
        assertEquals(TutorScope.IN_LECTURE, turn.scope)
    }

    @Test
    fun rejectsAnswerDumpInQuestion() {
        val bad = TutorTurn(
            id = "t1",
            sourceSpanId = "s1",
            question = "정답은 42입니다. 풀이: n log n",
            escalationStep = 1,
            citations = listOf("s1"),
            scope = TutorScope.IN_LECTURE,
        )
        assertFalse(TutorContract.isValid(bad))
    }

    @Test
    fun outOfScopeClearsCitations() {
        val turn = TutorTurn(
            id = "t2",
            sourceSpanId = "s1",
            question = "이 강의 범위 밖입니다. 관련 장면으로 돌아가 보세요.",
            escalationStep = 1,
            citations = emptyList(),
            scope = TutorScope.OUT_OF_SCOPE,
        )
        assertTrue(TutorContract.isValid(turn))
        val withCite = turn.copy(citations = listOf("s1"))
        assertFalse(TutorContract.isValid(withCite))
    }

    @Test
    fun bundledTutorNeverReturnsSolutionDump() {
        val asset = CourseAsset.loadBundled()
        for (span in asset.spans) {
            for (step in 1..3) {
                assertTrue(TutorContract.isValid(BundledTutorClient(asset).turn(span.id, step)))
            }
        }
    }
}

class StudyCitationTest {
    @Test
    fun citationSelectedResolvesStartSec() {
        val asset = CourseAsset.loadBundled()
        val span = asset.spans[0]
        assertEquals(span.startSec, asset.startSecForCitation(span.id))
        assertNull(asset.startSecForCitation("missing"))
        assertNotNull(asset.span(span.id))
    }
}
