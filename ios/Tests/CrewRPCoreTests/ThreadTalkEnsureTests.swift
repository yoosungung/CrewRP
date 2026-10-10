import Foundation
import Testing
@testable import CrewRPCore

@Suite("ThreadTalk comments")
struct ThreadTalkCommentsTests {
    @Test("listIssueComments parses numeric ids")
    func listComments() async throws {
        let transport = MockHTTPTransport()
        transport.handler = { request in
            #expect(request.url!.path.hasSuffix("/issues/7/comments"))
            let body = Data(#"""
            [{"id":99,"body":"ok","user":{"login":"ada"}}]
            """#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let items = try await ThreadTalkClient(transport: transport)
            .listIssueComments(owner: "a", repo: "b", issueNumber: 7, token: "t")
        #expect(items == [ThreadMessage(id: "99", body: "ok", author: "ada")])
    }

    @Test("postComment sends body")
    func postComment() async throws {
        let transport = MockHTTPTransport()
        transport.handler = { request in
            #expect(request.httpMethod == "POST")
            let raw = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(raw.contains("hello"))
            let body = Data(#"""
            {"id":1,"body":"hello","user":{"login":"ada"}}
            """#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        }
        let msg = try await ThreadTalkClient(transport: transport)
            .postComment(owner: "a", repo: "b", issueNumber: 7, body: "hello", token: "t")
        #expect(msg.body == "hello")
        #expect(msg.id == "1")
    }
}

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
