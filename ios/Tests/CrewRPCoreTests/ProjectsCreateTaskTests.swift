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
        final class Box: @unchecked Sendable { var fieldQuery = "" }
        let box = Box()
        transport.handler = { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            if body.contains("fields(first") {
                box.fieldQuery = body
                return (
                    Data(#"{"data":{"user":{"projectV2":{"id":"P1","fields":{"nodes":[{"id":"S1","name":"Status","options":[{"id":"o1","name":"접수"}]},{"id":"D1","name":"Due date"}]}}}}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            return (
                Data(#"{"data":{"user":{"projectV2":{"items":{"nodes":[{"id":"t1","content":{"title":"보고서","body":"세부"},"fieldValues":{"nodes":[{"name":"접수","field":{"name":"Status"}},{"date":"2026-10-07","field":{"name":"Due date"}}]}}]}}}}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let client = ProjectsClient(transport: transport)
        let meta = try await client.loadFieldMeta(owner: "yoosungung", projectNumber: 1, token: "tok")
        #expect(meta?.dueFieldId == "D1")
        #expect(box.fieldQuery.contains("fields(first:50)"))
        #expect(box.fieldQuery.contains("ProjectV2FieldCommon"))
        let cards = try await client.listTasks(org: "yoosungung", projectNumber: 1, token: "tok")
        #expect(cards.count == 1)
        #expect(cards.first?.dueOn == "2026-10-07")
        #expect(cards.first?.body == "세부")
    }

    @Test("loadFieldMeta uses DATE dataType when name is not Due")
    func dueFieldFromDateDataType() async throws {
        let transport = MockHTTPTransport()
        transport.handler = { _ in
            (
                Data(#"{"data":{"user":{"projectV2":{"id":"P1","fields":{"nodes":[{"id":"S1","name":"Status","options":[{"id":"o1","name":"접수"}]},{"id":"D1","name":"마감일","dataType":"DATE"}]}}}}}"#.utf8),
                HTTPURLResponse(url: URL(string: "https://api.github.com/graphql")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let meta = try await ProjectsClient(transport: transport).loadFieldMeta(owner: "yoosungung", projectNumber: 1, token: "tok")
        #expect(meta?.dueFieldId == "D1")
    }

    @Test("ensureDueDateField creates DATE field when missing")
    func ensureCreatesDueDateField() async throws {
        let transport = MockHTTPTransport()
        final class Box: @unchecked Sendable { var calls = 0; var created = false }
        let box = Box()
        transport.handler = { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            box.calls += 1
            if body.contains("createProjectV2Field") {
                box.created = true
                return (
                    Data(#"{"data":{"createProjectV2Field":{"projectV2Field":{"id":"D1","name":"Due date"}}}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            if box.created {
                return (
                    Data(#"{"data":{"user":{"projectV2":{"id":"P1","fields":{"nodes":[{"id":"S1","name":"Status","options":[{"id":"o1","name":"접수"}]},{"id":"D1","name":"Due date","dataType":"DATE"}]}}}}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            return (
                Data(#"{"data":{"user":{"projectV2":{"id":"P1","fields":{"nodes":[{"id":"S1","name":"Status","options":[{"id":"o1","name":"접수"}]}]}}}}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let client = ProjectsClient(transport: transport)
        let before = try await client.loadFieldMeta(owner: "yoosungung", projectNumber: 1, token: "tok")
        #expect(before?.dueFieldId == nil)
        let after = try await client.ensureDueDateField(meta: before!, owner: "yoosungung", projectNumber: 1, token: "tok")
        #expect(after.dueFieldId == "D1")
        #expect(box.created)
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
