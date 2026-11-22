import Foundation

public struct OwnerAuthStatus: Codable, Sendable, Equatable {
    public var claimed: Bool
    public var passwordSet: Bool
    public var signedIn: Bool

    public init(claimed: Bool, passwordSet: Bool, signedIn: Bool) {
        self.claimed = claimed
        self.passwordSet = passwordSet
        self.signedIn = signedIn
    }

    enum CodingKeys: String, CodingKey {
        case claimed
        case passwordSet = "password_set"
        case signedIn = "signed_in"
    }
}

public enum OwnerAuthField: String, Sendable, Equatable {
    case login
    case password
}

public enum OwnerCredentialsResult: Sendable, Equatable {
    case success(OwnerAuthStatus)
    case failure(message: String, field: OwnerAuthField?)
}

/// Calls `/api/v1/auth/*` (which sit outside the generated OpenAPI client because browsers call
/// them while signed out, and 400/401/429 responses return `{ message, field }` for the form).
public enum OwnerAuthAPI {
    public static func status(using client: APIClient, timeout: TimeInterval = 15) async throws -> OwnerAuthStatus {
        try await client.get("/api/v1/auth/status", as: OwnerAuthStatus.self, timeout: timeout)
    }

    public static func setup(login: String, password: String, using client: APIClient, timeout: TimeInterval = 15) async -> OwnerCredentialsResult {
        await submit(action: "setup", login: login, password: password, using: client, timeout: timeout)
    }

    public static func login(login: String, password: String, using client: APIClient, timeout: TimeInterval = 15) async -> OwnerCredentialsResult {
        await submit(action: "login", login: login, password: password, using: client, timeout: timeout)
    }

    private static func submit(
        action: String,
        login: String,
        password: String,
        using client: APIClient,
        timeout: TimeInterval
    ) async -> OwnerCredentialsResult {
        struct CredentialsBody: Encodable {
            let login: String
            let password: String
        }
        struct ErrorPayload: Decodable {
            let message: String?
            let field: String?
        }

        let url: URL
        do {
            url = try client.makeURL("/api/v1/auth/\(action)")
        } catch {
            return .failure(message: "Invalid auth path.", field: nil)
        }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        client.authorize(&req)
        do {
            req.httpBody = try JSONEncoder().encode(CredentialsBody(login: login, password: password))
        } catch {
            return .failure(message: "Couldn't encode credentials.", field: nil)
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await client.rawRequest(req)
        } catch {
            return .failure(message: "Couldn't reach Vesper. Is the API running?", field: nil)
        }

        if (200..<300).contains(response.statusCode) {
            if let status = try? JSONDecoder().decode(OwnerAuthStatus.self, from: data) {
                return .success(status)
            }
            return .success(OwnerAuthStatus(claimed: true, passwordSet: true, signedIn: true))
        }

        let err = try? JSONDecoder().decode(ErrorPayload.self, from: data)
        let field = err?.field.flatMap(OwnerAuthField.init(rawValue:))
        let msg = err?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(
            message: (msg?.isEmpty == false ? msg! : "Something went wrong (\(response.statusCode))."),
            field: field
        )
    }
}
