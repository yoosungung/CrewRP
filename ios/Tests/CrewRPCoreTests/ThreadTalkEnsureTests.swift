import Foundation
import Testing
@testable import CrewRPCore

@Suite("ThreadTalk ensure")
struct ThreadTalkEnsureTests {
    @Test("creates talk issue when none and #1 missing")
    func createsWhenMissing() async throws {
        let transport = MockHTTPTransport()
        transport.handler = { request in
            let url = request.url!.absoluteString
            let method = request.httpMethod ?? "GET"
            if method == "GET", url.contains("state=open") {
                return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if method == "GET", url.hasSuffix("/issues/1") {
                return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            if method == "POST", url.hasSuffix("/issues") {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                #expect(body["title"] as? String == ThreadTalkClient.talkIssueTitle)
                return (
                    Data(#"{"number":7}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                )
            }
            throw GitHubAPIError.invalidResponse
        }
        let n = try await ThreadTalkClient(transport: transport).ensureTalkIssueNumber(owner: "a", repo: "b", token: "t")
        #expect(n == 7)
    }

    @Test("prefers existing titled talk issue")
    func prefersTitled() async throws {
        let transport = MockHTTPTransport()
        transport.handler = { request in
            let url = request.url!.absoluteString
            if url.contains("state=open") {
                let data = Data(#"[{"number":3,"title":"스레드 톡"},{"number":1,"title":"other"}]"#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            throw GitHubAPIError.invalidResponse
        }
        let n = try await ThreadTalkClient(transport: transport).ensureTalkIssueNumber(owner: "a", repo: "b", token: "t")
        #expect(n == 3)
    }
}
