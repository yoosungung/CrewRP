import Foundation

public struct StudyCaptionDraft: Sendable, Equatable {
    public var vtt: String
    public var chapters: [VideoChapter]
    public var markers: [ConceptMarker]

    public init(vtt: String, chapters: [VideoChapter], markers: [ConceptMarker]) {
        self.vtt = vtt
        self.chapters = chapters
        self.markers = markers
    }
}

public struct StudyCaptionClient: Sendable {
    public var transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    /// 재생 URL에서 시청 페이지·자막을 읽어 마커 초안을 만든다. 실패 시 오류 — UI는 VTT 붙여넣기 폴백.
    public func draftFromPlaybackURL(_ playbackUrl: String, windowSec: Int = 180) async throws -> StudyCaptionDraft {
        guard let videoId = youtubeVideoId(from: playbackUrl) else {
            throw StudyBatchError.invalidRange("youtube video id")
        }
        var request = URLRequest(url: URL(string: youtubeWatchURL(videoId: videoId))!)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        let (data, http) = try await transport.data(for: request)
        guard (200...299).contains(http.statusCode), let html = String(data: data, encoding: .utf8) else {
            throw StudyBatchError.invalidRange("watch page http \(http.statusCode)")
        }
        let payload = try parseYouTubeWatchPayload(html)
        guard let captionBase = payload.captionTrackURL else {
            throw StudyBatchError.noSubtitleCues
        }
        var captionReq = URLRequest(url: URL(string: youtubeCaptionRequestURL(captionBase))!)
        captionReq.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (captionData, captionHttp) = try await transport.data(for: captionReq)
        guard (200...299).contains(captionHttp.statusCode),
              let vtt = String(data: captionData, encoding: .utf8),
              !vtt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudyBatchError.noSubtitleCues
        }
        let cues = parseSubtitles(vtt)
        guard !cues.isEmpty else { throw StudyBatchError.noSubtitleCues }
        let markers = draftConceptMarkers(chapters: payload.chapters, cues: cues, windowSec: windowSec)
        guard !markers.isEmpty else { throw StudyBatchError.markersRequired }
        return StudyCaptionDraft(vtt: vtt, chapters: payload.chapters, markers: markers)
    }

    /// VTT 붙여넣기 폴백용.
    public func draftFromVTT(_ vtt: String, chapters: [VideoChapter] = [], windowSec: Int = 180) throws -> StudyCaptionDraft {
        let cues = parseSubtitles(vtt)
        guard !cues.isEmpty else { throw StudyBatchError.noSubtitleCues }
        let markers = draftConceptMarkers(chapters: chapters, cues: cues, windowSec: windowSec)
        guard !markers.isEmpty else { throw StudyBatchError.markersRequired }
        return StudyCaptionDraft(vtt: vtt, chapters: chapters, markers: markers)
    }
}
