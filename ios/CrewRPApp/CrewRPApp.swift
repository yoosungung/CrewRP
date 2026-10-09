import SwiftUI
import UIKit
import CrewRPCore
import os

@main
struct CrewRPApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var registrableRepos: [CrewRepo] = []
    @Published var session: Session?
    @Published var errorMessage: String?
    @Published var selectedTab = 0
    @Published var tasks: [TaskCard] = []
    @Published var notices: [Notice] = []
    @Published var docPreview: String = ""
    @Published var docPath: String = "docs/README.md"
    @Published var docSha: String?
    @Published var docs: [DocEntry] = []
    @Published var docsDirPath: String = "docs"
    @Published var threadMessages: [ThreadMessage] = []
    @Published var isLoading = false
    @Published var tasksFailed = false
    @Published var noticesFailed = false
    @Published var docFailed = false
    @Published var threadsFailed = false
    @Published var writeError: String?
    @Published var currentLogin: String?
    @Published var projectMeta: ProjectFieldMeta?
    @Published var discussionSetup: DiscussionSetup?
    @Published var talkIssueNumber: Int = 1
    private var didRegisterPush = false

    private let flow: AuthFlow
    private let cache: CacheStore
    private let tokens: KeychainTokenStore
    private let transport = URLSessionTransport()
    private let log = Logger(subsystem: "app.crewrp", category: "auth")

    private var projectNumber: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "ProjectNumber") as? String ?? "1") ?? 1
    }

    private var repoParts: (owner: String, repo: String)? {
        guard let session else { return nil }
        let parts = session.repo.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    init() {
        let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "crewrp.sqlite")
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = AuthConfig(
            clientID: Bundle.main.object(forInfoDictionaryKey: "GitHubClientID") as? String ?? "REPLACE_ME",
            redirectURI: "crewrp://oauth/callback",
            authBridgeBaseURL: URL(string: Bundle.main.object(forInfoDictionaryKey: "AuthBridgeURL") as? String ?? "https://auth.example")!
        )
        cache = try! CacheStore(path: cacheURL.path)
        tokens = KeychainTokenStore()
        flow = AuthFlow(
            config: config,
            bridge: AuthBridgeClient(baseURL: config.authBridgeBaseURL, transport: transport),
            membership: GitHubMembershipClient(transport: transport),
            tokens: tokens,
            cache: cache,
            pendingStore: UserDefaultsPendingLoginStore()
        )
        session = try? cache.session()
    }

    func login() {
        errorMessage = nil
        let challenge = flow.beginLogin()
        // External Safari (same as Android): ASWebAuthenticationSession was dropping the
        // post-token repo list call after OAuth return on recent simulators.
        UIApplication.shared.open(challenge.authorizeURL)
    }

    func handleOAuthCallback(_ url: URL) {
        guard url.scheme == "crewrp" else { return }
        Task {
            do {
                registrableRepos = try await flow.completeLogin(callbackURL: url)
                errorMessage = registrableRepos.isEmpty
                    ? "운영 권한이 있는 보관소가 없습니다."
                    : nil
            } catch {
                log.error("completeLogin failed: \(String(describing: error), privacy: .public)")
                errorMessage = authFailureMessage(describing: String(describing: error))
            }
        }
    }

    func register(_ repo: CrewRepo) {
        Task {
            do {
                session = try await flow.registerCrew(repo)
                errorMessage = nil
                await refreshHomeData()
            } catch {
                errorMessage = "크루를 시작하지 못했습니다. 잠시 후 다시 시도해 주세요."
            }
        }
    }

    func logout() {
        try? flow.logout()
        session = nil
        registrableRepos = []
        errorMessage = nil
        writeError = nil
        tasks = []
        notices = []
        docs = []
        docsDirPath = "docs"
        threadMessages = []
        currentLogin = nil
        projectMeta = nil
        discussionSetup = nil
        docPreview = ""
        docSha = nil
        selectedTab = 0
        didRegisterPush = false
    }

    func refreshHomeData(forceNetwork: Bool = false) async {
        guard let session, let token = try? tokens.loadAccessToken(), let parts = repoParts else { return }
        let owner = parts.owner
        let repo = parts.repo
        let org = session.org
        let preferredProject = projectNumber
        let listPath = docsDirPath
        let transport = self.transport
        let cache = self.cache
        isLoading = true
        defer { isLoading = false }

        // Network + JSON decode off the main actor so UI scroll stays responsive (A).
        // Sections run in parallel to cut the REST/GraphQL waterfall (B).
        struct Snapshot: Sendable {
            var login: String?
            var tasks: [TaskCard] = []
            var tasksFailed = false
            var projectMeta: ProjectFieldMeta?
            var notices: [Notice] = []
            var noticesFailed = false
            var discussionSetup: DiscussionSetup?
            var docs: [DocEntry] = []
            var docsDirPath: String
            var docFailed = false
            var talkIssueNumber = 1
            var threadMessages: [ThreadMessage] = []
            var threadsFailed = false
        }

        let snapshot = await Task.detached(priority: .userInitiated) { () -> Snapshot in
            async let loginTask = try? await GitHubMembershipClient(transport: transport).currentUser(token: token).login

            async let tasksTask: (cards: [TaskCard], failed: Bool, meta: ProjectFieldMeta?) = {
                do {
                    let projects = ProjectsClient(transport: transport)
                    let queryName = GraphQLFreshness.listTasksQueryName(org: org, projectNumber: preferredProject)
                    let number: Int
                    if !forceNetwork, GraphQLFreshness.freshBody(cache: cache, queryName: queryName) != nil {
                        number = preferredProject
                    } else {
                        number = (try? await projects.resolveProjectNumber(
                            owner: org, preferred: preferredProject, token: token
                        )) ?? preferredProject
                    }
                    let cards = try await projects.sortedByDueDate(
                        projects.listTasks(
                            org: org,
                            projectNumber: number,
                            token: token,
                            cache: cache,
                            forceNetwork: forceNetwork
                        )
                    )
                    let meta = try? await projects.loadFieldMeta(owner: org, projectNumber: number, token: token)
                    return (cards, false, meta)
                } catch {
                    return ([], true, nil)
                }
            }()

            async let noticesTask: (items: [Notice], failed: Bool, setup: DiscussionSetup?) = {
                do {
                    let discussions = DiscussionsClient(transport: transport)
                    let items = try await discussions.listNotices(
                        owner: owner,
                        repo: repo,
                        token: token,
                        cache: cache,
                        forceNetwork: forceNetwork
                    )
                    let setup = try? await discussions.resolveSetup(owner: owner, repo: repo, token: token)
                    return (items, false, setup)
                } catch {
                    return ([], true, nil)
                }
            }()

            async let docsTask: (entries: [DocEntry], dir: String, failed: Bool) = {
                let docsClient = DocsClient(transport: transport, cache: cache)
                do {
                    let entries = try await docsClient.listDocs(owner: owner, repo: repo, token: token, path: listPath)
                    return (entries, listPath, false)
                } catch {
                    if case GitHubAPIError.httpStatus(404) = error {
                        return ([], listPath, false)
                    }
                    return ([], listPath, true)
                }
            }()

            async let talkTask: (issue: Int, messages: [ThreadMessage], failed: Bool) = {
                do {
                    let talk = ThreadTalkClient(transport: transport)
                    let issue = try await talk.ensureTalkIssueNumber(owner: owner, repo: repo, token: token)
                    let messages = try await talk.listIssueComments(
                        owner: owner, repo: repo, issueNumber: issue, token: token
                    )
                    return (issue, messages, false)
                } catch {
                    return (1, [], true)
                }
            }()

            let tasks = await tasksTask
            let notices = await noticesTask
            let docs = await docsTask
            let talk = await talkTask
            return Snapshot(
                login: await loginTask,
                tasks: tasks.cards,
                tasksFailed: tasks.failed,
                projectMeta: tasks.meta,
                notices: notices.items,
                noticesFailed: notices.failed,
                discussionSetup: notices.setup,
                docs: docs.entries,
                docsDirPath: docs.dir,
                docFailed: docs.failed,
                talkIssueNumber: talk.issue,
                threadMessages: talk.messages,
                threadsFailed: talk.failed
            )
        }.value

        currentLogin = snapshot.login
        if !snapshot.tasksFailed || tasks.isEmpty {
            tasks = snapshot.tasks
        }
        tasksFailed = snapshot.tasksFailed
        if let meta = snapshot.projectMeta { projectMeta = meta }
        if !snapshot.noticesFailed || notices.isEmpty {
            notices = snapshot.notices
        }
        noticesFailed = snapshot.noticesFailed
        if let setup = snapshot.discussionSetup { discussionSetup = setup }
        if !snapshot.docFailed || docs.isEmpty {
            docs = snapshot.docs
            docsDirPath = snapshot.docsDirPath
        }
        docFailed = snapshot.docFailed
        if !snapshot.threadsFailed || threadMessages.isEmpty {
            talkIssueNumber = snapshot.talkIssueNumber
            threadMessages = snapshot.threadMessages
        }
        threadsFailed = snapshot.threadsFailed

        if !didRegisterPush {
            didRegisterPush = true
            await registerPushDevice()
        }
    }

    private func withToken(_ work: (String, String, String) async throws -> Void) async {
        guard let token = try? tokens.loadAccessToken(), let parts = repoParts else {
            writeError = "로그인이 만료되었습니다. 다시 로그인해 주세요."
            return
        }
        do {
            try await work(token, parts.owner, parts.repo)
            writeError = nil
            await refreshHomeData(forceNetwork: true)
        } catch {
            log.error("write failed: \(String(describing: error), privacy: .public)")
            writeError = writeFailureMessage(String(describing: error))
        }
    }

    func createNotice(title: String, body: String) async {
        guard let setup = discussionSetup else { return }
        await withToken { token, _, _ in
            _ = try await DiscussionsClient(transport: transport)
                .createNotice(repositoryId: setup.repositoryId, categoryId: setup.categoryId, title: title, body: body, token: token)
        }
    }

    func updateNotice(_ notice: Notice, title: String, body: String) async {
        await withToken { token, _, _ in
            _ = try await DiscussionsClient(transport: transport).updateNotice(id: notice.id, title: title, body: body, token: token)
        }
    }

    func deleteNotice(_ notice: Notice) async {
        await withToken { token, _, _ in
            try await DiscussionsClient(transport: transport).deleteNotice(id: notice.id, token: token)
        }
    }

    func createTask(title: String, dueOn: String?) async {
        await withToken { token, owner, repo in
            let projects = ProjectsClient(transport: transport)
            let number = try await projects.resolveProjectNumber(
                owner: session?.org ?? owner, preferred: projectNumber, token: token
            )
            _ = try await projects.createTask(
                owner: owner, repo: repo, title: title, body: "", projectNumber: number, token: token, dueOn: dueOn
            )
        }
    }

    func updateTask(_ card: TaskCard, status: String, dueOn: String?) async {
        guard let meta = projectMeta else { return }
        let due = dueOn.flatMap { value in
            let trimmed = dueOnInput(value)
            return trimmed.isEmpty ? nil : trimmed
        }
        await withToken { token, owner, _ in
            let projects = ProjectsClient(transport: transport)
            let number = try await projects.resolveProjectNumber(
                owner: session?.org ?? owner, preferred: projectNumber, token: token
            )
            let ready = try await projects.ensureDueDateField(
                meta: meta, owner: session?.org ?? owner, projectNumber: number, token: token
            )
            let opt = ready.statusOptions.first { key, _ in
                key == status || taskLane(status: key) == taskLane(status: status)
            }?.value
            try await projects.updateTaskFields(
                projectId: ready.projectId,
                itemId: card.id,
                statusFieldId: ready.statusFieldId,
                statusOptionId: opt,
                dueFieldId: ready.dueFieldId,
                dueOn: due,
                token: token
            )
        }
    }

    func deleteTask(_ card: TaskCard) async {
        guard let meta = projectMeta else { return }
        await withToken { token, owner, repo in
            try await ProjectsClient(transport: transport).deleteTask(
                projectId: meta.projectId, itemId: card.id, owner: owner, repo: repo, issueNumber: card.issueNumber, token: token
            )
        }
    }

    func saveDoc(path: String, content: String) async {
        await withToken { token, owner, repo in
            let p = path.hasPrefix("docs/") ? path : "docs/\(path)"
            let sha = p == docPath ? docSha : nil
            _ = try await DocsClient(transport: transport, cache: cache)
                .saveMarkdown(owner: owner, repo: repo, path: p, content: content, token: token, sha: sha)
        }
    }

    func openDoc(path: String) async {
        guard let token = try? tokens.loadAccessToken(), let parts = repoParts else { return }
        do {
            let file = try await DocsClient(transport: transport, cache: cache)
                .fetchMarkdown(owner: parts.owner, repo: parts.repo, path: path, token: token)
            docPath = file.path
            docPreview = file.content
            docSha = file.sha
            docFailed = false
            writeError = nil
        } catch {
            writeError = writeFailureMessage(String(describing: error))
        }
    }

    func listDocs(at path: String) async {
        guard let token = try? tokens.loadAccessToken(), let parts = repoParts else { return }
        do {
            let entries = try await DocsClient(transport: transport, cache: cache)
                .listDocs(owner: parts.owner, repo: parts.repo, token: token, path: path)
            docsDirPath = path
            docs = entries
            docFailed = false
            writeError = nil
        } catch {
            if case GitHubAPIError.httpStatus(404) = error {
                docsDirPath = path
                docs = []
                docFailed = false
            } else {
                writeError = writeFailureMessage(String(describing: error))
                docFailed = true
            }
        }
    }

    func deleteDoc() async {
        guard let sha = docSha else { return }
        await withToken { token, owner, repo in
            try await DocsClient(transport: transport, cache: cache)
                .deleteDoc(owner: owner, repo: repo, path: docPath, sha: sha, token: token)
        }
    }

    func postTalk(_ body: String) async {
        await withToken { token, owner, repo in
            let talk = ThreadTalkClient(transport: transport)
            let issue = try await talk.ensureTalkIssueNumber(owner: owner, repo: repo, token: token)
            talkIssueNumber = issue
            _ = try await talk.postComment(owner: owner, repo: repo, issueNumber: issue, body: body, token: token)
        }
    }

    func updateTalk(_ message: ThreadMessage, body: String) async {
        await withToken { token, owner, repo in
            _ = try await ThreadTalkClient(transport: transport)
                .updateComment(owner: owner, repo: repo, commentId: message.id, body: body, token: token)
        }
    }

    func deleteTalk(_ message: ThreadMessage) async {
        await withToken { token, owner, repo in
            try await ThreadTalkClient(transport: transport)
                .deleteComment(owner: owner, repo: repo, commentId: message.id, token: token)
        }
    }

    func reactTalk(_ message: ThreadMessage) async {
        await withToken { token, owner, repo in
            try await ThreadTalkClient(transport: transport)
                .addReaction(owner: owner, repo: repo, commentId: message.id, content: "+1", token: token)
        }
    }

    func openDiscord() {
        let server = Bundle.main.object(forInfoDictionaryKey: "DiscordServerID") as? String ?? "REPLACE_ME"
        let channel = Bundle.main.object(forInfoDictionaryKey: "DiscordChannelID") as? String ?? "REPLACE_ME"
        UIApplication.shared.open(DiscordDeepLink.voiceChannelURL(serverId: server, channelId: channel))
    }

    func registerPushDevice() async {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "PushBridgeURL") as? String,
              let url = URL(string: base + "/devices"),
              let org = session?.org else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "userId": org,
            "token": "apns-token-placeholder",
        ])
        _ = try? await URLSession.shared.data(for: request)
    }
}

private extension Color {
    static let crewInk = Color(red: 15.0 / 255, green: 92.0 / 255, blue: 92.0 / 255)
}

struct RootView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        Group {
            if model.session != nil {
                TabView(selection: $model.selectedTab) {
                    HomeTab(model: model)
                        .tabItem { Label("홈", systemImage: "house") }
                        .tag(0)
                    TasksTab(model: model)
                        .tabItem { Label("할 일", systemImage: "checklist") }
                        .tag(1)
                    DocsTab(model: model)
                        .tabItem { Label("자료실", systemImage: "folder") }
                        .tag(2)
                    TalkTab(model: model)
                        .tabItem { Label("소통", systemImage: "bubble.left.and.bubble.right") }
                        .tag(3)
                }
                .tint(.crewInk)
                .task { await model.refreshHomeData() }
            } else if !model.registrableRepos.isEmpty {
                NavigationStack {
                    List(model.registrableRepos) { repo in
                        Button { model.register(repo) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(crewDisplayName(repo.fullName)).foregroundStyle(.primary)
                                if !crewOwnerName(repo.fullName).isEmpty {
                                    Text(crewOwnerName(repo.fullName))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .navigationTitle("크루 시작")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("로그아웃") { model.logout() }
                        }
                    }
                    .safeAreaInset(edge: .top) {
                        Text("운영 권한이 있는 보관소를 고르세요.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                    }
                }
            } else {
                LoginView(error: model.errorMessage) { model.login() }
            }
        }
        .onOpenURL { model.handleOAuthCallback($0) }
    }
}

private struct LoginView: View {
    let error: String?
    let onLogin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            Text("크루를 위한 작업 공간")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.crewInk)
            Text("CrewRP").font(.largeTitle.bold())
            Text("할 일, 공지, 자료를 한곳에서 봅니다.")
                .foregroundStyle(.secondary)
            Button(action: onLogin) {
                Text("로그인").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.crewInk)
            .padding(.top, 20)
            if let error {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

private struct HomeTab: View {
    @ObservedObject var model: AppModel
    @State private var composing = false
    @State private var editing: Notice?

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.tasks.isEmpty && model.notices.isEmpty {
                    ProgressView()
                } else if homeQuiet && (model.tasksFailed || model.noticesFailed) {
                    FailedHint { await model.refreshHomeData(forceNetwork: true) }
                } else if homeQuiet {
                    EmptyHint(title: "아직 소식이 없습니다", message: "+ 로 공지를 작성하세요.")
                } else {
                    List {
                        if let err = model.writeError {
                            Section { Text(err).foregroundStyle(.red) }
                        }
                        if let session = model.session {
                            Section {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.org).font(.headline)
                                    Text("\(crewDisplayName(session.repo)) · \(session.teamRole.label)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if !sections.today.isEmpty {
                            Section("오늘 할 일") { ForEach(sections.today, id: \.id) { TaskRow(task: $0) } }
                        }
                        if !sections.notices.isEmpty {
                            Section("고정 공지") {
                                ForEach(sections.notices, id: \.id) { notice in
                                    Button { editing = notice } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(notice.title).font(.headline).foregroundStyle(.primary)
                                            if !notice.body.isEmpty {
                                                Text(notice.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if !sections.upcoming.isEmpty {
                            Section("다가오는 할 일") { ForEach(sections.upcoming, id: \.id) { TaskRow(task: $0) } }
                        }
                    }
                }
            }
            .navigationTitle(model.session.map { crewDisplayName($0.repo) } ?? "홈")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("로그아웃") { model.logout() }
                }
                RefreshButton(model: model)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await model.refreshHomeData(forceNetwork: true) }
            .sheet(isPresented: $composing) {
                ComposeSheet(title: "공지 작성", titleLabel: "제목", bodyLabel: "본문") { t, b in
                    Task { await model.createNotice(title: t, body: b) }
                }
            }
            .sheet(item: $editing) { notice in
                ComposeSheet(
                    title: "공지 수정",
                    titleLabel: "제목",
                    bodyLabel: "본문",
                    initialTitle: notice.title,
                    initialBody: notice.body,
                    showDelete: canMutate(role: model.session?.teamRole ?? .none, authorLogin: notice.authorLogin, currentLogin: model.currentLogin),
                    onSave: { t, b in Task { await model.updateNotice(notice, title: t, body: b) } },
                    onDelete: { Task { await model.deleteNotice(notice) } }
                )
            }
        }
    }

    private var sections: HomeSections {
        homeSections(tasks: model.tasks, notices: model.notices, today: todayISO())
    }

    private var homeQuiet: Bool {
        sections.today.isEmpty && sections.upcoming.isEmpty && sections.notices.isEmpty
    }
}

private struct TasksTab: View {
    @ObservedObject var model: AppModel
    @State private var mode = 0
    @State private var composing = false
    @State private var editing: TaskCard?

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.tasks.isEmpty && !model.tasksFailed {
                    ProgressView()
                } else if model.tasksFailed && model.tasks.isEmpty {
                    FailedHint { await model.refreshHomeData(forceNetwork: true) }
                } else if model.tasks.isEmpty {
                    EmptyHint(title: "아직 할 일이 없습니다", message: "+ 로 새 할 일을 추가하세요.")
                } else {
                    VStack(spacing: 0) {
                        if let err = model.writeError {
                            Text(err).font(.footnote).foregroundStyle(.red).padding(.top, 8)
                        }
                        Picker("보기", selection: $mode) {
                            Text("칸반").tag(0)
                            Text("마감일").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding()
                        if mode == 0 {
                            KanbanBoard(tasks: model.tasks) { editing = $0 }
                        } else {
                            List(model.tasks, id: \.id) { task in
                                Button { editing = task } label: { TaskRow(task: task) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("할 일")
            .toolbar {
                RefreshButton(model: model)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await model.refreshHomeData(forceNetwork: true) }
            .sheet(isPresented: $composing) {
                ComposeSheet(title: "할 일 추가", titleLabel: "제목", bodyLabel: "마감 (YYYY-MM-DD)", initialBody: "") { t, due in
                    Task { await model.createTask(title: t, dueOn: due.isEmpty ? nil : due) }
                }
            }
            .sheet(item: $editing) { task in
                TaskEditSheet(
                    task: task,
                    showDelete: model.session?.teamRole == .admin,
                    onSave: { status, due in Task { await model.updateTask(task, status: status, dueOn: due) } },
                    onDelete: { Task { await model.deleteTask(task) } }
                )
            }
        }
    }
}

private struct KanbanBoard: View {
    let tasks: [TaskCard]
    var onSelect: (TaskCard) -> Void = { _ in }
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let stacked = kanbanUsesStackedLanes(compact: sizeClass == .compact)
        if stacked {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(TaskLane.allCases, id: \.self) { lane in
                        KanbanLaneColumn(tasks: tasks, lane: lane, stacked: true, onSelect: onSelect)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(TaskLane.allCases, id: \.self) { lane in
                        KanbanLaneColumn(tasks: tasks, lane: lane, stacked: false, onSelect: onSelect)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct KanbanLaneColumn: View {
    let tasks: [TaskCard]
    let lane: TaskLane
    let stacked: Bool
    var onSelect: (TaskCard) -> Void

    var body: some View {
        let laneTasks = tasks.filter { taskLane(status: $0.status) == lane }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(lane.title).font(.headline)
                Spacer()
                Text("\(laneTasks.count)").foregroundStyle(.secondary)
            }
            ForEach(laneTasks, id: \.id) { task in
                Button { onSelect(task) } label: { TaskRow(task: task) }
            }
        }
        .padding(12)
        .frame(maxWidth: stacked ? .infinity : nil, alignment: .topLeading)
        .frame(width: stacked ? nil : 260, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct TaskEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let task: TaskCard
    var showDelete = false
    var onSave: (String, String?) -> Void
    var onDelete: (() -> Void)?

    @State private var status: String
    @State private var dueOn: String

    init(
        task: TaskCard,
        showDelete: Bool = false,
        onSave: @escaping (String, String?) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.task = task
        self.showDelete = showDelete
        self.onSave = onSave
        self.onDelete = onDelete
        _status = State(initialValue: taskStatusChoice(status: task.status))
        _dueOn = State(initialValue: dueOnInput(task.dueOn))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("제목", text: .constant(task.title)).disabled(true)
                Picker("상태", selection: $status) {
                    ForEach(TaskLane.allCases, id: \.self) { lane in
                        Text(lane.title).tag(lane.title)
                    }
                }
                .pickerStyle(.segmented)
                TextField("납기 (YYYY-MM-DD)", text: $dueOn)
            }
            .navigationTitle("할 일 수정")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        let due = dueOnInput(dueOn)
                        onSave(status, due.isEmpty ? nil : due)
                        dismiss()
                    }
                }
                if showDelete, let onDelete {
                    ToolbarItem(placement: .bottomBar) {
                        Button("삭제", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

private struct DocsTab: View {
    @ObservedObject var model: AppModel
    @State private var composing = false
    @State private var showingDetail = false
    @State private var search = ""

    private var listed: [DocEntry] { filterDocs(model.docs, query: search) }
    private var parentPath: String? { parentDocsPath(model.docsDirPath) }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.docs.isEmpty && !model.docFailed {
                    ProgressView()
                } else if model.docFailed && model.docs.isEmpty {
                    FailedHint { await model.refreshHomeData(forceNetwork: true) }
                } else {
                    VStack(spacing: 0) {
                        if let err = model.writeError {
                            Text(err).font(.footnote).foregroundStyle(.red).padding(8)
                        }
                        TextField("이름·경로 검색", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        if listed.isEmpty {
                            EmptyHint(
                                title: model.docs.isEmpty ? "자료실이 비어 있습니다" : "검색 결과가 없습니다",
                                message: model.docs.isEmpty ? "+ 로 자료를 추가하세요." : "다른 검색어를 입력해 보세요."
                            )
                        } else {
                            List(listed, id: \.path) { entry in
                                Button {
                                    if entry.isDir {
                                        Task { await model.listDocs(at: entry.path) }
                                    } else {
                                        Task {
                                            await model.openDoc(path: entry.path)
                                            showingDetail = true
                                        }
                                    }
                                } label: {
                                    Label(entry.name, systemImage: entry.isDir ? "folder.fill" : "doc.text")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .listStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("자료실")
            .toolbar {
                if let parentPath {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Task { await model.listDocs(at: parentPath) }
                        } label: {
                            Label("상위", systemImage: "chevron.up")
                        }
                    }
                }
                RefreshButton(model: model)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await model.refreshHomeData(forceNetwork: true) }
            .sheet(isPresented: $composing) {
                ComposeSheet(
                    title: "자료 저장",
                    titleLabel: "경로 (docs/…)",
                    bodyLabel: "내용",
                    initialTitle: model.docsDirPath == "docs" ? "docs/notes.md" : "\(model.docsDirPath)/notes.md"
                ) { path, body in
                    Task { await model.saveDoc(path: path, content: body) }
                }
            }
            .sheet(isPresented: $showingDetail) {
                DocDetailSheet(model: model)
            }
        }
    }
}

private struct DocDetailSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var draft = ""

    private var canDelete: Bool { model.session?.teamRole == .admin && model.docSha != nil }

    var body: some View {
        NavigationStack {
            Group {
                if editing {
                    TextEditor(text: $draft).padding()
                } else if docBlocks(model.docPreview).isEmpty {
                    EmptyHint(title: "내용이 없습니다", message: "편집으로 내용을 추가하세요.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(docBlocks(model.docPreview).enumerated()), id: \.offset) { _, block in
                                switch block {
                                case .heading(let text): Text(text).font(.title2.bold()).padding(.top, 8)
                                case .bullet(let text): Text("·  \(text)")
                                case .paragraph(let text): Text(text)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    }
                }
            }
            .navigationTitle(model.docPath.split(separator: "/").last.map(String.init) ?? "자료")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
                if editing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("저장") {
                            Task {
                                await model.saveDoc(path: model.docPath, content: draft)
                                editing = false
                                dismiss()
                            }
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("편집") {
                            draft = model.docPreview
                            editing = true
                        }
                    }
                    if canDelete {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("삭제", role: .destructive) {
                                Task {
                                    await model.deleteDoc()
                                    dismiss()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct TalkTab: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @State private var editing: ThreadMessage?
    @FocusState private var composerFocused: Bool

    private var discordReady: Bool {
        let server = Bundle.main.object(forInfoDictionaryKey: "DiscordServerID") as? String ?? ""
        let channel = Bundle.main.object(forInfoDictionaryKey: "DiscordChannelID") as? String ?? ""
        return discordConfigured(serverId: server, channelId: channel)
    }

    private func dismissComposer() {
        composerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let err = model.writeError {
                    Text(err).font(.footnote).foregroundStyle(.red).padding(8)
                }
                Group {
                    if model.isLoading && model.threadMessages.isEmpty && !model.threadsFailed {
                        ProgressView()
                    } else if model.threadsFailed && model.threadMessages.isEmpty {
                        FailedHint { await model.refreshHomeData(forceNetwork: true) }
                    } else if model.threadMessages.isEmpty {
                        EmptyHint(title: "스레드 톡이 없습니다", message: "아래에 메시지를 남겨 보세요.")
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(model.threadMessages, id: \.id) { message in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(message.author).font(.caption).foregroundStyle(.secondary)
                                        Text(message.body)
                                            .padding(12)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                                        HStack {
                                            Button("좋아요") { Task { await model.reactTalk(message) } }
                                            if canMutate(role: model.session?.teamRole ?? .none, authorLogin: message.author, currentLogin: model.currentLogin) {
                                                Button("수정") { editing = message }
                                                Button("삭제", role: .destructive) { Task { await model.deleteTalk(message) } }
                                            }
                                        }
                                        .font(.caption)
                                    }
                                }
                            }
                            .padding(16)
                        }
                        .scrollDismissesKeyboard(.immediately)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if composerFocused {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { dismissComposer() }
                    }
                }
                HStack {
                    TextField("메시지", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($composerFocused)
                    Button("보내기") {
                        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !body.isEmpty else { return }
                        draft = ""
                        dismissComposer()
                        Task { await model.postTalk(body) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.crewInk)
                }
                .padding(12)
                if discordReady {
                    Button("바로 대화") { model.openDiscord() }
                        .buttonStyle(.borderedProminent)
                        .tint(.crewInk)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
            .navigationTitle("소통")
            .toolbar {
                RefreshButton(model: model)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("완료") { dismissComposer() }
                }
            }
            .refreshable { await model.refreshHomeData(forceNetwork: true) }
            .sheet(item: $editing) { message in
                ComposeSheet(
                    title: "메시지 수정",
                    titleLabel: "작성자",
                    bodyLabel: "본문",
                    initialTitle: message.author,
                    initialBody: message.body,
                    titleEnabled: false,
                    onSave: { _, body in Task { await model.updateTalk(message, body: body) } }
                )
            }
        }
    }
}

private struct ComposeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var titleLabel = "제목"
    var bodyLabel = "본문"
    var initialTitle = ""
    var initialBody = ""
    var titleEnabled = true
    var showDelete = false
    var onSave: (String, String) -> Void
    var onDelete: (() -> Void)?

    @State private var fieldTitle = ""
    @State private var fieldBody = ""

    init(
        title: String,
        titleLabel: String = "제목",
        bodyLabel: String = "본문",
        initialTitle: String = "",
        initialBody: String = "",
        titleEnabled: Bool = true,
        showDelete: Bool = false,
        onSave: @escaping (String, String) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.title = title
        self.titleLabel = titleLabel
        self.bodyLabel = bodyLabel
        self.initialTitle = initialTitle
        self.initialBody = initialBody
        self.titleEnabled = titleEnabled
        self.showDelete = showDelete
        self.onSave = onSave
        self.onDelete = onDelete
        _fieldTitle = State(initialValue: initialTitle)
        _fieldBody = State(initialValue: initialBody)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(titleLabel, text: $fieldTitle).disabled(!titleEnabled)
                TextField(bodyLabel, text: $fieldBody, axis: .vertical).lineLimit(4...12)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        onSave(fieldTitle, fieldBody)
                        dismiss()
                    }
                }
                if showDelete, let onDelete {
                    ToolbarItem(placement: .bottomBar) {
                        Button("삭제", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

private struct TaskRow: View {
    let task: TaskCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.title).font(.headline)
            HStack(spacing: 8) {
                Text(taskLane(status: task.status).title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.crewInk.opacity(0.12), in: Capsule())
                Text(formatDue(task.dueOn))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RefreshButton: ToolbarContent {
    @ObservedObject var model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await model.refreshHomeData(forceNetwork: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("새로고침")
        }
    }
}

private struct EmptyHint: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailedHint: View {
    let retry: () async -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("내용을 불러오지 못했습니다").font(.headline)
            Text("연결을 확인한 뒤 다시 시도해 주세요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("다시 시도") { Task { await retry() } }
                .buttonStyle(.borderedProminent)
                .tint(.crewInk)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func todayISO() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}
