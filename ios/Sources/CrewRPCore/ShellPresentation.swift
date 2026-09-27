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

public extension TeamRole {
    var label: String { self == .admin ? "운영진" : "멤버" }
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
