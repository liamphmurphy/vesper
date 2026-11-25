import Foundation

/// Yields the lines of an event-stream response. Tests inject a stub.
public typealias SSEConnector = @Sendable (URLRequest) async throws -> AsyncThrowingStream<String, Error>

public enum SSE {
    /// The event type of one stream line: Vesper sends `data: {"type":"run.updated",…}`. Nil for
    /// comments, other fields and malformed frames.
    public static func eventType(fromLine line: String) -> String? {
        event(fromLine: line)?.type
    }

    /// The whole hint of one stream line: its type and the ids it names (strings only).
    public static func event(fromLine line: String) -> ServerEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        let ids = (object["ids"] as? [Any])?.compactMap { $0 as? String } ?? []
        return ServerEvent(type: type, ids: ids)
    }

    /// Builds an `SSEConnector` backed by a custom `URLSession` (e.g. a TLS-pinned companion session).
    public static func urlSessionConnector(session: URLSession) -> SSEConnector {
        { request in
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await line in bytes.lines { continuation.yield(line) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    static let urlSessionConnector: SSEConnector = { request in
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForResource = 24 * 3600
        let session = URLSession(configuration: config)
        return try await urlSessionConnector(session: session)(request)
    }
}

/// Server-sent events from GET /events. One stream for the app: `onEvent` gets every event type
/// (feed it to the InboxMonitor and RunMonitor) and `onServerEvent` the whole hint, ids included
/// (feed it to the QueryStore). Reconnects 5 s after the stream ends or fails.
@MainActor
public final class EventStream {
    public var onEvent: ((String) -> Void)?
    public var onServerEvent: ((ServerEvent) -> Void)?

    private let connector: SSEConnector
    private let reconnectDelay: Duration
    private var task: Task<Void, Never>?

    public init(reconnectDelay: Duration = .seconds(5), connector: SSEConnector? = nil) {
        self.connector = connector ?? SSE.urlSessionConnector
        self.reconnectDelay = reconnectDelay
    }

    public var isRunning: Bool { task != nil }

    public func start(client: APIClient) {
        stop()
        let connector = connector
        let delay = reconnectDelay
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let url = URL(string: "/events", relativeTo: client.baseURL)?.absoluteURL else { return }
                    var request = URLRequest(url: url, timeoutInterval: 3600)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    client.authorize(&request)
                    let lines = try await connector(request)
                    for try await line in lines {
                        if Task.isCancelled { return }
                        if let event = SSE.event(fromLine: line) {
                            await MainActor.run {
                                self?.onEvent?(event.type)
                                self?.onServerEvent?(event)
                            }
                        }
                    }
                } catch {
                    // Aborts and transient network drops: reconnect below.
                }
                if Task.isCancelled { return }
                try? await Task.sleep(for: delay)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
