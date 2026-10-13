import Foundation

public struct CourseRef: Sendable, Equatable, Codable {
    public var id: String
    public var title: String
    public var subject: String
    public var playbackUrl: String

    public init(id: String, title: String, subject: String, playbackUrl: String) {
        self.id = id
        self.title = title
        self.subject = subject
        self.playbackUrl = playbackUrl
    }
}

public struct SourceSpan: Sendable, Equatable, Codable {
    public var id: String
    public var courseId: String
    public var concept: String
    public var startSec: Int
    public var endSec: Int
    public var slideLabel: String

    public init(id: String, courseId: String, concept: String, startSec: Int, endSec: Int, slideLabel: String = "") {
        self.id = id
        self.courseId = courseId
        self.concept = concept
        self.startSec = startSec
        self.endSec = endSec
        self.slideLabel = slideLabel
    }
}

public enum PathPlacement: String, Sendable, Equatable, Codable {
    case planned
    case skipped
    case current
    case detour
}

public struct PathItem: Sendable, Equatable, Codable {
    public var sourceSpanId: String
    public var placement: PathPlacement
    public var returnToSpanId: String?

    public init(sourceSpanId: String, placement: PathPlacement, returnToSpanId: String? = nil) {
        self.sourceSpanId = sourceSpanId
        self.placement = placement
        self.returnToSpanId = returnToSpanId
    }
}

public enum TutorScope: String, Sendable, Equatable, Codable {
    case inLecture = "in_lecture"
    case outOfScope = "out_of_scope"
}

public enum FormulaVerdict: String, Sendable, Equatable, Codable {
    case correct
    case incorrect
}

public struct TutorTurn: Sendable, Equatable, Codable {
    public var id: String
    public var sourceSpanId: String
    public var question: String
    public var escalationStep: Int
    public var citations: [String]
    public var scope: TutorScope
    public var formulaVerdict: FormulaVerdict?
    public var privateThought: String?

    public init(
        id: String,
        sourceSpanId: String,
        question: String,
        escalationStep: Int,
        citations: [String],
        scope: TutorScope,
        formulaVerdict: FormulaVerdict? = nil,
        privateThought: String? = nil
    ) {
        self.id = id
        self.sourceSpanId = sourceSpanId
        self.question = question
        self.escalationStep = escalationStep
        self.citations = citations
        self.scope = scope
        self.formulaVerdict = formulaVerdict
        self.privateThought = privateThought
    }
}

public struct ReviewCard: Sendable, Equatable, Codable {
    public var id: String
    public var sourceSpanId: String
    public var summary: String
    public var createdAt: Date
    public var fadesAt: Date

    public init(id: String, sourceSpanId: String, summary: String, createdAt: Date, fadesAt: Date) {
        self.id = id
        self.sourceSpanId = sourceSpanId
        self.summary = summary
        self.createdAt = createdAt
        self.fadesAt = fadesAt
    }
}

public enum StudySplitRatio: String, Sendable, CaseIterable, Equatable {
    case mediaHeavy = "7:3"
    case balanced = "5:5"
    case tutorHeavy = "3:7"

    public var mediaWeight: Int {
        switch self {
        case .mediaHeavy: 7
        case .balanced: 5
        case .tutorHeavy: 3
        }
    }

    public var tutorWeight: Int {
        switch self {
        case .mediaHeavy: 3
        case .balanced: 5
        case .tutorHeavy: 7
        }
    }

    public var mediaFraction: Double {
        Double(mediaWeight) / Double(mediaWeight + tutorWeight)
    }

    public static func snap(mediaFraction: Double) -> StudySplitRatio {
        let candidates = StudySplitRatio.allCases
        return candidates.min(by: { abs($0.mediaFraction - mediaFraction) < abs($1.mediaFraction - mediaFraction) })!
    }
}

public func studyCanvasStacksVertically(width: Double, height: Double) -> Bool {
    height >= width
}

/// YouTube embed URL에 `start` 초를 붙인다. CitationSelected → 재로드용.
public func embedPlaybackURL(_ base: String, startSec: Int?) -> String {
    guard let startSec, startSec > 0 else { return base }
    guard var components = URLComponents(string: base) else { return base }
    var items = components.queryItems ?? []
    items.removeAll { $0.name == "start" }
    items.append(URLQueryItem(name: "start", value: String(startSec)))
    components.queryItems = items
    return components.string ?? base
}

public enum CourseAssetError: Error, Equatable {
    case invalidJSON
    case missingCourse
    case emptyCourseId
    case emptyPlaybackURL
}

private struct CourseAssetDTO: Codable {
    var course: CourseRef
    var spans: [SourceSpan]
    var tutorPrompts: [TutorPromptDTO]?
}

private struct TutorPromptDTO: Codable {
    var sourceSpanId: String
    var escalationStep: Int
    var question: String
    var citations: [String]
    var privateThought: String?
    var scope: TutorScope?
}

public struct CourseAsset: Sendable, Equatable {
    public var course: CourseRef
    public var spans: [SourceSpan]
    public var tutorPrompts: [BundledTutorPrompt]

    public init(course: CourseRef, spans: [SourceSpan], tutorPrompts: [BundledTutorPrompt] = []) {
        self.course = course
        self.spans = spans
        self.tutorPrompts = tutorPrompts
    }

    public func span(id: String) -> SourceSpan? {
        spans.first { $0.id == id }
    }

    public func startSec(forCitation id: String) -> Int? {
        span(id: id)?.startSec
    }

    public static func parse(_ json: String) throws -> CourseAsset {
        guard let data = json.data(using: .utf8) else { throw CourseAssetError.invalidJSON }
        let dto: CourseAssetDTO
        do {
            dto = try JSONDecoder().decode(CourseAssetDTO.self, from: data)
        } catch {
            throw CourseAssetError.invalidJSON
        }
        if dto.course.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CourseAssetError.emptyCourseId
        }
        if dto.course.playbackUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CourseAssetError.emptyPlaybackURL
        }
        let prompts = (dto.tutorPrompts ?? []).map {
            BundledTutorPrompt(
                sourceSpanId: $0.sourceSpanId,
                escalationStep: $0.escalationStep,
                question: $0.question,
                citations: $0.citations,
                privateThought: $0.privateThought,
                scope: $0.scope ?? .inLecture
            )
        }
        return CourseAsset(course: dto.course, spans: dto.spans, tutorPrompts: prompts)
    }

    public static func loadBundled() throws -> CourseAsset {
        try parse(BundledStudyJSON.csAlgoIntro)
    }
}

public struct BundledTutorPrompt: Sendable, Equatable {
    public var sourceSpanId: String
    public var escalationStep: Int
    public var question: String
    public var citations: [String]
    public var privateThought: String?
    public var scope: TutorScope

    public init(
        sourceSpanId: String,
        escalationStep: Int,
        question: String,
        citations: [String],
        privateThought: String? = nil,
        scope: TutorScope = .inLecture
    ) {
        self.sourceSpanId = sourceSpanId
        self.escalationStep = escalationStep
        self.question = question
        self.citations = citations
        self.privateThought = privateThought
        self.scope = scope
    }
}

public enum TutorContract {
    private static let bannedFragments = [
        "정답은", "풀이:", "답:", "the answer is", "solution:", "정답:",
    ]

    public static func isValid(_ turn: TutorTurn) -> Bool {
        let q = turn.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        guard (1...3).contains(turn.escalationStep) else { return false }
        let lower = q.lowercased()
        if bannedFragments.contains(where: { lower.contains($0.lowercased()) }) {
            return false
        }
        switch turn.scope {
        case .outOfScope:
            return turn.citations.isEmpty
        case .inLecture:
            return !turn.citations.isEmpty
        }
    }
}

public struct BundledTutorClient: Sendable {
    public var asset: CourseAsset

    public init(asset: CourseAsset) {
        self.asset = asset
    }

    public func turn(for sourceSpanId: String, escalationStep: Int) throws -> TutorTurn {
        let step = min(3, max(1, escalationStep))
        if let prompt = asset.tutorPrompts.first(where: { $0.sourceSpanId == sourceSpanId && $0.escalationStep == step })
            ?? asset.tutorPrompts.first(where: { $0.sourceSpanId == sourceSpanId }) {
            let turn = TutorTurn(
                id: "bundled-\(sourceSpanId)-\(step)",
                sourceSpanId: sourceSpanId,
                question: prompt.question,
                escalationStep: step,
                citations: prompt.citations,
                scope: prompt.scope,
                formulaVerdict: nil,
                privateThought: prompt.privateThought
            )
            guard TutorContract.isValid(turn) else { throw CourseAssetError.invalidJSON }
            return turn
        }
        return TutorTurn(
            id: "oos-\(sourceSpanId)",
            sourceSpanId: sourceSpanId,
            question: "이 강의에서 짚을 장면이 없습니다. 경로의 다음 장면으로 이동해 보세요.",
            escalationStep: step,
            citations: [],
            scope: .outOfScope,
            formulaVerdict: nil,
            privateThought: nil
        )
    }
}

/// MIT 6.006 L1 (공개 YouTube). 자막·슬라이드 라벨을 배치 1회로 고정한 정적 자산.
enum BundledStudyJSON {
    static let csAlgoIntro = #"""
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
    """#
}
