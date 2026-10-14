import Foundation
import Testing
@testable import CrewRPCore

@Suite("Study course asset")
struct StudyCourseAssetTests {
    @Test("bundled CS course loads id playbackUrl and spans")
    func loadsBundledCourse() throws {
        let asset = try CourseAsset.loadBundled()
        #expect(asset.course.id == "cs-algo-intro-01")
        #expect(asset.course.subject == "CS")
        #expect(asset.course.playbackUrl.contains("youtube.com/embed/"))
        #expect(!asset.spans.isEmpty)
        #expect(asset.spans.allSatisfy { $0.courseId == asset.course.id })
        #expect(asset.spans.first?.startSec ?? -1 >= 0)
    }

    @Test("parse rejects empty course id")
    func parseRejectsBad() {
        #expect(throws: CourseAssetError.self) {
            try CourseAsset.parse(#"{"course":{"id":"","title":"t","subject":"CS","playbackUrl":"https://x"},"spans":[]}"#)
        }
    }
}

@Suite("Study playback URL")
struct StudyPlaybackURLTests {
    @Test("appends start seconds for citation jump")
    func appendsStart() {
        let base = "https://www.youtube.com/embed/HtSuA80QTyo"
        #expect(embedPlaybackURL(base, startSec: 90) == "https://www.youtube.com/embed/HtSuA80QTyo?start=90")
        #expect(embedPlaybackURL(base + "?rel=0", startSec: 12) == "https://www.youtube.com/embed/HtSuA80QTyo?rel=0&start=12")
        #expect(embedPlaybackURL(base, startSec: nil) == base)
        #expect(embedPlaybackURL(base, startSec: 0) == base)
    }

    @Test("embed referer identifies app for YouTube WebView")
    func embedReferer() {
        #expect(youtubeEmbedReferer == "https://app.crewrp")
        let headers = youtubeEmbedRequestHeaders()
        #expect(headers["Referer"] == youtubeEmbedReferer)
        #expect(headers["Referrer-Policy"] == "strict-origin-when-cross-origin")
    }

    @Test("embed HTML includes escaped playback URL and referrer policy")
    func embedHTML() {
        let html = youtubeEmbedHTML(playbackURL: "https://www.youtube.com/embed/HtSuA80QTyo?start=90")
        #expect(html.contains("HtSuA80QTyo"))
        #expect(html.contains("start=90"))
        #expect(html.contains("enablejsapi=1"))
        #expect(html.contains("origin=https://app.crewrp"))
        #expect(html.contains("referrerpolicy=\"strict-origin-when-cross-origin\""))
        #expect(html.contains("crewrpUnmute"))
        #expect(html.contains("<iframe"))
    }

    @Test("embed player URL adds jsapi and origin")
    func embedPlayerURL() {
        let url = youtubeEmbedPlayerURL("https://www.youtube.com/embed/HtSuA80QTyo?start=12")
        #expect(url.contains("enablejsapi=1"))
        #expect(url.contains("origin=https://app.crewrp"))
        #expect(url.contains("start=12"))
    }
}

@Suite("Study split ratio")
struct StudySplitRatioTests {
    @Test("weights match product snaps")
    func weights() {
        #expect(StudySplitRatio.mediaHeavy.mediaWeight == 7)
        #expect(StudySplitRatio.mediaHeavy.tutorWeight == 3)
        #expect(StudySplitRatio.balanced.mediaWeight == 5)
        #expect(StudySplitRatio.tutorHeavy.mediaWeight == 3)
    }

    @Test("portrait stacks vertically")
    func orientation() {
        #expect(studyCanvasStacksVertically(width: 390, height: 844))
        #expect(!studyCanvasStacksVertically(width: 844, height: 390))
    }

    @Test("snaps continuous fraction to nearest ratio")
    func snap() {
        #expect(StudySplitRatio.snap(mediaFraction: 0.75) == .mediaHeavy)
        #expect(StudySplitRatio.snap(mediaFraction: 0.5) == .balanced)
        #expect(StudySplitRatio.snap(mediaFraction: 0.25) == .tutorHeavy)
    }
}

@Suite("TutorTurn contract")
struct TutorTurnContractTests {
    @Test("accepts one guiding question with citations")
    func acceptsValid() throws {
        let asset = try CourseAsset.loadBundled()
        let turn = try BundledTutorClient(asset: asset).turn(for: asset.spans[0].id, escalationStep: 1)
        #expect(TutorContract.isValid(turn))
        #expect(!turn.question.isEmpty)
        #expect(turn.escalationStep == 1)
        #expect(!turn.citations.isEmpty)
        #expect(turn.scope == .inLecture)
    }

    @Test("rejects answer dump in question")
    func rejectsAnswerDump() {
        let bad = TutorTurn(
            id: "t1",
            sourceSpanId: "s1",
            question: "정답은 42입니다. 풀이: n log n",
            escalationStep: 1,
            citations: ["s1"],
            scope: .inLecture,
            formulaVerdict: nil
        )
        #expect(!TutorContract.isValid(bad))
    }

    @Test("out_of_scope clears citations")
    func outOfScope() {
        let turn = TutorTurn(
            id: "t2",
            sourceSpanId: "s1",
            question: "이 강의 범위 밖입니다. 관련 장면으로 돌아가 보세요.",
            escalationStep: 1,
            citations: [],
            scope: .outOfScope,
            formulaVerdict: nil
        )
        #expect(TutorContract.isValid(turn))
        let withCite = TutorTurn(
            id: "t3",
            sourceSpanId: "s1",
            question: "범위 밖",
            escalationStep: 1,
            citations: ["s1"],
            scope: .outOfScope,
            formulaVerdict: nil
        )
        #expect(!TutorContract.isValid(withCite))
    }

    @Test("bundled tutor never returns solution dump")
    func bundledIsSafe() throws {
        let asset = try CourseAsset.loadBundled()
        for span in asset.spans {
            for step in 1...3 {
                let turn = try BundledTutorClient(asset: asset).turn(for: span.id, escalationStep: step)
                #expect(TutorContract.isValid(turn))
            }
        }
    }
}

@Suite("Study citation event")
struct StudyCitationTests {
    @Test("CitationSelected resolves startSec")
    func resolvesStart() throws {
        let asset = try CourseAsset.loadBundled()
        let span = asset.spans[0]
        let start = asset.startSec(forCitation: span.id)
        #expect(start == span.startSec)
        #expect(asset.startSec(forCitation: "missing") == nil)
    }
}

@Suite("Study batch")
struct StudyBatchTests {
    @Test("parseSubtitles reads VTT cues")
    func parseVtt() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:03.000
        Hello

        00:00:03.000 --> 00:00:10.000
        World
        """
        let cues = parseSubtitles(raw)
        #expect(cues.count == 2)
        #expect(cues[0].text == "Hello")
        #expect(cues[1].endSec == 10)
    }

    @Test("buildSourceSpans maps markers")
    func buildSpans() throws {
        let cues = [
            SubtitleCue(startSec: 0, endSec: 10, text: "a"),
            SubtitleCue(startSec: 10, endSec: 60, text: "b"),
        ]
        let markers = [
            ConceptMarker(concept: "A", startSec: 0, slideLabel: "A"),
            ConceptMarker(concept: "B", startSec: 10, slideLabel: "B"),
        ]
        let spans = try buildSourceSpans(courseId: "demo", markers: markers, cues: cues)
        #expect(spans.count == 2)
        #expect(spans[0].id == "demo:span-001")
        #expect(spans[1].endSec == 60)
        try assertValidSourceSpans(spans, courseId: "demo")
    }

    @Test("draftConceptMarkers prefers chapters")
    func draftFromChapters() {
        let cues = [SubtitleCue(startSec: 0, endSec: 600, text: "long")]
        let chapters = [
            VideoChapter(title: "Intro", startSec: 0),
            VideoChapter(title: "Peak", startSec: 120),
        ]
        let draft = draftConceptMarkers(chapters: chapters, cues: cues, windowSec: 180)
        #expect(draft.map(\.concept) == ["Intro", "Peak"])
        #expect(draft.map(\.startSec) == [0, 120])
    }

    @Test("draftConceptMarkers windows cues when no chapters")
    func draftFromCues() {
        let cues = [
            SubtitleCue(startSec: 0, endSec: 10, text: "hello world here"),
            SubtitleCue(startSec: 100, endSec: 110, text: "mid"),
            SubtitleCue(startSec: 200, endSec: 210, text: "later part"),
        ]
        let draft = draftConceptMarkers(chapters: [], cues: cues, windowSec: 180)
        #expect(draft.count == 2)
        #expect(draft[0].startSec == 0)
        #expect(draft[0].concept.hasPrefix("hello"))
        #expect(draft[1].startSec == 200)
    }

    @Test("youtubeVideoId from embed and watch urls")
    func youtubeId() {
        #expect(youtubeVideoId(from: "https://www.youtube.com/embed/HtSuA80QTyo") == "HtSuA80QTyo")
        #expect(youtubeVideoId(from: "https://www.youtube.com/watch?v=HtSuA80QTyo&t=9") == "HtSuA80QTyo")
        #expect(youtubeVideoId(from: "https://youtu.be/HtSuA80QTyo") == "HtSuA80QTyo")
        #expect(youtubeVideoId(from: "https://example.com/x") == nil)
    }

    @Test("parseYouTubeWatchPayload extracts chapters and caption url")
    func parseWatchPayload() throws {
        let html = """
        <html><script>var ytInitialPlayerResponse = {"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[{"baseUrl":"https://www.youtube.com/api/timedtext?v=abc","languageCode":"en"}]}},"markersMap":[{"key":"DESCRIPTION_CHAPTERS","value":{"chapters":[{"chapterRenderer":{"title":{"simpleText":"Intro"},"timeRangeStartMillis":0}},{"chapterRenderer":{"title":{"simpleText":"Next"},"timeRangeStartMillis":120000}}]}}]};</script></html>
        """
        let parsed = try parseYouTubeWatchPayload(html)
        #expect(parsed.chapters.map(\.title) == ["Intro", "Next"])
        #expect(parsed.chapters.map(\.startSec) == [0, 120])
        #expect(parsed.captionTrackURL?.contains("timedtext") == true)
    }
}

@Suite("Study catalog")
struct StudyCatalogTests {
    @Test("recent study dedupes")
    func recent() throws {
        let cache = try CacheStore(path: ":memory:")
        _ = try recordRecentStudy(
            cache: cache,
            entry: RecentStudyEntry(subjectId: "cs", courseId: "a", title: "A", openedAtEpochSec: 1),
            max: 2
        )
        let recent = try recordRecentStudy(
            cache: cache,
            entry: RecentStudyEntry(subjectId: "cs", courseId: "a", title: "A2", openedAtEpochSec: 2),
            max: 2
        )
        #expect(recent.map(\.courseId) == ["a"])
        #expect(recent[0].title == "A2")
    }

    @Test("tab indices include study")
    func tabs() {
        #expect(shellTasksTabIndex == 1)
        #expect(shellStudyTabIndex == 2)
        #expect(shellDocsTabIndex == 3)
        #expect(shellTalkTabIndex == 4)
    }

    @Test("study empty copy has no bundled fallback")
    func emptyCopy() {
        #expect(!studyEmptyRecentMessage.isEmpty)
        #expect(!studyEmptyCatalogMessage.isEmpty)
        #expect(!studyEmptyHomeSubtitle.isEmpty)
        #expect(!studyEmptyRecentMessage.contains("번들"))
        #expect(!studyEmptyCatalogMessage.contains("번들"))
    }
}

@Suite("Study path")
struct StudyPathTests {
    @Test("bundled course has static knowledge DAG")
    func bundledDag() throws {
        let asset = try CourseAsset.loadBundled()
        #expect(!asset.knowledgeEdges.isEmpty)
        #expect(asset.knowledgeEdges.contains {
            $0.fromSpanId == "span-what-is-algo" && $0.toSpanId == "span-peak-finding"
        })
    }

    @Test("advisor onboarding skips known concepts and sets current")
    func onboardingSkips() throws {
        let asset = try CourseAsset.loadBundled()
        let path = StudyPath.build(
            spanIds: asset.spans.map(\.id),
            knownSpanIds: ["span-what-is-algo"]
        )
        #expect(path.items[0].placement == .skipped)
        #expect(path.items[1].placement == .current)
        #expect(path.items[2].placement == .planned)
        #expect(path.activeSpanId() == "span-peak-finding")
    }

    @Test("DetourInserted uses prerequisite and returns")
    func detourRoundTrip() throws {
        let asset = try CourseAsset.loadBundled()
        var path = StudyPath.build(
            spanIds: asset.spans.map(\.id),
            knownSpanIds: ["span-what-is-algo"]
        )
        path = path.insertDetour(edges: asset.knowledgeEdges, stuckSpanId: "span-peak-finding")
        let detour = try #require(path.items.first { $0.placement == .detour })
        #expect(detour.sourceSpanId == "span-what-is-algo")
        #expect(detour.returnToSpanId == "span-peak-finding")
        #expect(path.activeSpanId() == "span-what-is-algo")

        path = path.completeDetour()
        #expect(path.items.allSatisfy { $0.placement != .detour })
        #expect(path.activeSpanId() == "span-peak-finding")
        #expect(path.items.first { $0.sourceSpanId == "span-peak-finding" }?.placement == .current)
    }

    @Test("insertDetour no-op without prerequisite")
    func detourNoOp() {
        let path = StudyPath.build(spanIds: ["a", "b"], knownSpanIds: [])
        let same = path.insertDetour(edges: [], stuckSpanId: "a")
        #expect(same.items == path.items)
    }
}
