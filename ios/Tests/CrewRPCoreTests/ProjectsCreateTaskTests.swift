import Foundation
import Testing
@testable import CrewRPCore

@Suite("ProjectsClient createTask")
struct ProjectsCreateTaskTests {
    @Test("closes issue when project meta is missing")
    func closesIssueWhenProjectMissing() async throws {
        final class Flag: @unchecked Sendable { var value = false }
        let closed = Flag()
        let transport = MockHTTPTransport()
        transport.handler = { request in
            let url = request.url!.absoluteString
            let method = request.httpMethod ?? "GET"
            if method == "POST", url.hasSuffix("/issues") {
                return (
                    Data(#"{"number":42,"node_id":"I_1"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                )
            }
            if method == "POST", url.hasSuffix("/graphql") {
                return (
                    Data(#"{"data":{"organization":{"projectV2":null},"user":{"projectV2":null}}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            if method == "PATCH", url.hasSuffix("/issues/42") {
                closed.value = true
                return (
                    Data(#"{"state":"closed"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            throw GitHubAPIError.invalidResponse
        }
        let client = ProjectsClient(transport: transport)
        await #expect(throws: GitHubAPIError.self) {
            try await client.createTask(
                owner: "a", repo: "b", title: "t", body: "", projectNumber: 1, token: "tok", dueOn: nil
            )
        }
        #expect(closed.value)
    }

    @Test("loadFieldMeta and listTasks recognize GitHub Due date field")
    func dueDateFieldName() async throws {
        let transport = MockHTTPTransport()
        transport.handler = { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            if body.contains("fields(first") {
                return (
                    Data(#"{"data":{"user":{"projectV2":{"id":"P1","fields":{"nodes":[{"id":"S1","name":"Status","options":[{"id":"o1","name":"접수"}]},{"id":"D1","name":"Due date"}]}}}}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            return (
                Data(#"{"data":{"user":{"projectV2":{"items":{"nodes":[{"id":"t1","content":{"title":"보고서"},"fieldValues":{"nodes":[{"name":"접수","field":{"name":"Status"}},{"date":"2026-10-07","field":{"name":"Due date"}}]}}]}}}}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let client = ProjectsClient(transport: transport)
        let meta = try await client.loadFieldMeta(owner: "yoosungung", projectNumber: 1, token: "tok")
        #expect(meta?.dueFieldId == "D1")
        let cards = try await client.listTasks(org: "yoosungung", projectNumber: 1, token: "tok")
        #expect(cards.count == 1)
        #expect(cards.first?.dueOn == "2026-10-07")
    }

    @Test("resolveProjectNumber falls back to listed project")
    func resolveFallsBack() async throws {
        let transport = MockHTTPTransport()
        transport.handler = { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            if body.contains("projectV2(number") {
                return (
                    Data(#"{"data":{"organization":null,"user":{"projectV2":null}},"errors":[{"type":"NOT_FOUND"}]}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            if body.contains("projectsV2") {
                return (
                    Data(#"{"data":{"organization":null,"user":{"projectsV2":{"nodes":[{"number":2}]}}},"errors":[{"type":"NOT_FOUND"}]}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            throw GitHubAPIError.invalidResponse
        }
        let n = try await ProjectsClient(transport: transport)
            .resolveProjectNumber(owner: "alice", preferred: 1, token: "tok")
        #expect(n == 2)
    }
}
