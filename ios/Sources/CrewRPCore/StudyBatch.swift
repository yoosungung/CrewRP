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

private func toSec(_ h: Substring, _ m: Substring, _ s: Substring, _ ms: Substring) -> Double {
    Double(h)! * 3600 + Double(m)! * 60 + Double(s)! + Double(ms)! / 1000
}

private func spanId(courseId: String, index: Int) -> String {
    let n = String(format: "%03d", index + 1)
    return "\(courseId):span-\(n)"
}
