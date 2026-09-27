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
    @Published var threadMessages: [ThreadMessage] = []
    @Published var isLoading = false
    @Published var tasksFailed = false
    @Published var noticesFailed = false
    @Published var docFailed = false
    @Published var threadsFailed = false
    private var didRegisterPush = false

    private let flow: AuthFlow
    private let cache: CacheStore
    private let tokens: KeychainTokenStore
    private let transport = URLSessionTransport()
    private var webSession: ASWebAuthenticationSession?

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
        guard let session, let token = try? tokens.loadAccessToken() else { return }
        let parts = session.repo.split(separator: "/")
        guard parts.count == 2 else { return }
        let owner = String(parts[0])
        let repo = String(parts[1])
        let projectNumber = Int(Bundle.main.object(forInfoDictionaryKey: "ProjectNumber") as? String ?? "1") ?? 1
        isLoading = true
        defer { isLoading = false }

        do {
            let projects = ProjectsClient(transport: transport)
            tasks = try await projects.sortedByDueDate(
                projects.listTasks(org: session.org, projectNumber: projectNumber, token: token)
            )
            tasksFailed = false
        } catch {
            tasksFailed = true
        }

        do {
            notices = try await DiscussionsClient(transport: transport)
                .listNotices(owner: owner, repo: repo, token: token)
            noticesFailed = false
        } catch {
            noticesFailed = true
        }

        do {
            let rest = ETagRESTClient(transport: transport, cache: cache)
            docPreview = try await DocsClient(rest: rest)
                .fetchMarkdown(owner: owner, repo: repo, path: "docs/README.md", token: token)
                .content
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

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.tasks.isEmpty && model.notices.isEmpty {
                    ProgressView()
                } else if homeQuiet && (model.tasksFailed || model.noticesFailed) {
                    FailedHint { await model.refreshHomeData() }
                } else if homeQuiet {
                    EmptyHint(title: "아직 소식이 없습니다", message: "공지와 할 일이 생기면 홈에 모입니다.")
                } else {
                    List {
                        if let session = model.session {
                            Section {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.org).font(.headline)
                                    Text("\(crewDisplayName(session.repo)) · \(session.teamRole.label)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        if model.tasksFailed || model.noticesFailed {
                            Section { Text("최신 내용을 불러오지 못했습니다").foregroundStyle(.red) }
                        }
                        if !sections.today.isEmpty {
                            Section("오늘 할 일") {
                                ForEach(sections.today, id: \.id) { TaskRow(task: $0) }
                            }
                        }
                        if !sections.notices.isEmpty {
                            Section("고정 공지") {
                                ForEach(sections.notices, id: \.id) { notice in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(notice.title).font(.headline)
                                        if !notice.body.isEmpty {
                                            Text(notice.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                        }
                                    }
                                }
                            }
                        }
                        if !sections.upcoming.isEmpty {
                            Section("다가오는 할 일") {
                                ForEach(sections.upcoming, id: \.id) { TaskRow(task: $0) }
                            }
                        }
                    }
                }
            }
            .navigationTitle(model.session.map { crewDisplayName($0.repo) } ?? "홈")
            .toolbar { RefreshButton(model: model) }
            .refreshable { await model.refreshHomeData() }
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

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.tasks.isEmpty && !model.tasksFailed {
                    ProgressView()
                } else if model.tasksFailed && model.tasks.isEmpty {
                    FailedHint { await model.refreshHomeData() }
                } else if model.tasks.isEmpty {
                    EmptyHint(title: "아직 할 일이 없습니다", message: "접수된 일이 생기면 칸반에 올라옵니다.")
                } else {
                    VStack(spacing: 0) {
                        Picker("보기", selection: $mode) {
                            Text("칸반").tag(0)
                            Text("마감일").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding()
                        if mode == 0 {
                            KanbanBoard(tasks: model.tasks)
                        } else {
                            List(model.tasks, id: \.id) { TaskRow(task: $0) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("할 일")
            .toolbar { RefreshButton(model: model) }
            .refreshable { await model.refreshHomeData() }
        }
    }
}

private struct KanbanBoard: View {
    let tasks: [TaskCard]

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
                        if laneTasks.isEmpty {
                            Text("없음").font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(laneTasks, id: \.id) { TaskRow(task: $0) }
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

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.docPreview.isEmpty && !model.docFailed {
                    ProgressView()
                } else if model.docFailed && model.docPreview.isEmpty {
                    FailedHint { await model.refreshHomeData() }
                } else if docBlocks(model.docPreview).isEmpty {
                    EmptyHint(title: "자료실이 비어 있습니다", message: "정관과 규정이 올라오면 여기에 보입니다.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if model.docFailed {
                                Text("최신 내용을 불러오지 못했습니다").font(.footnote).foregroundStyle(.red)
                            }
                            ForEach(Array(docBlocks(model.docPreview).enumerated()), id: \.offset) { _, block in
                                switch block {
                                case .heading(let text):
                                    Text(text).font(.title2.bold()).padding(.top, 8)
                                case .bullet(let text):
                                    Text("·  \(text)")
                                case .paragraph(let text):
                                    Text(text)
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
            .toolbar { RefreshButton(model: model) }
            .refreshable { await model.refreshHomeData() }
        }
    }
}

private struct TalkTab: View {
    @ObservedObject var model: AppModel

    private var discordReady: Bool {
        let server = Bundle.main.object(forInfoDictionaryKey: "DiscordServerID") as? String ?? ""
        let channel = Bundle.main.object(forInfoDictionaryKey: "DiscordChannelID") as? String ?? ""
        return discordConfigured(serverId: server, channelId: channel)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if model.isLoading && model.threadMessages.isEmpty && !model.threadsFailed {
                        ProgressView()
                    } else if model.threadsFailed && model.threadMessages.isEmpty {
                        FailedHint { await model.refreshHomeData() }
                    } else if model.threadMessages.isEmpty {
                        EmptyHint(title: "스레드 톡이 없습니다", message: "공지와 할 일에 남긴 이야기가 여기에 모입니다.")
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
                                    }
                                }
                            }
                            .padding(16)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if discordReady {
                    VStack(spacing: 6) {
                        Button("바로 대화") { model.openDiscord() }
                            .buttonStyle(.borderedProminent)
                            .tint(.crewInk)
                            .controlSize(.large)
                        Text("음성과 잡담은 Discord에서 이어집니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("소통")
            .toolbar { RefreshButton(model: model) }
            .refreshable { await model.refreshHomeData() }
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
