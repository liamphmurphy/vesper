import Foundation

// The native half of Vesper for Safari (docs/dev/safari-extension.md). The
// extension's JavaScript sends {op, ...} messages; this turns each into one
// call on the local Vesper API with the extension's token, or into a vesper://
// link to open. Only the operations below exist, so the extension can't reach
// any other API route. Used by the sandboxed extension (reads the connection
// file) and by the app (writes it).

/// Where the extension finds Vesper: the local server and the extension's token.
public struct SafariConnection: Codable, Equatable, Sendable {
    public var baseURL: String
    public var token: String

    public init(baseURL: String, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case token
    }

    /// The server URL, only when it's this Mac's own (http on a loopback address).
    public var loopbackURL: URL? {
        guard let url = URL(string: baseURL), url.scheme == "http", let host = url.host,
              ["127.0.0.1", "localhost", "::1"].contains(host), url.user == nil
        else { return nil }
        return url
    }
}

/// The connection file. The app writes it at launch; the extension's sandbox may read only its folder
/// (com.apple.security.temporary-exception.files.home-relative-path.read-only in VesperSafari.entitlements).
public enum SafariConnectionFile {
    public static let relativeDirectory = "Library/Application Support/Vesper Safari"
    public static let fileName = "connection.json"

    /// The person's real home. Inside the extension's sandbox NSHomeDirectory() is its container,
    /// so look it up from the user database instead.
    public static func realHome() -> URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public static func url(home: URL = realHome()) -> URL {
        home.appendingPathComponent(relativeDirectory, isDirectory: true).appendingPathComponent(fileName)
    }

    /// Writes the file readable by the person only (folder 0700, file 0600), replacing it atomically.
    public static func write(_ connection: SafariConnection, to url: URL = url()) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let data = try JSONEncoder().encode(connection)
        let temp = dir.appendingPathComponent(".\(fileName).\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
    }

    public static func read(from url: URL = url()) throws -> SafariConnection {
        try JSONDecoder().decode(SafariConnection.self, from: Data(contentsOf: url))
    }
}

/// One call on the extension's API.
public struct BridgeCall: Equatable, Sendable {
    public var method: String
    public var path: String
    public var body: Data?
}

public enum BridgeAction: Equatable, Sendable {
    case api(BridgeCall)
    case open(URL)
}

public enum BridgeError: Error, Equatable {
    case badMessage(String)
}

public enum SafariBridge {
    static let apiPrefix = "/api/v1/browser-extension/"

    private static func uuid(_ message: [String: Any], _ key: String) throws -> String {
        guard let raw = message[key] as? String, let id = UUID(uuidString: raw) else { throw BridgeError.badMessage("\(key) must be a UUID") }
        return id.uuidString.lowercased()
    }

    private static func body(_ message: [String: Any]) throws -> Data {
        guard let object = message["body"] as? [String: Any] else { throw BridgeError.badMessage("body must be an object") }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// The call (or link) for one message from the extension.
    public static func route(_ message: [String: Any]) throws -> BridgeAction {
        guard let op = message["op"] as? String else { throw BridgeError.badMessage("missing op") }
        func call(_ method: String, _ rest: String, _ body: Data? = nil) -> BridgeAction {
            .api(BridgeCall(method: method, path: apiPrefix + rest, body: body))
        }
        switch op {
        case "config": return call("GET", "config")
        case "share_start": return call("POST", "shares", try body(message))
        case "share_get":
            let share = try uuid(message, "share_id")
            return call("GET", "shares/" + share)
        case "snapshot":
            let share = try uuid(message, "share_id")
            return call("POST", "shares/" + share + "/snapshot", try body(message))
        case "share_stop":
            let share = try uuid(message, "share_id")
            return call("POST", "shares/" + share + "/stop", try body(message))
        case "ask": return call("POST", "ask", try body(message))
        case "clip": return call("POST", "clip", try body(message))
        case "never_add": return call("POST", "never-share", try body(message))
        case "never_remove":
            let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
            guard let host = message["host"] as? String, (1...253).contains(host.count), host.allSatisfy(allowed.contains) else {
                throw BridgeError.badMessage("host must be a lower-case host name")
            }
            return call("DELETE", "never-share/" + host)
        case "open_chat":
            let chat = try uuid(message, "chat_id")
            return .open(URL(string: "vesper://chat/" + chat)!)
        case "open_page":
            let page = try uuid(message, "page_id")
            return .open(URL(string: "vesper://page/" + page)!)
        default: throw BridgeError.badMessage("unknown op \(op)")
        }
    }

    /// The request for a call, with the extension's token.
    public static func request(_ call: BridgeCall, connection: SafariConnection) -> URLRequest? {
        guard let base = connection.loopbackURL, var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = call.path
        comps.query = nil
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = call.method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        if let body = call.body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    /// The reply the extension gets: {ok, status, body} or {ok: false, status, error}.
    public static func reply(data: Data?, response: URLResponse?, error: Error?) -> [String: Any] {
        guard error == nil, let http = response as? HTTPURLResponse else {
            return ["ok": false, "status": 0, "error": "Couldn't reach Vesper. Open the Vesper app and try again."]
        }
        var json: Any?
        if let data, !data.isEmpty { json = try? JSONSerialization.jsonObject(with: data) }
        if (200..<300).contains(http.statusCode) {
            return ["ok": true, "status": http.statusCode, "body": json ?? NSNull()]
        }
        var message = (json as? [String: Any])?["message"] as? String ?? "Vesper answered \(http.statusCode)."
        if http.statusCode == 401 { message = "Vesper refused the extension's key. Quit and reopen Vesper to renew it." }
        return ["ok": false, "status": http.statusCode, "error": message]
    }

    public typealias Transport = (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void

    public static let urlSessionTransport: Transport = { request, done in
        URLSession.shared.dataTask(with: request, completionHandler: done).resume()
    }

    /// Handles one message: routes it, then calls the API or opens a link, and always completes once.
    public static func handle(
        _ message: [String: Any],
        connection: () throws -> SafariConnection = { try SafariConnectionFile.read() },
        transport: Transport = urlSessionTransport,
        open: (URL) -> Bool,
        completion: @escaping ([String: Any]) -> Void
    ) {
        let action: BridgeAction
        do {
            action = try route(message)
        } catch BridgeError.badMessage(let why) {
            return completion(["ok": false, "status": 0, "error": "Vesper for Safari sent a bad request: \(why)."])
        } catch {
            return completion(["ok": false, "status": 0, "error": "\(error)"])
        }
        switch action {
        case .open(let url):
            completion(open(url) ? ["ok": true, "status": 0, "body": NSNull()] : ["ok": false, "status": 0, "error": "Couldn't open Vesper."])
        case .api(let call):
            guard let conn = try? connection(), let req = request(call, connection: conn) else {
                return completion(["ok": false, "status": 0, "error": "Vesper isn't running. Open the Vesper app and try again."])
            }
            transport(req) { data, response, error in completion(reply(data: data, response: response, error: error)) }
        }
    }
}
