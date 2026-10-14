import Foundation

public struct ConceptMarker: Sendable, Equatable, Codable {
    public var concept: String
    public var startSec: Int
    public var slideLabel: String

    public init(concept: String, startSec: Int, slideLabel: String = "") {
        self.concept = concept
        self.startSec = startSec
        self.slideLabel = slideLabel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        concept = try c.decode(String.self, forKey: .concept)
        startSec = try c.decode(Int.self, forKey: .startSec)
        slideLabel = try c.decodeIfPresent(String.self, forKey: .slideLabel) ?? ""
    }
}

public struct SubtitleCue: Sendable, Equatable {
    public var startSec: Double
    public var endSec: Double
    public var text: String

    public init(startSec: Double, endSec: Double, text: String) {
        self.startSec = startSec
        self.endSec = endSec
        self.text = text
    }
}

public enum StudyBatchError: Error, Equatable {
    case noSubtitleCues
    case markersRequired
    case markersNotOrdered
    case duplicateMarkerStart
    case invalidRange(String)
    case spansEmpty
    case courseIdMismatch
    case idConceptRequired
    case endBeforeStart(String)
    case overlap(String)
}

/// SRT/WebVTT → 시각 큐. 배치 전용.
public func parseSubtitles(_ raw: String) -> [SubtitleCue] {
    let timePattern =
        #/(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})/#
    let cleaned = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
    let normalized = cleaned
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let blocks = normalized
        .components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    var cues: [SubtitleCue] = []
    for block in blocks {
        if block.uppercased().hasPrefix("WEBVTT") ||
            block.uppercased().hasPrefix("NOTE") ||
            block.uppercased().hasPrefix("STYLE") {
            continue
        }
        let lines = block.components(separatedBy: "\n")
        guard let timeLineIdx = lines.firstIndex(where: { $0.contains("-->") }),
              let match = lines[timeLineIdx].firstMatch(of: timePattern) else {
            continue
        }
        let startSec = toSec(match.1, match.2, match.3, match.4)
        let endSec = toSec(match.5, match.6, match.7, match.8)
        let text = lines[(timeLineIdx + 1)...]
            .joined(separator: " ")
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        cues.append(SubtitleCue(startSec: startSec, endSec: endSec, text: text))
    }
    return cues
}

public func lectureEndSec(_ cues: [SubtitleCue]) throws -> Double {
    guard let last = cues.last else { throw StudyBatchError.noSubtitleCues }
    return last.endSec
}

public func buildSourceSpans(
    courseId: String,
    markers: [ConceptMarker],
    cues: [SubtitleCue]
) throws -> [SourceSpan] {
    guard !markers.isEmpty else { throw StudyBatchError.markersRequired }
    let sorted = markers.sorted { $0.startSec < $1.startSec }
    for i in 1..<sorted.count {
        if sorted[i].startSec < sorted[i - 1].startSec {
            throw StudyBatchError.markersNotOrdered
        }
        if sorted[i].startSec == sorted[i - 1].startSec {
            throw StudyBatchError.duplicateMarkerStart
        }
    }
    let end = try lectureEndSec(cues)
    return try sorted.enumerated().map { i, marker in
        let endSec = i + 1 < sorted.count ? Double(sorted[i + 1].startSec) : end
        guard endSec > Double(marker.startSec) else {
            throw StudyBatchError.invalidRange(marker.concept)
        }
        return SourceSpan(
            id: spanId(courseId: courseId, index: i),
            courseId: courseId,
            concept: marker.concept,
            startSec: marker.startSec,
            endSec: Int(endSec),
            slideLabel: marker.slideLabel
        )
    }
}

public func assertValidSourceSpans(_ spans: [SourceSpan], courseId: String) throws {
    guard !spans.isEmpty else { throw StudyBatchError.spansEmpty }
    var prevEnd = Int.min
    for span in spans {
        guard span.courseId == courseId else { throw StudyBatchError.courseIdMismatch }
        guard !span.id.isEmpty, !span.concept.isEmpty else { throw StudyBatchError.idConceptRequired }
        guard span.endSec > span.startSec else { throw StudyBatchError.endBeforeStart(span.id) }
        guard span.startSec >= prevEnd else { throw StudyBatchError.overlap(span.id) }
        prevEnd = span.endSec
    }
}

public func buildCourseAssetFromBatch(
    course: CourseRef,
    markers: [ConceptMarker],
    subtitleRaw: String
) throws -> CourseAsset {
    let cues = parseSubtitles(subtitleRaw)
    let spans = try buildSourceSpans(courseId: course.id, markers: markers, cues: cues)
    try assertValidSourceSpans(spans, courseId: course.id)
    return CourseAsset(
        course: course,
        spans: spans,
        tutorPrompts: [],
        knowledgeEdges: StudyPath.linearEdges(spanIds: spans.map(\.id))
    )
}

public func parseConceptMarkersJSON(_ json: String) throws -> [ConceptMarker] {
    guard let data = json.data(using: .utf8) else { return [] }
    return try JSONDecoder().decode([ConceptMarker].self, from: data)
}

public func conceptMarkersJSON(_ markers: [ConceptMarker]) throws -> String {
    let data = try JSONEncoder().encode(markers)
    return String(data: data, encoding: .utf8) ?? "[]"
}

extension CourseAsset {
    public func toJSON() throws -> String {
        struct EdgeDTO: Codable {
            var from: String
            var to: String
        }
        struct PromptDTO: Codable {
            var sourceSpanId: String
            var escalationStep: Int
            var question: String
            var citations: [String]
            var privateThought: String?
            var scope: TutorScope
        }
        struct Root: Codable {
            var course: CourseRef
            var spans: [SourceSpan]
            var knowledgeEdges: [EdgeDTO]
            var tutorPrompts: [PromptDTO]?
        }
        let root = Root(
            course: course,
            spans: spans,
            knowledgeEdges: knowledgeEdges.map { EdgeDTO(from: $0.fromSpanId, to: $0.toSpanId) },
            tutorPrompts: tutorPrompts.isEmpty ? nil : tutorPrompts.map {
                PromptDTO(
                    sourceSpanId: $0.sourceSpanId,
                    escalationStep: $0.escalationStep,
                    question: $0.question,
                    citations: $0.citations,
                    privateThought: $0.privateThought,
                    scope: $0.scope
                )
            }
        )
        let data = try JSONEncoder().encode(root)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

public struct VideoChapter: Sendable, Equatable {
    public var title: String
    public var startSec: Int

    public init(title: String, startSec: Int) {
        self.title = title
        self.startSec = startSec
    }
}

public struct YouTubeWatchPayload: Sendable, Equatable {
    public var chapters: [VideoChapter]
    public var captionTrackURL: String?

    public init(chapters: [VideoChapter], captionTrackURL: String?) {
        self.chapters = chapters
        self.captionTrackURL = captionTrackURL
    }
}

/// 챕터가 있으면 그걸 쓰고, 없으면 자막 cue를 `windowSec` 창으로 묶어 초안 마커를 만든다.
public func draftConceptMarkers(
    chapters: [VideoChapter],
    cues: [SubtitleCue],
    windowSec: Int = 180
) -> [ConceptMarker] {
    if !chapters.isEmpty {
        var seen = Set<Int>()
        var out: [ConceptMarker] = []
        for ch in chapters.sorted(by: { $0.startSec < $1.startSec }) {
            guard !seen.contains(ch.startSec) else { continue }
            seen.insert(ch.startSec)
            let name = ch.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            out.append(ConceptMarker(concept: name, startSec: ch.startSec, slideLabel: name))
        }
        return out
    }
    guard !cues.isEmpty else { return [] }
    let window = max(30, windowSec)
    var out: [ConceptMarker] = []
    var bucketStart = Int(cues[0].startSec)
    var bucketLabel = cueLabel(cues[0].text)
    for cue in cues.dropFirst() {
        let sec = Int(cue.startSec)
        if sec - bucketStart >= window {
            out.append(ConceptMarker(concept: bucketLabel, startSec: bucketStart, slideLabel: bucketLabel))
            bucketStart = sec
            bucketLabel = cueLabel(cue.text)
        }
    }
    out.append(ConceptMarker(concept: bucketLabel, startSec: bucketStart, slideLabel: bucketLabel))
    return out
}

public func mergeAdjacentConceptMarkers(_ markers: [ConceptMarker], at index: Int) -> [ConceptMarker] {
    guard index >= 0, index + 1 < markers.count else { return markers }
    var next = markers
    next.remove(at: index + 1)
    return next
}

public func youtubeVideoId(from playbackUrl: String) -> String? {
    guard let url = URL(string: playbackUrl.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    let host = url.host?.lowercased() ?? ""
    if host.contains("youtu.be") {
        let id = url.path.split(separator: "/").first.map(String.init)
        return validYouTubeId(id)
    }
    if host.contains("youtube.com") || host.contains("youtube-nocookie.com") {
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value {
            return validYouTubeId(v)
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if let embed = parts.firstIndex(of: "embed"), embed + 1 < parts.count {
            return validYouTubeId(parts[embed + 1])
        }
        if let shorts = parts.firstIndex(of: "shorts"), shorts + 1 < parts.count {
            return validYouTubeId(parts[shorts + 1])
        }
    }
    return nil
}

public func parseYouTubeWatchPayload(_ html: String) throws -> YouTubeWatchPayload {
    guard let json = extractYtInitialPlayerResponse(html) else {
        throw StudyBatchError.invalidRange("ytInitialPlayerResponse")
    }
    let data = Data(json.utf8)
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    let chapters = parseChapters(from: root)
    let caption = pickCaptionTrackURL(from: root)
    return YouTubeWatchPayload(chapters: chapters, captionTrackURL: caption)
}

public func youtubeWatchURL(videoId: String) -> String {
    "https://www.youtube.com/watch?v=\(videoId)"
}

public func youtubeCaptionRequestURL(_ base: String) -> String {
    if base.contains("fmt=") { return base }
    return base.contains("?") ? "\(base)&fmt=vtt" : "\(base)?fmt=vtt"
}

private func cueLabel(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "구간" }
    if trimmed.count <= 24 { return trimmed }
    let idx = trimmed.index(trimmed.startIndex, offsetBy: 20)
    return String(trimmed[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func validYouTubeId(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let id = raw.split(separator: "?").first.map(String.init) ?? raw
    guard id.range(of: #"^[A-Za-z0-9_-]{6,}\z"#, options: .regularExpression) != nil else { return nil }
    return id
}

private func extractYtInitialPlayerResponse(_ html: String) -> String? {
    let marker = "ytInitialPlayerResponse"
    guard let range = html.range(of: marker) else { return nil }
    var i = html[range.upperBound...].startIndex
    while i < html.endIndex, html[i] != "{" { i = html.index(after: i) }
    guard i < html.endIndex else { return nil }
    var depth = 0
    var inString = false
    var escape = false
    var j = i
    while j < html.endIndex {
        let c = html[j]
        if inString {
            if escape { escape = false }
            else if c == "\\" { escape = true }
            else if c == "\"" { inString = false }
        } else {
            if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 {
                    return String(html[i...j])
                }
            }
        }
        j = html.index(after: j)
    }
    return nil
}

private func parseChapters(from root: [String: Any]) -> [VideoChapter] {
    guard let map = root["markersMap"] as? [[String: Any]] else { return [] }
    for entry in map {
        let key = entry["key"] as? String ?? ""
        guard key.contains("CHAPTER") else { continue }
        let value = entry["value"] as? [String: Any] ?? [:]
        let chapters = value["chapters"] as? [[String: Any]] ?? []
        var out: [VideoChapter] = []
        for ch in chapters {
            let renderer = ch["chapterRenderer"] as? [String: Any] ?? ch
            let titleObj = renderer["title"] as? [String: Any]
            let title = (titleObj?["simpleText"] as? String)
                ?? ((titleObj?["runs"] as? [[String: Any]])?.first?["text"] as? String)
                ?? ""
            let ms = renderer["timeRangeStartMillis"] as? Int
                ?? (renderer["timeRangeStartMillis"] as? Double).map { Int($0) }
                ?? 0
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                out.append(VideoChapter(title: name, startSec: ms / 1000))
            }
        }
        if !out.isEmpty { return out }
    }
    return []
}

private func pickCaptionTrackURL(from root: [String: Any]) -> String? {
    let captions = root["captions"] as? [String: Any]
    let list = captions?["playerCaptionsTracklistRenderer"] as? [String: Any]
    let tracks = list?["captionTracks"] as? [[String: Any]] ?? []
    guard !tracks.isEmpty else { return nil }
    let preferred = ["ko", "en", "en-US", "en-GB"]
    for lang in preferred {
        if let hit = tracks.first(where: { ($0["languageCode"] as? String)?.lowercased() == lang.lowercased() }),
           let url = hit["baseUrl"] as? String, !url.isEmpty {
            return url
        }
    }
    return tracks.first?["baseUrl"] as? String
}

private func toSec(_ h: Substring, _ m: Substring, _ s: Substring, _ ms: Substring) -> Double {
    Double(h)! * 3600 + Double(m)! * 60 + Double(s)! + Double(ms)! / 1000
}

private func spanId(courseId: String, index: Int) -> String {
    let n = String(format: "%03d", index + 1)
    return "\(courseId):span-\(n)"
}
