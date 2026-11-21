import Foundation

/// The namespace of the generated API types and request builders (`Generated/API+*.gen.swift`,
/// from api/openapi.yaml by server/cmd/gen-swift-api). Generated names live here so a schema such as
/// `InboxItem` can't collide with the shell's own models.
public enum API {}

// MARK: Values

/// A string enum from the spec. An open set: a value a newer server sends still decodes, and
/// compares unequal to every known case.
public protocol APIStringEnum: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible, APIQueryValue
where RawValue == String {}

extension APIStringEnum {
    public var description: String { rawValue }
    public var apiQueryValues: [String] { [rawValue] }
}

/// An optional member the spec marks nullable: absent (`nil`), explicitly `null`, or a value. The
/// server tells "leave it" (absent) from "clear it" (null) in PATCH bodies.
public enum APINullable<Wrapped> {
    case null
    case value(Wrapped)

    public var value: Wrapped? {
        if case .value(let v) = self { return v }
        return nil
    }
}

extension APINullable: Sendable where Wrapped: Sendable {}
extension APINullable: Equatable where Wrapped: Equatable {}

extension APINullable: Codable where Wrapped: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = c.decodeNil() ? .null : .value(try c.decode(Wrapped.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .value(let v): try c.encode(v)
        }
    }
}

extension KeyedDecodingContainer {
    /// Decodes a nullable optional member: nil when the key is missing, `.null` for JSON null.
    public func decodeNullable<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> APINullable<T>? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) { return .null }
        return .value(try decode(T.self, forKey: key))
    }
}

/// Free-form JSON (`additionalProperties: true`, untyped members). Integers stay exact.
public enum JSONValue: Sendable, Equatable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// The answer of an operation with no body (204, or 2xx without content).
public struct APIEmpty: Sendable, Equatable, Codable {
    public init() {}
}

// MARK: Requests

/// How an operation's answer is decoded.
public struct APIDecoding<Response: Sendable>: Sendable {
    public let decode: @Sendable (Data) throws -> Response
    public init(_ decode: @escaping @Sendable (Data) throws -> Response) { self.decode = decode }
}

extension APIDecoding where Response: Decodable {
    public static var json: APIDecoding {
        APIDecoding { data in
            do { return try JSONDecoder().decode(Response.self, from: data) }
            catch { throw APIError.decoding(String(describing: error)) }
        }
    }
}

extension APIDecoding where Response == APIEmpty {
    public static var empty: APIDecoding { APIDecoding { _ in APIEmpty() } }
}

extension APIDecoding where Response == Data {
    public static var raw: APIDecoding { APIDecoding { $0 } }
}

/// A request body. JSON is encoded when the request is sent, so building a request never throws.
public enum APIRequestBody: Sendable {
    case encoded(@Sendable () throws -> Data)
    case multipart(APIMultipartForm)
    case raw(Data, contentType: String)

    public static func json<T: Encodable & Sendable>(_ value: T) -> APIRequestBody {
        .encoded { try JSONEncoder().encode(value) }
    }

    /// The bytes to send and their Content-Type.
    public func encode() throws -> (Data, String) {
        switch self {
        case .encoded(let make): return (try make(), "application/json")
        case .multipart(let form): return form.encode()
        case .raw(let data, let contentType): return (data, contentType)
        }
    }
}

/// One API operation, built by a generated `API.<operationId>(…)` function: everything needed to
/// send it, to decode its answer, and to cache it in `QueryStore` under `key`.
public struct APIRequest<Response: Sendable>: Sendable {
    public let method: String
    /// The spec's path template, e.g. `/tickets/{key}`.
    public let template: String
    /// The escaped path, starting with `/api/v1/`.
    public let path: String
    public let query: [URLQueryItem]
    public let headers: [String: String]
    public let body: APIRequestBody?
    public let decoding: APIDecoding<Response>

    public init(
        method: String, template: String, path: String, query: [URLQueryItem] = [], headers: [String: String] = [:],
        body: APIRequestBody? = nil, decode: APIDecoding<Response>
    ) {
        self.method = method
        self.template = template
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.decoding = decode
    }

    /// `path?query`, with query values escaped strictly (a `+` reaches Go as `+`, not a space).
    public var pathAndQuery: String {
        let encoded = APIQuery.encode(query)
        return encoded.isEmpty ? path : path + "?" + encoded
    }

    public var key: QueryKey { QueryKey(path: path, template: template, query: APIQuery.encode(query)) }
}

/// Identifies a cached query: its path segments (after `/api/v1`) and query string. `resources` are
/// the template's literal segments (`tickets`, `runs`, `board`…), which server change hints name.
public struct QueryKey: Hashable, Sendable, CustomStringConvertible {
    public let segments: [String]
    public let resources: Set<String>
    public let query: String

    public init(path: String, template: String, query: String = "") {
        segments = QueryKey.split(path)
        resources = Set(QueryKey.split(template).filter { !$0.hasPrefix("{") })
        self.query = query
    }

    /// True when this key's path starts with `prefix` (unescaped segments).
    public func hasPrefix(_ prefix: [String]) -> Bool {
        guard prefix.count <= segments.count else { return false }
        return zip(prefix, segments).allSatisfy { $0 == ($1.removingPercentEncoding ?? $1) }
    }

    public var description: String { "/" + segments.joined(separator: "/") + (query.isEmpty ? "" : "?" + query) }

    private static func split(_ path: String) -> [String] {
        var parts = path.split(separator: "/").map(String.init)
        if parts.starts(with: ["api", "v1"]) { parts.removeFirst(2) }
        return parts
    }
}

// MARK: Query, path and header values

/// A value that can go in a query string, path segment or header.
public protocol APIQueryValue: Sendable {
    var apiQueryValues: [String] { get }
}

extension String: APIQueryValue { public var apiQueryValues: [String] { [self] } }
extension Int: APIQueryValue { public var apiQueryValues: [String] { [String(self)] } }
extension Double: APIQueryValue { public var apiQueryValues: [String] { [String(self)] } }
extension Bool: APIQueryValue { public var apiQueryValues: [String] { [self ? "true" : "false"] } }
extension Array: APIQueryValue where Element: APIQueryValue {
    public var apiQueryValues: [String] { flatMap(\.apiQueryValues) }
}

public enum APIQuery {
    /// Unreserved characters only (RFC 3986), so `+`, `&` and `=` in values survive.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Adds `name=value` (once per element for arrays); nil adds nothing.
    public static func append<V: APIQueryValue>(_ query: inout [URLQueryItem], _ name: String, _ value: V?) {
        guard let value else { return }
        for v in value.apiQueryValues { query.append(URLQueryItem(name: name, value: v)) }
    }

    public static func set<V: APIQueryValue>(_ headers: inout [String: String], _ name: String, _ value: V?) {
        guard let value else { return }
        headers[name] = value.apiQueryValues.joined(separator: ",")
    }

    public static func encode(_ items: [URLQueryItem]) -> String {
        items.map { item in
            let name = item.name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? item.name
            guard let value = item.value else { return name }
            return name + "=" + (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)
        }.joined(separator: "&")
    }
}

public enum APIPath {
    /// One path segment: everything but unreserved characters is escaped, so a `/` in a value
    /// can't change the route.
    public static func escape<V: APIQueryValue>(_ value: V) -> String {
        let raw = value.apiQueryValues.joined(separator: ",")
        return raw.addingPercentEncoding(withAllowedCharacters: APIQuery.unreserved) ?? raw
    }
}

// MARK: Multipart

/// A multipart/form-data body: text fields and files, in order.
public struct APIMultipartForm: Sendable, Equatable {
    public struct Part: Sendable, Equatable {
        public var name: String
        public var filename: String?
        public var contentType: String?
        public var data: Data
    }

    public var parts: [Part]
    public var boundary: String

    public init(parts: [Part] = [], boundary: String = "----vesper\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))") {
        self.parts = parts
        self.boundary = boundary
    }

    public mutating func addField(_ name: String, _ value: String) {
        parts.append(Part(name: name, filename: nil, contentType: nil, data: Data(value.utf8)))
    }

    public mutating func addFile(_ name: String, filename: String, contentType: String, data: Data) {
        parts.append(Part(name: name, filename: filename, contentType: contentType, data: data))
    }

    public func encode() -> (Data, String) {
        var body = Data()
        for part in parts {
            var head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.quoted(part.name))\""
            if let filename = part.filename { head += "; filename=\"\(Self.quoted(filename))\"" }
            head += "\r\n"
            if let contentType = part.contentType { head += "Content-Type: \(contentType)\r\n" }
            head += "\r\n"
            body.append(Data(head.utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    /// Quotes and line breaks would end the header early.
    private static func quoted(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }
}

// MARK: Sending

extension APIClient {
    /// Sends a generated request and decodes its answer.
    public func send<Response>(_ request: APIRequest<Response>, timeout: TimeInterval = 15) async throws -> Response {
        var body: Data?
        var contentType: String?
        if let requestBody = request.body {
            do { (body, contentType) = try requestBody.encode() }
            catch { throw APIError.encoding(String(describing: error)) }
        }
        let data = try await self.request(
            request.method, request.pathAndQuery, body: body, contentType: contentType, headers: request.headers, timeout: timeout
        )
        return try request.decoding.decode(data)
    }
}
