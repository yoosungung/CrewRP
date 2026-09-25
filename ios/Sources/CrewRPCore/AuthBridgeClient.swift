import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthBridgeError.invalidResponse
        }
        return (data, http)
    }
}

public struct TokenExchangeResult: Sendable, Equatable, Codable {
    public let accessToken: String
    public let tokenType: String?
    public let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
    }
}

public enum AuthBridgeError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case githubError(String)
}

public struct AuthBridgeClient: Sendable {
    private let baseURL: URL
    private let transport: any HTTPTransport

    public init(baseURL: URL, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func exchange(
        code: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> TokenExchangeResult {
        var request = URLRequest(url: baseURL.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "code_verifier": codeVerifier,
            "redirect_uri": redirectURI,
        ])

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw AuthBridgeError.httpStatus(response.statusCode)
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? String {
            throw AuthBridgeError.githubError(error)
        }
        return try JSONDecoder().decode(TokenExchangeResult.self, from: data)
    }
}
