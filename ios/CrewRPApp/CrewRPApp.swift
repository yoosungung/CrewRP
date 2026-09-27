import SwiftUI
import UIKit
import AuthenticationServices
import CrewRPCore

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
    private var didRegisterPush = false

    private let flow: AuthFlow
    private let cache: CacheStore
    private let tokens: KeychainTokenStore
    private let transport = URLSessionTransport()
    private var webSession: ASWebAuthenticationSession?

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
            cache: cache
        )
        session = try? cache.session()
    }

    func login() {
        let challenge = flow.beginLogin()
        let session = ASWebAuthenticationSession(
            url: challenge.authorizeURL,
            callbackURLScheme: "crewrp"
        ) { [weak self] callback, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil {
                    self.errorMessage = "로그인에 실패했습니다. 잠시 후 다시 시도해 주세요."
                    return
                }
                guard let callback else { return }
                do {
                    self.registrableRepos = try await self.flow.completeLogin(callbackURL: callback)
                    if self.registrableRepos.isEmpty {
                        self.errorMessage = "운영 권한이 있는 보관소가 없습니다."
                    }
                } catch {
                    self.errorMessage = "로그인에 실패했습니다. 잠시 후 다시 시도해 주세요."
                }
            }
        }
        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = AuthPresenter.shared
        webSession = session
        session.start()
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

    func refreshHomeData() async {
        guard let session, let token = try? tokens.loadAccessToken(), let parts = repoParts else { return }
        let owner = parts.owner
        let repo = parts.repo
        isLoading = true
        defer { isLoading = false }

        currentLogin = try? await GitHubMembershipClient(transport: transport).currentUser(token: token).login

        do {
            let projects = ProjectsClient(transport: transport)
            tasks = try await projects.sortedByDueDate(
                projects.listTasks(org: session.org, projectNumber: projectNumber, token: token)
            )
            projectMeta = try? await projects.loadFieldMeta(owner: session.org, projectNumber: projectNumber, token: token)
            tasksFailed = false
        } catch {
            tasksFailed = true
        }

        do {
            let discussions = DiscussionsClient(transport: transport)
            notices = try await discussions.listNotices(owner: owner, repo: repo, token: token)
            discussionSetup = try? await discussions.resolveSetup(owner: owner, repo: repo, token: token)
            noticesFailed = false
        } catch {
            noticesFailed = true
        }

        do {
            let docsClient = DocsClient(transport: transport, cache: cache)
            docs = (try? await docsClient.listDocs(owner: owner, repo: repo, token: token)) ?? []
            let path = docs.first(where: { !$0.isDir && $0.name.lowercased() == "readme.md" })?.path ?? docPath
            let file = try await docsClient.fetchMarkdown(owner: owner, repo: repo, path: path, token: token)
            docPath = file.path
            docPreview = file.content
            docSha = file.sha
            docFailed = false
        } catch {
            docFailed = true
        }

        do {
            threadMessages = try await ThreadTalkClient(transport: transport)
                .listIssueComments(owner: owner, repo: repo, issueNumber: 1, token: token)
            threadsFailed = false
        } catch {
            threadsFailed = true
        }

        if !didRegisterPush {
            didRegisterPush = true
            await registerPushDevice()
        }
    }

    private func withToken(_ work: (String, String, String) async throws -> Void) async {
        guard let token = try? tokens.loadAccessToken(), let parts = repoParts else { return }
        do {
            try await work(token, parts.owner, parts.repo)
            writeError = nil
            await refreshHomeData()
        } catch {
            writeError = "저장하지 못했습니다. 잠시 후 다시 시도해 주세요."
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
            _ = try await ProjectsClient(transport: transport).createTask(
                owner: owner, repo: repo, title: title, body: "", projectNumber: projectNumber, token: token, dueOn: dueOn
            )
        }
    }

    func updateTask(_ card: TaskCard, status: String) async {
        guard let meta = projectMeta else { return }
        let opt = meta.statusOptions.first { key, _ in
            key == status || taskLane(status: key) == taskLane(status: status)
        }?.value
        await withToken { token, _, _ in
            try await ProjectsClient(transport: transport).updateTaskFields(
                projectId: meta.projectId,
                itemId: card.id,
                statusFieldId: meta.statusFieldId,
                statusOptionId: opt,
                dueFieldId: nil,
                dueOn: nil,
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
        } catch {
            writeError = "저장하지 못했습니다. 잠시 후 다시 시도해 주세요."
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
            _ = try await ThreadTalkClient(transport: transport)
                .postComment(owner: owner, repo: repo, issueNumber: 1, body: body, token: token)
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

final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthPresenter()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
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
                    FailedHint { await model.refreshHomeData() }
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
                RefreshButton(model: model)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await model.refreshHomeData() }
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
                    FailedHint { await model.refreshHomeData() }
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
            .refreshable { await model.refreshHomeData() }
            .sheet(isPresented: $composing) {
                ComposeSheet(title: "할 일 추가", titleLabel: "제목", bodyLabel: "마감 (YYYY-MM-DD)", initialBody: "") { t, due in
                    Task { await model.createTask(title: t, dueOn: due.isEmpty ? nil : due) }
                }
            }
            .sheet(item: $editing) { task in
                ComposeSheet(
                    title: "할 일 수정",
                    titleLabel: "제목",
                    bodyLabel: "상태 (접수/진행 중/완료)",
                    initialTitle: task.title,
                    initialBody: task.status,
                    titleEnabled: false,
                    showDelete: model.session?.teamRole == .admin,
                    onSave: { _, status in Task { await model.updateTask(task, status: status) } },
                    onDelete: { Task { await model.deleteTask(task) } }
                )
            }
        }
    }
}

private struct KanbanBoard: View {
    let tasks: [TaskCard]
    var onSelect: (TaskCard) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(TaskLane.allCases, id: \.self) { lane in
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
                    .frame(width: 260, alignment: .topLeading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct DocsTab: View {
    @ObservedObject var model: AppModel
    @State private var composing = false
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.docPreview.isEmpty && !model.docFailed {
                    ProgressView()
                } else if model.docFailed && model.docPreview.isEmpty {
                    FailedHint { await model.refreshHomeData() }
                } else if editing {
                    TextEditor(text: $draft).padding()
                } else if docBlocks(model.docPreview).isEmpty {
                    EmptyHint(title: "자료실이 비어 있습니다", message: "+ 로 자료를 추가하세요.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ScrollView(.horizontal) {
                                HStack {
                                    ForEach(model.docs.filter { !$0.isDir }, id: \.path) { entry in
                                        Button(entry.name) { Task { await model.openDoc(path: entry.path) } }
                                    }
                                }
                            }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("자료실")
            .toolbar {
                RefreshButton(model: model)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Image(systemName: "plus") }
                }
                if editing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("저장") {
                            Task {
                                await model.saveDoc(path: model.docPath, content: draft)
                                editing = false
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
                }
            }
            .refreshable { await model.refreshHomeData() }
            .sheet(isPresented: $composing) {
                ComposeSheet(title: "자료 저장", titleLabel: "경로 (docs/…)", bodyLabel: "내용", initialTitle: "docs/notes.md") { path, body in
                    Task { await model.saveDoc(path: path, content: body) }
                }
            }
        }
    }
}

private struct TalkTab: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @State private var editing: ThreadMessage?

    private var discordReady: Bool {
        let server = Bundle.main.object(forInfoDictionaryKey: "DiscordServerID") as? String ?? ""
        let channel = Bundle.main.object(forInfoDictionaryKey: "DiscordChannelID") as? String ?? ""
        return discordConfigured(serverId: server, channelId: channel)
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
                        FailedHint { await model.refreshHomeData() }
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
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    TextField("메시지", text: $draft)
                        .textFieldStyle(.roundedBorder)
                    Button("보내기") {
                        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !body.isEmpty else { return }
                        draft = ""
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
            .toolbar { RefreshButton(model: model) }
            .refreshable { await model.refreshHomeData() }
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
                Task { await model.refreshHomeData() }
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
