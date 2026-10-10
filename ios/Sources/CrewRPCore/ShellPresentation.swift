import Foundation

public enum TaskLane: String, Sendable, Hashable, CaseIterable {
    case inbox
    case doing
    case done

    public var title: String {
        switch self {
        case .inbox: "접수"
        case .doing: "진행 중"
        case .done: "완료"
        }
    }
}

public func taskLane(status: String) -> TaskLane {
    let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if ["완료", "done", "complete", "completed"].contains(normalized) { return .done }
    if normalized.contains("진행") || ["in progress", "doing", "in_progress"].contains(normalized) {
        return .doing
    }
    return .inbox
}

/// compact(폰)는 레인 세로 섹션, 와이드는 다열 칸반.
public func kanbanUsesStackedLanes(compact: Bool) -> Bool { compact }

public func taskStatusChoice(status: String) -> String { taskLane(status: status).title }

/// 상세 납기 입력값. Projects Due는 YYYY-MM-DD.
public func dueOnInput(_ iso: String?) -> String {
    guard let iso, iso.count >= 10 else { return "" }
    return String(iso.prefix(10))
}

/// `YYYY-MM-DD` → 자정 `Date`. 형식이 아니면 nil.
public func parseDueOnDate(_ text: String, calendar: Calendar = .current) -> Date? {
    let t = dueOnInput(text)
    guard t.count == 10 else { return nil }
    let parts = t.split(separator: "-")
    guard parts.count == 3,
          let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
    else { return nil }
    var components = DateComponents()
    components.year = y
    components.month = m
    components.day = d
    return calendar.date(from: components)
}

/// 납기 저장용 `YYYY-MM-DD`.
public func formatDueOnDate(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    guard let y = c.year, let m = c.month, let d = c.day else { return "" }
    return String(format: "%04d-%02d-%02d", y, m, d)
}

/// GitHub Projects v2 날짜 필드 표시 이름 (기본값은 "Due date").
public func isProjectsDueFieldName(_ name: String?) -> Bool {
    guard let name else { return false }
    let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return n == "due" || n == "date" || n == "due date"
}

public extension TeamRole {
    var label: String { self == .admin ? "운영진" : "멤버" }
}

/// ASWebAuthenticationSession 등 로그인 UI 오류 → 사용자 문구. 취소(code 1)는 nil.
public func loginFailureMessage(domain: String, code: Int) -> String? {
    if domain == "com.apple.AuthenticationServices.WebAuthenticationSession", code == 1 {
        return nil
    }
    return "로그인에 실패했습니다. 잠시 후 다시 시도해 주세요."
}

/// completeLogin 등 인증 파이프라인 오류 문구.
public func authFailureMessage(describing error: String) -> String {
    let lower = error.lowercased()
    if lower.contains("missingpending") || lower.contains("statemismatch") {
        return "로그인 세션이 만료되었습니다. 다시 로그인해 주세요."
    }
    if lower.contains("bad_verification") || lower.contains("incorrect_client") {
        return "로그인 코드가 만료되었습니다. 다시 로그인해 주세요."
    }
    // Match HTTP status enums only — not substrings inside OSStatus like -34018.
    if lower.contains("httpstatus(401)") || lower.contains("httpstatus(403)") {
        return "권한이 부족합니다. GitHub에서 앱 권한을 확인한 뒤 다시 로그인해 주세요."
    }
    if lower.contains("loadfailed") || lower.contains("savefailed") || lower.contains("-34018") {
        return "로그인 정보를 저장하지 못했습니다. 앱을 다시 실행한 뒤 로그인해 주세요."
    }
    return "로그인에 실패했습니다. 잠시 후 다시 시도해 주세요."
}

/// 쓰기 API 실패 문구. 스코프 부족이면 재로그인을 안내한다.
public func writeFailureMessage(_ detail: String) -> String {
    let lower = detail.lowercased()
    if lower.contains("scope") || lower.contains("httpstatus(403)") || lower.contains("resource not accessible") {
        return "권한이 부족합니다. 다시 로그인해 주세요."
    }
    if lower.contains("httpstatus(401)") {
        return "로그인이 만료되었습니다. 다시 로그인해 주세요."
    }
    if lower.contains("httpstatus(404)") {
        return "대상이 없습니다. 잠시 후 다시 시도해 주세요."
    }
    if lower.contains("httpstatus(429)") {
        return "요청이 많습니다. 잠시 후 다시 시도해 주세요."
    }
    return "저장하지 못했습니다. 잠시 후 다시 시도해 주세요."
}

/// 운영진은 전부, 멤버는 본인 작성분만 수정·삭제.
public func canMutate(role: TeamRole, authorLogin: String?, currentLogin: String?) -> Bool {
    if role == .admin { return true }
    guard let authorLogin, let currentLogin,
          !authorLogin.isEmpty, !currentLogin.isEmpty else { return false }
    return authorLogin.caseInsensitiveCompare(currentLogin) == .orderedSame
}

public func crewDisplayName(_ repo: String) -> String {
    guard let slash = repo.lastIndex(of: "/") else { return repo }
    let name = repo[repo.index(after: slash)...]
    return name.isEmpty ? repo : String(name)
}

public func crewOwnerName(_ repo: String) -> String {
    guard let slash = repo.firstIndex(of: "/") else { return "" }
    return String(repo[..<slash])
}

public func discordConfigured(serverId: String, channelId: String) -> Bool {
    func ready(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.uppercased().contains("REPLACE")
    }
    return ready(serverId) && ready(channelId)
}

public func formatDue(_ iso: String?) -> String {
    guard let iso, !iso.isEmpty else { return "마감 없음" }
    let parts = iso.split(separator: "-")
    guard parts.count >= 3, let month = Int(parts[1]), let day = Int(parts[2].prefix(2)) else {
        return iso
    }
    return "\(month)월 \(day)일"
}

public struct HomeSections: Equatable, Sendable {
    public let today: [TaskCard]
    public let upcoming: [TaskCard]
    public let notices: [Notice]
}

public func homeSections(tasks: [TaskCard], notices: [Notice], today: String) -> HomeSections {
    let todayTasks = tasks.filter { $0.dueOn?.hasPrefix(today) == true }
    let upcoming = tasks
        .filter { card in
            guard let due = card.dueOn.map({ String($0.prefix(10)) }) else { return false }
            return due > today && taskLane(status: card.status) != .done
        }
        .sorted { ($0.dueOn ?? "9999") < ($1.dueOn ?? "9999") }
        .prefix(3)
    return HomeSections(today: todayTasks, upcoming: Array(upcoming), notices: Array(notices.prefix(3)))
}

public enum DocBlock: Equatable, Sendable {
    case heading(String)
    case bullet(String)
    case paragraph(String)
}

public func docBlocks(_ markdown: String) -> [DocBlock] {
    var blocks: [DocBlock] = []
    var paragraph = ""
    func flush() {
        let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { blocks.append(.paragraph(text)) }
        paragraph = ""
    }
    for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            flush()
        } else if line.hasPrefix("#") {
            flush()
            let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.heading(String(text))) }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            flush()
            blocks.append(.bullet(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
        } else {
            if !paragraph.isEmpty { paragraph.append(" ") }
            paragraph.append(contentsOf: line)
        }
    }
    flush()
    return blocks
}

/// 현재 목록에서 이름·경로 부분 일치(대소문자 무시). 빈 쿼리는 전체. 폴더 우선·이름 정렬.
public func filterDocs(_ entries: [DocEntry], query: String) -> [DocEntry] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered: [DocEntry]
    if q.isEmpty {
        filtered = entries
    } else {
        filtered = entries.filter {
            $0.name.range(of: q, options: .caseInsensitive) != nil
                || $0.path.range(of: q, options: .caseInsensitive) != nil
        }
    }
    return filtered.sorted { a, b in
        if a.isDir != b.isDir { return a.isDir && !b.isDir }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

/// 검색어 없으면 현재 폴더 목록, 있으면 Trees 재귀 인덱스에서 필터.
public func listedDocs(folderEntries: [DocEntry], treeEntries: [DocEntry], query: String) -> [DocEntry] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if q.isEmpty { return filterDocs(folderEntries, query: "") }
    return filterDocs(treeEntries, query: q)
}

public func filterAttachments(_ entries: [AttachmentEntry], query: String) -> [AttachmentEntry] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered: [AttachmentEntry]
    if q.isEmpty {
        filtered = entries
    } else {
        filtered = entries.filter { $0.name.range(of: q, options: .caseInsensitive) != nil }
    }
    return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

/// docs 폴더 항목 + (docs 루트이거나 검색 중일 때) Release 첨부를 합친 자료실 목록.
public func listedLibrary(
    folderEntries: [DocEntry],
    treeEntries: [DocEntry],
    attachments: [AttachmentEntry],
    docsDirPath: String,
    query: String
) -> [DocsLibraryItem] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let docs = listedDocs(folderEntries: folderEntries, treeEntries: treeEntries, query: query)
        .map { DocsLibraryItem.doc($0) }
    let atRoot = docsDirPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "docs"
    let showAttachments = atRoot || !q.isEmpty
    guard showAttachments else { return docs }
    let atts = filterAttachments(attachments, query: query).map { DocsLibraryItem.attachment($0) }
    return docs + atts
}

/// `/docs` 루트면 nil. 그 외 상위 path (Contents API list 대상).
public func parentDocsPath(_ path: String) -> String? {
    var trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard !trimmed.isEmpty, trimmed != "docs" else { return nil }
    guard let slash = trimmed.lastIndex(of: "/") else { return nil }
    let parent = String(trimmed[..<slash])
    return parent.isEmpty ? nil : parent
}
