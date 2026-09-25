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
    @Published var organizations: [Organization] = []
    @Published var session: Session?
    @Published var errorMessage: String?
    @Published var selectedTab = 0
    @Published var tasks: [TaskCard] = []
    @Published var notices: [Notice] = []
    @Published var docPreview: String = ""
    @Published var threadMessages: [ThreadMessage] = []

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
                if let error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                guard let callback else { return }
                do {
                    self.organizations = try await self.flow.completeLogin(callbackURL: callback)
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = AuthPresenter.shared
        webSession = session
        session.start()
    }

    func select(_ org: Organization) {
        Task {
            do {
                session = try await flow.selectOrganization(org)
                await refreshHomeData()
            } catch {
                errorMessage = error.localizedDescription
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

        do {
            let projects = ProjectsClient(transport: transport)
            tasks = try await projects.sortedByDueDate(
                projects.listTasks(org: session.org, projectNumber: projectNumber, token: token)
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        do {
            notices = try await DiscussionsClient(transport: transport)
                .listNotices(owner: owner, repo: repo, token: token)
        } catch {
            errorMessage = error.localizedDescription
        }

        do {
            let rest = ETagRESTClient(transport: transport, cache: cache)
            docPreview = try await DocsClient(rest: rest)
                .fetchMarkdown(owner: owner, repo: repo, path: "docs/README.md", token: token)
                .content
        } catch {
            docPreview = "자료를 불러오지 못했습니다."
        }

        do {
            threadMessages = try await ThreadTalkClient(transport: transport)
                .listIssueComments(owner: owner, repo: repo, issueNumber: 1, token: token)
        } catch {
            threadMessages = []
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

struct RootView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        Group {
            if model.session != nil {
                TabView(selection: $model.selectedTab) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("홈").font(.largeTitle)
                        Text("크루: \(model.session!.org)")
                        Text("역할: \(model.session!.teamRole.rawValue)")
                        Text("고정 공지").font(.headline)
                        ForEach(model.notices.prefix(3), id: \.id) { notice in
                            Text(notice.title).font(.subheadline)
                        }
                    }
                    .padding()
                    .tabItem { Text("홈") }
                    .tag(0)

                    List(model.tasks, id: \.id) { task in
                        VStack(alignment: .leading) {
                            Text(task.title)
                            Text("\(task.status) · \(task.dueOn ?? "-")").font(.caption)
                        }
                    }
                    .navigationTitle("할 일")
                    .tabItem { Text("할 일") }
                    .tag(1)

                    ScrollView {
                        Text(model.docPreview).frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                    .tabItem { Text("자료실") }
                    .tag(2)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("소통").font(.title)
                        List(model.threadMessages, id: \.id) { msg in
                            VStack(alignment: .leading) {
                                Text(msg.author).font(.caption)
                                Text(msg.body)
                            }
                        }
                        Button("바로 대화 (Discord)") { model.openDiscord() }
                        Button("알림 기기 등록") {
                            Task { await model.registerPushDevice() }
                        }
                        Button("새로고침") {
                            Task { await model.refreshHomeData() }
                        }
                    }
                    .padding()
                    .tabItem { Text("소통") }
                    .tag(3)
                }
                .task { await model.refreshHomeData() }
            } else if !model.organizations.isEmpty {
                List(model.organizations, id: \.id) { org in
                    Button(org.login) { model.select(org) }
                }
                .navigationTitle("크루 선택")
            } else {
                VStack(spacing: 16) {
                    Text("CrewRP").font(.largeTitle)
                    Text("계정으로 로그인")
                    Button("로그인") { model.login() }
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }
                .padding()
            }
        }
    }
}
