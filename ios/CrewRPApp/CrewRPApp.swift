import SwiftUI
import UIKit
import UniformTypeIdentifiers
import QuickLook
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
    @Published var readme: String = ""
    @Published var docPreview: String = ""
    @Published var docPath: String = "docs/README.md"
    @Published var docSha: String?
    @Published var docs: [DocEntry] = []
    @Published var docsTree: [DocEntry] = []
    @Published var docsDirPath: String = "docs"
    @Published var attachments: [AttachmentEntry] = []
    @Published var discussionCategories: [DiscussionCategory] = []
    @Published var discussionRepositoryId: String?
    @Published var selectedCategory: DiscussionCategory?
    @Published var boardPosts: [Notice] = []
    @Published var taskComments: [ThreadMessage] = []
    @Published var isLoading = false
    @Published var tasksFailed = false
    @Published var readmeFailed = false
    @Published var boardFailed = false
    @Published var docFailed = false
    @Published var writeError: String?
    @Published var currentLogin: String?
    @Published var projectMeta: ProjectFieldMeta?
    @Published var discordLink: AccountLink?
    @Published var crewSettings: CrewSettingsFile?
    @Published var discordServerDraft = ""
    @Published var discordChannelDraft = ""
    private var didRegisterPush = false

    private let flow: AuthFlow
    private let discordFlow: DiscordLinkFlow
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
        let bridge = AuthBridgeClient(baseURL: config.authBridgeBaseURL, transport: transport)
        flow = AuthFlow(
            config: config,
            bridge: bridge,
            membership: GitHubMembershipClient(transport: transport),
            tokens: tokens,
            cache: cache,
            pendingStore: UserDefaultsPendingLoginStore()
        )
        discordFlow = DiscordLinkFlow(
            config: DiscordAuthConfig(
                clientID: Bundle.main.object(forInfoDictionaryKey: "DiscordClientID") as? String ?? "REPLACE_ME",
                authBridgeBaseURL: config.authBridgeBaseURL
            ),
            bridge: bridge,
            cache: cache,
            pendingStore: UserDefaultsPendingLoginStore(
                stateKey: "crewrp.discord.oauth.state",
                verifierKey: "crewrp.discord.oauth.verifier"
            )
        )
        session = try? cache.session()
        discordLink = try? discordFlow.linkedDiscord()
    }

    func login() {
        errorMessage = nil
        let challenge = flow.beginLogin()
        // External Safari (same as Android): ASWebAuthenticationSession was dropping the
        // post-token repo list call after OAuth return on recent simulators.
        UIApplication.shared.open(challenge.authorizeURL)
    }

    func handleOAuthCallback(_ url: URL) {
        let isDiscordCallback =
            (url.scheme?.hasPrefix("discord-") == true)
            || (url.scheme == "crewrp" && (url.path.hasPrefix("/discord") || url.path == "/discord"))
        if isDiscordCallback {
            Task {
                do {
                    discordLink = try await discordFlow.completeLink(callbackURL: url)
                    writeError = nil
                } catch {
                    log.error("discord link failed: \(String(describing: error), privacy: .public)")
                    writeError = "Discord 연결에 실패했습니다. 잠시 후 다시 시도해 주세요."
                }
            }
            return
        }
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

    func linkDiscord() {
        writeError = nil
        let challenge = discordFlow.beginLink()
        UIApplication.shared.open(challenge.authorizeURL)
    }

    func unlinkDiscord() {
        try? discordFlow.unlink()
        discordLink = nil
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
        readme = ""
        docs = []
        docsTree = []
        docsDirPath = "docs"
        attachments = []
        discussionCategories = []
        discussionRepositoryId = nil
        selectedCategory = nil
        boardPosts = []
        taskComments = []
        discordLink = nil
        crewSettings = nil
        discordServerDraft = ""
        discordChannelDraft = ""
        currentLogin = nil
        projectMeta = nil
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
            var readme: String = ""
            var readmeFailed = false
            var categories: [DiscussionCategory] = []
            var repositoryId: String?
            var boardFailed = false
            var docs: [DocEntry] = []
            var docsTree: [DocEntry] = []
            var docsDirPath: String
            var docFailed = false
            var attachments: [AttachmentEntry] = []
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

            async let readmeTask: (text: String, failed: Bool) = {
                do {
                    let text = try await DocsClient(transport: transport, cache: cache)
                        .fetchReadme(owner: owner, repo: repo, token: token) ?? ""
                    return (text, false)
                } catch {
                    return ("", true)
                }
            }()

            async let boardTask: (categories: [DiscussionCategory], repositoryId: String?, failed: Bool) = {
                do {
                    let setup = try await DiscussionsClient(transport: transport).listCategories(
                        owner: owner,
                        repo: repo,
                        token: token,
                        cache: cache,
                        forceNetwork: forceNetwork
                    )
                    return (setup.categories, setup.repositoryId, false)
                } catch {
                    return ([], nil, true)
                }
            }()

            async let docsTask: (entries: [DocEntry], tree: [DocEntry], dir: String, failed: Bool) = {
                let docsClient = DocsClient(transport: transport, cache: cache)
                let entries: [DocEntry]
                var folderFailed = false
                do {
                    entries = try await docsClient.listDocs(owner: owner, repo: repo, token: token, path: listPath)
                } catch {
                    if case GitHubAPIError.httpStatus(404) = error {
                        entries = []
                    } else {
                        entries = []
                        folderFailed = true
                    }
                }
                let tree = (try? await docsClient.listDocsTree(
                    owner: owner, repo: repo, token: token, forceNetwork: forceNetwork
                )) ?? []
                return (entries, tree, listPath, folderFailed)
            }()

            async let attachmentsTask: [AttachmentEntry] = {
                (try? await ReleaseAssetClient(transport: transport)
                    .listAttachments(owner: owner, repo: repo, token: token)) ?? []
            }()

            let tasks = await tasksTask
            let readme = await readmeTask
            let board = await boardTask
            let docs = await docsTask
            return Snapshot(
                login: await loginTask,
                tasks: tasks.cards,
                tasksFailed: tasks.failed,
                projectMeta: tasks.meta,
                readme: readme.text,
                readmeFailed: readme.failed,
                categories: board.categories,
                repositoryId: board.repositoryId,
                boardFailed: board.failed,
                docs: docs.entries,
                docsTree: docs.tree,
                docsDirPath: docs.dir,
                docFailed: docs.failed,
                attachments: await attachmentsTask
            )
        }.value

        currentLogin = snapshot.login
        if !snapshot.tasksFailed || tasks.isEmpty {
            tasks = snapshot.tasks
        }
        tasksFailed = snapshot.tasksFailed
        if let meta = snapshot.projectMeta { projectMeta = meta }
        if !snapshot.readmeFailed || readme.isEmpty {
            readme = snapshot.readme
        }
        readmeFailed = snapshot.readmeFailed
        if !snapshot.boardFailed || discussionCategories.isEmpty {
            discussionCategories = snapshot.categories
            discussionRepositoryId = snapshot.repositoryId
        }
        boardFailed = snapshot.boardFailed
        if !snapshot.docFailed || docs.isEmpty {
            docs = snapshot.docs
            docsDirPath = snapshot.docsDirPath
        }
        if !snapshot.docFailed || docsTree.isEmpty {
            docsTree = snapshot.docsTree
        }
        docFailed = snapshot.docFailed
        attachments = snapshot.attachments

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

    func createBoardPost(categoryId: String, title: String, body: String) async {
        guard let repositoryId = discussionRepositoryId else { return }
        let reload = selectedCategory
        await withToken { token, _, _ in
            _ = try await DiscussionsClient(transport: transport)
                .createNotice(repositoryId: repositoryId, categoryId: categoryId, title: title, body: body, token: token)
            if let reload, reload.id == categoryId {
                await openBoardCategory(reload)
            }
        }
    }

    func updateBoardPost(_ notice: Notice, title: String, body: String) async {
        await withToken { token, _, _ in
            _ = try await DiscussionsClient(transport: transport).updateNotice(id: notice.id, title: title, body: body, token: token)
            if let cat = selectedCategory {
                await openBoardCategory(cat)
            }
        }
    }

    func deleteBoardPost(_ notice: Notice) async {
        await withToken { token, _, _ in
            try await DiscussionsClient(transport: transport).deleteNotice(id: notice.id, token: token)
            boardPosts.removeAll { $0.id == notice.id }
        }
    }

    func openBoardCategory(_ category: DiscussionCategory) async {
        guard let token = try? tokens.loadAccessToken(), let parts = repoParts else { return }
        selectedCategory = category
        do {
            boardPosts = try await DiscussionsClient(transport: transport).listDiscussions(
                owner: parts.owner,
                repo: parts.repo,
                categoryId: category.id,
                token: token,
                cache: cache,
                forceNetwork: true
            )
            boardFailed = false
            writeError = nil
        } catch {
            boardFailed = true
            writeError = writeFailureMessage(String(describing: error))
        }
    }

    func clearBoardCategory() {
        selectedCategory = nil
        boardPosts = []
    }

    func loadTaskComments(issueNumber: Int) async {
        guard let token = try? tokens.loadAccessToken(), let parts = repoParts else { return }
        do {
            taskComments = try await ThreadTalkClient(transport: transport)
                .listIssueComments(owner: parts.owner, repo: parts.repo, issueNumber: issueNumber, token: token)
            writeError = nil
        } catch {
            writeError = writeFailureMessage(String(describing: error))
        }
    }

    func postTaskComment(issueNumber: Int, body: String) async {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let token = try? tokens.loadAccessToken(),
              let parts = repoParts else { return }
        do {
            let msg = try await ThreadTalkClient(transport: transport)
                .postComment(owner: parts.owner, repo: parts.repo, issueNumber: issueNumber, body: text, token: token)
            taskComments.append(msg)
            writeError = nil
        } catch {
            writeError = writeFailureMessage(String(describing: error))
        }
    }

    func updateTaskComment(commentId: String, body: String) async {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let token = try? tokens.loadAccessToken(),
              let parts = repoParts else { return }
        do {
            let msg = try await ThreadTalkClient(transport: transport)
                .updateComment(owner: parts.owner, repo: parts.repo, commentId: commentId, body: text, token: token)
            if let idx = taskComments.firstIndex(where: { $0.id == commentId }) {
                taskComments[idx] = msg
            }
            writeError = nil
        } catch {
            writeError = writeFailureMessage(String(describing: error))
        }
    }

    func deleteTaskComment(commentId: String) async {
        guard let token = try? tokens.loadAccessToken(), let parts = repoParts else { return }
        do {
            try await ThreadTalkClient(transport: transport)
                .deleteComment(owner: parts.owner, repo: parts.repo, commentId: commentId, token: token)
            taskComments.removeAll { $0.id == commentId }
            writeError = nil
        } catch {
            writeError = writeFailureMessage(String(describing: error))
        }
    }

    func createTask(title: String, body: String, status: String, dueOn: String?) async {
        await withToken { token, owner, repo in
            let projects = ProjectsClient(transport: transport)
            let number = try await projects.resolveProjectNumber(
                owner: session?.org ?? owner, preferred: projectNumber, token: token
            )
            _ = try await projects.createTask(
                owner: owner,
                repo: repo,
                title: title,
                body: body,
                projectNumber: number,
                token: token,
                dueOn: dueOn,
                statusLabel: status
            )
        }
    }

    func updateTask(_ card: TaskCard, title: String, body: String, status: String, dueOn: String?) async {
        guard let meta = projectMeta else { return }
        let due = dueOn.flatMap { value in
            let trimmed = dueOnInput(value)
            return trimmed.isEmpty ? nil : trimmed
        }
        await withToken { token, owner, repo in
            let projects = ProjectsClient(transport: transport)
            if let issueNumber = card.issueNumber {
                try await projects.updateIssue(
                    owner: owner, repo: repo, issueNumber: issueNumber, title: title, body: body, token: token
                )
            }
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

    func uploadAttachment(name: String, bytes: Data, contentType: String) async {
        await withToken { token, owner, repo in
            let entry = try await ReleaseAssetClient(transport: transport).uploadAttachment(
                owner: owner,
                repo: repo,
                name: name,
                bytes: bytes,
                contentType: contentType,
                token: token
            )
            if !attachments.contains(where: { $0.id == entry.id }) {
                attachments.insert(entry, at: 0)
            }
        }
    }

    /// Downloads attachment bytes to a temp file for QuickLook / share.
    func materializeAttachment(_ entry: AttachmentEntry) async -> URL? {
        guard let token = try? tokens.loadAccessToken() else {
            writeError = "로그인이 만료되었습니다. 다시 로그인해 주세요."
            return nil
        }
        do {
            let data = try await ReleaseAssetClient(transport: transport)
                .downloadBytes(asset: entry, token: token)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crewrp-attachments", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(entry.name)
            try data.write(to: url, options: .atomic)
            writeError = nil
            return url
        } catch {
            writeError = writeFailureMessage(String(describing: error))
            return nil
        }
    }

    var discordReady: Bool {
        crewSettings?.settings.discord?.isConfigured == true
    }

    func loadCrewSettings() async {
        guard let token = try? tokens.loadAccessToken(), let parts = repoParts else { return }
        do {
            let file = try await CrewSettingsClient(transport: transport, cache: cache)
                .load(owner: parts.owner, repo: parts.repo, token: token)
            crewSettings = file
            if let discord = file?.settings.discord {
                discordServerDraft = discord.serverId
                discordChannelDraft = discord.channelId
            }
        } catch {
            log.error("crew settings load failed: \(String(describing: error), privacy: .public)")
        }
    }

    func openDiscord() {
        guard let discord = crewSettings?.settings.discord, discord.isConfigured else { return }
        UIApplication.shared.open(
            DiscordDeepLink.voiceChannelURL(serverId: discord.serverId, channelId: discord.channelId)
        )
    }

    /// 소통 탭 진입: 크루 Discord 설정만 로드(자동 딥링크하지 않음).
    func enterTalk() {
        Task { await loadCrewSettings() }
    }

    func saveDiscordSettings() async {
        let server = discordServerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = discordChannelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard discordConfigured(serverId: server, channelId: channel) else {
            writeError = "서버 ID와 채널 ID를 모두 입력해 주세요."
            return
        }
        await withToken { token, owner, repo in
            let settings = CrewSettings(discord: CrewDiscordSettings(serverId: server, channelId: channel))
            crewSettings = try await CrewSettingsClient(transport: transport, cache: cache)
                .save(owner: owner, repo: repo, token: token, settings: settings, sha: crewSettings?.sha)
        }
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
                .onChange(of: model.selectedTab) { _, tab in
                    if tab == 3 { model.enterTalk() }
                }
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

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.tasks.isEmpty && model.readme.isEmpty {
                    ProgressView()
                } else if homeQuiet && (model.tasksFailed || model.readmeFailed) {
                    FailedHint { await model.refreshHomeData(forceNetwork: true) }
                } else if homeQuiet {
                    EmptyHint(title: "아직 소식이 없습니다", message: "할 일을 추가하거나 README를 등록해 보세요.")
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
                        if !model.readme.isEmpty {
                            Section("소개") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(Array(docBlocks(model.readme).enumerated()), id: \.offset) { _, block in
                                        switch block {
                                        case .heading(let text): Text(text).font(.title3.bold())
                                        case .bullet(let text): Text("·  \(text)")
                                        case .paragraph(let text): Text(text).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                            }
                        }
                        if !sections.today.isEmpty {
                            Section("오늘 할 일") { ForEach(sections.today, id: \.id) { TaskRow(task: $0) } }
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
            }
            .refreshable { await model.refreshHomeData(forceNetwork: true) }
        }
    }

    private var sections: HomeSections {
        homeSections(tasks: model.tasks, today: todayISO())
    }

    private var homeQuiet: Bool {
        sections.today.isEmpty && sections.upcoming.isEmpty && model.readme.isEmpty
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
                TaskFormSheet { taskTitle, body, status, due in
                    Task { await model.createTask(title: taskTitle, body: body, status: status, dueOn: due) }
                }
            }
            .sheet(item: $editing) { task in
                TaskFormSheet(
                    task: task,
                    model: model,
                    showDelete: model.session?.teamRole == .admin,
                    onSave: { taskTitle, body, status, due in
                        Task { await model.updateTask(task, title: taskTitle, body: body, status: status, dueOn: due) }
                    },
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
            // Horizontal ScrollView centers short content vertically; pin to top like 마감일 list.
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(TaskLane.allCases, id: \.self) { lane in
                        KanbanLaneColumn(tasks: tasks, lane: lane, stacked: false, onSelect: onSelect)
                    }
                }
                .padding(.horizontal, 16)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

private struct TaskFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    var task: TaskCard?
    var model: AppModel?
    var showDelete = false
    var onSave: (String, String, String, String?) -> Void
    var onDelete: (() -> Void)?

    @State private var fieldTitle: String
    @State private var fieldBody: String
    @State private var status: String
    @State private var dueOn: String
    @State private var draftComment = ""
    @State private var editingComment: ThreadMessage?
    @State private var editDraft = ""

    private var sheetTitle: String {
        let t = fieldTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "새 할 일" : t
    }

    init(
        task: TaskCard? = nil,
        model: AppModel? = nil,
        showDelete: Bool = false,
        onSave: @escaping (String, String, String, String?) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.task = task
        self.model = model
        self.showDelete = showDelete
        self.onSave = onSave
        self.onDelete = onDelete
        _fieldTitle = State(initialValue: task?.title ?? "")
        _fieldBody = State(initialValue: task?.body ?? "")
        _status = State(initialValue: task.map { taskStatusChoice(status: $0.status) } ?? TaskLane.inbox.title)
        _dueOn = State(initialValue: dueOnInput(task?.dueOn))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("제목", text: $fieldTitle)
                TextField("내용", text: $fieldBody, axis: .vertical).lineLimit(3...10)
                Picker("상태", selection: $status) {
                    ForEach(TaskLane.allCases, id: \.self) { lane in
                        Text(lane.title).tag(lane.title)
                    }
                }
                .pickerStyle(.menu)
                DueOnField(dueOn: $dueOn)
                if let issueNumber = task?.issueNumber, let model {
                    Section("댓글") {
                        if model.taskComments.isEmpty {
                            Text("아직 댓글이 없습니다.").foregroundStyle(.secondary)
                        } else {
                            ForEach(model.taskComments) { comment in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("@\(comment.author)").font(.caption).foregroundStyle(.secondary)
                                    Text(comment.body)
                                    if canMutate(
                                        role: model.session?.teamRole ?? .none,
                                        authorLogin: comment.author,
                                        currentLogin: model.currentLogin
                                    ) {
                                        HStack {
                                            Button("수정") {
                                                editingComment = comment
                                                editDraft = comment.body
                                            }
                                            .font(.caption)
                                            Button("삭제", role: .destructive) {
                                                Task { await model.deleteTaskComment(commentId: comment.id) }
                                            }
                                            .font(.caption)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        TextField("댓글 작성", text: $draftComment, axis: .vertical)
                            .lineLimit(2...5)
                        Button("댓글 등록") {
                            let text = draftComment
                            draftComment = ""
                            Task { await model.postTaskComment(issueNumber: issueNumber, body: text) }
                        }
                        .disabled(draftComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        let due = dueOnInput(dueOn)
                        onSave(fieldTitle, fieldBody, status, due.isEmpty ? nil : due)
                        dismiss()
                    }
                    .disabled(fieldTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            .task(id: task?.issueNumber) {
                guard let issueNumber = task?.issueNumber else {
                    model?.taskComments = []
                    return
                }
                await model?.loadTaskComments(issueNumber: issueNumber)
            }
            .alert("댓글 수정", isPresented: Binding(
                get: { editingComment != nil },
                set: { if !$0 { editingComment = nil } }
            )) {
                TextField("내용", text: $editDraft)
                Button("저장") {
                    guard let comment = editingComment, let model else { return }
                    let text = editDraft
                    editingComment = nil
                    Task { await model.updateTaskComment(commentId: comment.id, body: text) }
                }
                Button("취소", role: .cancel) { editingComment = nil }
            } message: {
                Text("댓글 내용을 수정합니다.")
            }
        }
    }
}

private func libraryIcon(for item: DocsLibraryItem) -> String {
    switch item {
    case .doc(let e):
        return e.isDir ? "folder.fill" : "doc.text"
    case .attachment(let e):
        let n = e.name.lowercased()
        if n.hasSuffix(".pdf") { return "doc.richtext" }
        if e.isPreviewable { return "photo" }
        return "paperclip"
    }
}

private func mimeType(forFileName name: String) -> String {
    switch name.lowercased().split(separator: ".").last.map(String.init) {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "heic": return "image/heic"
    case "pdf": return "application/pdf"
    case "txt": return "text/plain"
    case "md": return "text/markdown"
    default: return "application/octet-stream"
    }
}

private struct DocsTab: View {
    @ObservedObject var model: AppModel
    @State private var composing = false
    @State private var showingDetail = false
    @State private var showAddMenu = false
    @State private var pickingFile = false
    @State private var previewURL: URL?
    @State private var shareURL: URL?
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var listed: [DocsLibraryItem] {
        listedLibrary(
            folderEntries: model.docs,
            treeEntries: model.docsTree,
            attachments: model.attachments,
            docsDirPath: model.docsDirPath,
            query: search
        )
    }
    private var parentPath: String? { parentDocsPath(model.docsDirPath) }
    private var libraryEmpty: Bool { model.docs.isEmpty && model.attachments.isEmpty }

    private func dismissSearch() {
        searchFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func openAttachment(_ entry: AttachmentEntry) {
        Task {
            guard let url = await model.materializeAttachment(entry) else { return }
            if entry.isPreviewable {
                previewURL = url
            } else {
                shareURL = url
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && libraryEmpty && !model.docFailed {
                    ProgressView()
                } else if model.docFailed && libraryEmpty {
                    FailedHint { await model.refreshHomeData(forceNetwork: true) }
                } else {
                    VStack(spacing: 0) {
                        if let err = model.writeError {
                            Text(err).font(.footnote).foregroundStyle(.red).padding(8)
                        }
                        TextField("이름·경로 검색", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .focused($searchFocused)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        Group {
                            if listed.isEmpty {
                                EmptyHint(
                                    title: libraryEmpty ? "자료실이 비어 있습니다" : "검색 결과가 없습니다",
                                    message: libraryEmpty ? "+ 로 문서·첨부를 추가하세요." : "다른 검색어를 입력해 보세요."
                                )
                            } else {
                                List(listed) { item in
                                    Button {
                                        dismissSearch()
                                        switch item {
                                        case .doc(let entry):
                                            if entry.isDir {
                                                Task { await model.listDocs(at: entry.path) }
                                            } else {
                                                Task {
                                                    await model.openDoc(path: entry.path)
                                                    showingDetail = true
                                                }
                                            }
                                        case .attachment(let entry):
                                            openAttachment(entry)
                                        }
                                    } label: {
                                        Label(item.name, systemImage: libraryIcon(for: item))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .listStyle(.plain)
                                .scrollDismissesKeyboard(.immediately)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            if searchFocused {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture { dismissSearch() }
                            }
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
                            dismissSearch()
                            Task { await model.listDocs(at: parentPath) }
                        } label: {
                            Label("상위", systemImage: "chevron.up")
                        }
                    }
                }
                RefreshButton(model: model)
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismissSearch()
                        showAddMenu = true
                    } label: { Image(systemName: "plus") }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("완료") { dismissSearch() }
                }
            }
            .confirmationDialog("추가", isPresented: $showAddMenu, titleVisibility: .visible) {
                Button("문서 작성") { composing = true }
                Button("파일 첨부") { pickingFile = true }
                Button("취소", role: .cancel) {}
            }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        do {
                            let data = try Data(contentsOf: url)
                            await model.uploadAttachment(
                                name: url.lastPathComponent,
                                bytes: data,
                                contentType: mimeType(forFileName: url.lastPathComponent)
                            )
                        } catch {
                            model.writeError = "파일을 읽지 못했습니다."
                        }
                    }
                case .failure:
                    model.writeError = "파일을 선택하지 못했습니다."
                }
            }
            .quickLookPreview($previewURL)
            .sheet(item: Binding(
                get: { shareURL.map { IdentifiedURL(url: $0) } },
                set: { shareURL = $0?.url }
            )) { item in
                ShareSheet(items: [item.url])
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

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
    @State private var composing = false
    @State private var editing: Notice?

    private var isAdmin: Bool {
        model.session?.teamRole == .admin
    }

    var body: some View {
        NavigationStack {
            List {
                if let err = model.writeError {
                    Section { Text(err).foregroundStyle(.red) }
                }
                Section("바로 대화") {
                    if let link = model.discordLink {
                        Text("연결됨: @\(link.username)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if model.discordReady {
                            Button("바로 대화") { model.openDiscord() }
                        } else if isAdmin {
                            Text("이 크루 Discord 서버·채널을 repo에 등록합니다.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            TextField("서버 ID", text: $model.discordServerDraft)
                                .keyboardType(.numberPad)
                            TextField("채널 ID", text: $model.discordChannelDraft)
                                .keyboardType(.numberPad)
                            Button("서버·채널 저장") {
                                Task { await model.saveDiscordSettings() }
                            }
                        } else {
                            Text("운영진이 Discord 서버·채널을 등록하면 바로 대화를 열 수 있습니다.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button("Discord 연결 해제", role: .destructive) { model.unlinkDiscord() }
                    } else {
                        Text("잡담과 음성은 Discord에서 이어갑니다.")
                            .foregroundStyle(.secondary)
                        Button("Discord 연결") { model.linkDiscord() }
                    }
                }
                if let category = model.selectedCategory {
                    Section(category.name) {
                        if model.boardFailed && model.boardPosts.isEmpty {
                            Text("글을 불러오지 못했습니다.")
                                .foregroundStyle(.secondary)
                        } else if model.boardPosts.isEmpty {
                            Text("글이 없습니다. + 로 작성하세요.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.boardPosts) { post in
                                Button {
                                    editing = post
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(post.title).font(.headline).foregroundStyle(.primary)
                                        if !post.body.isEmpty {
                                            Text(post.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Section("게시판") {
                        if model.boardFailed && model.discussionCategories.isEmpty {
                            Text("카테고리를 불러오지 못했습니다.")
                                .foregroundStyle(.secondary)
                        } else if model.discussionCategories.isEmpty {
                            Text("게시판 카테고리가 없습니다.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.discussionCategories) { cat in
                                Button {
                                    Task { await model.openBoardCategory(cat) }
                                } label: {
                                    Label(cat.name, systemImage: "bubble.left.and.bubble.right")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("소통")
            .toolbar {
                if model.selectedCategory != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            model.clearBoardCategory()
                        } label: {
                            Label("게시판", systemImage: "chevron.backward")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { composing = true } label: { Image(systemName: "plus") }
                    }
                }
                RefreshButton(model: model)
            }
            .refreshable { await model.refreshHomeData(forceNetwork: true) }
            .task { await model.loadCrewSettings() }
            .sheet(isPresented: $composing) {
                ComposeSheet(title: "글 작성", titleLabel: "제목", bodyLabel: "본문") { t, b in
                    guard let cat = model.selectedCategory else { return }
                    Task { await model.createBoardPost(categoryId: cat.id, title: t, body: b) }
                }
            }
            .sheet(item: $editing) { post in
                ComposeSheet(
                    title: "글 수정",
                    titleLabel: "제목",
                    bodyLabel: "본문",
                    initialTitle: post.title,
                    initialBody: post.body,
                    showDelete: canMutate(
                        role: model.session?.teamRole ?? .none,
                        authorLogin: post.authorLogin,
                        currentLogin: model.currentLogin
                    ),
                    onSave: { t, b in Task { await model.updateBoardPost(post, title: t, body: b) } },
                    onDelete: { Task { await model.deleteBoardPost(post) } }
                )
            }
        }
    }
}

private struct DueOnField: View {
    @Binding var dueOn: String

    private var dateBinding: Binding<Date> {
        Binding(
            get: { parseDueOnDate(dueOn) ?? Date() },
            set: { dueOn = formatDueOnDate($0) }
        )
    }

    var body: some View {
        HStack {
            DatePicker("납기", selection: dateBinding, displayedComponents: .date)
                .datePickerStyle(.compact)
            if !dueOnInput(dueOn).isEmpty {
                Button("지우기") { dueOn = "" }
                    .font(.footnote)
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
            if !task.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(task.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
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
