package app.crewrp.core

data class StudyCaptionDraft(
    val vtt: String,
    val chapters: List<VideoChapter>,
    val markers: List<ConceptMarker>,
)

class StudyCaptionClient(
    private val transport: HttpTransport,
) {
    /** 재생 URL에서 시청 페이지·자막을 읽어 마커 초안을 만든다. 실패 시 예외 — UI는 VTT 붙여넣기 폴백. */
    fun draftFromPlaybackUrl(playbackUrl: String, windowSec: Int = 180): StudyCaptionDraft {
        val videoId = youtubeVideoId(playbackUrl)
            ?: throw StudyBatchException("youtube video id")
        val headers = mapOf(
            "User-Agent" to
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Referer" to "https://www.youtube.com/",
        )
        val watch = transport.exchange("GET", youtubeWatchUrl(videoId), headers, null)
        require(watch.status in 200..299) { "watch page http ${watch.status}" }
        val payload = parseYouTubeWatchPayload(watch.body)
        val captionBase = payload.captionTrackUrl
            ?: throw StudyBatchException("no subtitle cues")
        val caption = transport.exchange("GET", youtubeCaptionRequestUrl(captionBase), headers, null)
        require(caption.status in 200..299) { "caption http ${caption.status}" }
        val vtt = caption.body.trim()
        if (vtt.isEmpty()) throw StudyBatchException("no subtitle cues")
        val cues = parseSubtitles(vtt)
        if (cues.isEmpty()) throw StudyBatchException("no subtitle cues")
        val markers = draftConceptMarkers(payload.chapters, cues, windowSec)
        if (markers.isEmpty()) throw StudyBatchException("markers required")
        return StudyCaptionDraft(vtt, payload.chapters, markers)
    }

    /** VTT 붙여넣기 폴백용. */
    fun draftFromVtt(
        vtt: String,
        chapters: List<VideoChapter> = emptyList(),
        windowSec: Int = 180,
    ): StudyCaptionDraft = draftStudyFromVtt(vtt, chapters, windowSec)
}

/** VTT 붙여넣기 폴백(네트워크 없음). */
fun draftStudyFromVtt(
    vtt: String,
    chapters: List<VideoChapter> = emptyList(),
    windowSec: Int = 180,
): StudyCaptionDraft {
    val cues = parseSubtitles(vtt)
    if (cues.isEmpty()) throw StudyBatchException("no subtitle cues")
    val markers = draftConceptMarkers(chapters, cues, windowSec)
    if (markers.isEmpty()) throw StudyBatchException("markers required")
    return StudyCaptionDraft(vtt, chapters, markers)
}
