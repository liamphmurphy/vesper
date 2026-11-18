import Foundation

/// How the shell's own calls fail. 401 and 403 are `.unauthorized` (the session is gone).
public enum APIError: Error, Equatable, Sendable {
    case unauthorized
    case http(status: Int, message: String)
    case timeout
    case unreachable
    case invalidPath(String)
    case decoding(String)

    /// A sentence for the person (desktop/src/api.ts `apiErrorMessage`).
    public var userMessage: String {
        switch self {
        case .unauthorized: return "Vesper isn't signed in."
        case .http(_, let message): return message
        case .timeout: return "Vesper didn't answer in time."
        case .unreachable: return "Vesper isn't reachable."
        case .invalidPath(let p): return "refusing non-API path \(p)"
        case .decoding: return "Vesper sent something unexpected."
        }
    }
}

/// How requests reach the network. Tests inject a stub.
public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Calls the Vesper API with the shell's session cookie, for actions taken outside a page
/// (notification buttons, the menu bar, quick capture, sent files) and for the monitors. Paths are
/// built by the validated request builders and must start with `/api/v1/`.
public final class APIClient: Sendable {
    public let baseURL: URL
    public let sessionToken: String
    private let transport: HTTPTransport

    public init(baseURL: URL, sessionToken: String, transport: HTTPTransport? = nil) {
        self.baseURL = baseURL
        self.sessionToken = sessionToken
        self.transport = transport ?? APIClient.urlSessionTransport
    }

    public convenience init(session: StackSession, transport: HTTPTransport? = nil) {
        self.init(baseURL: session.baseURL, sessionToken: session.sessionToken, transport: transport)
    }

    static let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static let urlSessionTransport: HTTPTransport = { request in
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    // MARK: Requests

    public func makeURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/api/v1/"), !path.contains(".."),
              var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let parsed = URLComponents(string: path)
        else { throw APIError.invalidPath(path) }
        comps.percentEncodedPath = parsed.percentEncodedPath
        comps.percentEncodedQuery = parsed.percentEncodedQuery
        guard let url = comps.url else { throw APIError.invalidPath(path) }
        return url
    }

    /// Adds the cookie and standard headers to a request for `url` (also used by the SSE stream).
    public func authorize(_ request: inout URLRequest) {
        request.setValue("\(StackSession.cookieName)=\(sessionToken)", forHTTPHeaderField: "Cookie")
    }

    /// Sends one request and returns the body of a 2xx answer.
    @discardableResult
    public func request(
        _ method: String, _ path: String, body: Data? = nil, contentType: String? = nil, timeout: TimeInterval = 15
    ) async throws -> Data {
        var req = URLRequest(url: try makeURL(path), timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        authorize(&req)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(req)
        } catch let error as URLError where error.code == .timedOut {
            throw APIError.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.unreachable
        }
        if response.statusCode == 401 || response.statusCode == 403 { throw APIError.unauthorized }
        if !(200..<300).contains(response.statusCode) {
            throw APIError.http(status: response.statusCode, message: Self.errorMessage(status: response.statusCode, body: data))
        }
        return data
    }

    public func get<T: Decodable>(_ path: String, as type: T.Type = T.self, timeout: TimeInterval = 15) async throws -> T {
        let data = try await request("GET", path, timeout: timeout)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw APIError.decoding("\(error)") }
    }

    /// Sends a policy-built call (method, path and JSON body) and returns the parsed JSON answer (nil when empty).
    @discardableResult
    public func send(_ call: APICall, timeout: TimeInterval = 15) async throws -> Any? {
        let body = try JSONEncoder().encode(call.body)
        let data = try await request(call.method, call.path, body: body, timeout: timeout)
        return data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
    }

    /// POST /api/v1/chat-attachments: one file as multipart. Returns the new attachment id.
    public func uploadAttachment(fileName: String, mime: String, data: Data, timeout: TimeInterval = 120) async throws -> String {
        let (body, contentType) = Drop.buildMultipartBody(fileName: fileName, mime: mime, data: data)
        let answer = try await request("POST", "/api/v1/chat-attachments", body: body, contentType: contentType, timeout: timeout)
        guard let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any], let id = object["id"] as? String else {
            throw APIError.decoding("chat-attachments answer has no id")
        }
        return id
    }

    /// The API's error body is { code, message }; fall back to the status.
    public static func errorMessage(status: Int, body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty
        {
            return String(message.prefix(300))
        }
        switch status {
        case 401, 403: return "Vesper isn't signed in."
        case 404: return "It's no longer there."
        case 409: return "It has already changed; open Vesper to see it."
        default: return "The server answered \(status)."
        }
    }
}
