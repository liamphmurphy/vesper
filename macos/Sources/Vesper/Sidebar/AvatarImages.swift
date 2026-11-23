import AppKit
import VesperCore

/// Persona and agent pictures for the native sidebar. The API serves them behind the session
/// cookie, so they're fetched with it, only from the Vesper origin (never another host), and
/// cached for the life of the app.
@MainActor
final class AvatarImages {
    static let shared = AvatarImages()

    /// Set by AppModel whenever the connection changes.
    var connection: Connection? {
        didSet { if connection != oldValue { cache.removeAll() } }
    }

    private var cache: [URL: NSImage] = [:]
    private var failed: Set<URL> = []
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private static let maxBytes = 5 * 1024 * 1024

    func image(for raw: String) async -> NSImage? {
        guard let conn = connection,
              let url = URL(string: raw, relativeTo: conn.baseURL)?.absoluteURL,
              BridgeOrigin.matches(url: url, base: conn.baseURL) else { return nil }
        if let hit = cache[url] { return hit }
        if failed.contains(url) { return nil }
        if let running = inFlight[url] { return await running.value }
        let task = Task<NSImage?, Never> {
            guard let data = await Self.fetch(url, conn: conn, maxBytes: Self.maxBytes, timeout: 10) else { return nil }
            return NSImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache[url] = image } else { failed.insert(url) }
        return image
    }

    /// A persona state loop's bytes (an Animated WebP of a few MB), fetched the same way as
    /// pictures but not cached here: callers keep the decoded frames instead.
    func loopData(for raw: String) async -> Data? {
        guard let conn = connection,
              let url = URL(string: raw, relativeTo: conn.baseURL)?.absoluteURL,
              BridgeOrigin.matches(url: url, base: conn.baseURL) else { return nil }
        return await Self.fetch(url, conn: conn, maxBytes: Self.maxLoopBytes, timeout: 30)
    }

    /// A reply's speech (WAV) and how many words it speaks, from the X-Speech-Words header.
    func speech(for raw: String) async -> (data: Data, words: Int)? {
        guard let conn = connection,
              let url = URL(string: raw, relativeTo: conn.baseURL)?.absoluteURL,
              BridgeOrigin.matches(url: url, base: conn.baseURL) else { return nil }
        guard let (data, http) = await Self.fetchResponse(url, conn: conn, maxBytes: Self.maxLoopBytes, timeout: 60, type: "audio/") else { return nil }
        return (data, Int(http.value(forHTTPHeaderField: "X-Speech-Words") ?? "") ?? 0)
    }

    /// Streams raw 16-bit mono PCM chunks from `/speech/stream` as Gemini emits them.
    struct SpeechStream: Sendable {
        let chunks: AsyncStream<Data>
        let words: Int
        let sampleRate: Int
        let cancel: @Sendable () -> Void
    }

    /// What asking for a reply's speech came to.
    enum SpeechStreamOutcome: Sendable {
        case stream(SpeechStream)
        /// The speech provider is out of quota or rate limited (HTTP 429); the message says which
        /// limit and when it lifts, for the person to read.
        case limited(message: String)
        /// No speech for any other reason (voice off, nothing to say, offline, a server error).
        case unavailable
    }

    func speechStream(for raw: String) async -> SpeechStreamOutcome {
        guard let conn = connection,
              let url = URL(string: raw, relativeTo: conn.baseURL)?.absoluteURL,
              BridgeOrigin.matches(url: url, base: conn.baseURL) else { return .unavailable }
        return await Self.openPCMStream(url, conn: conn, timeout: 60)
    }

    /// A 10s loop is budgeted at 14 MB on the server; this leaves headroom.
    private static let maxLoopBytes = 20 * 1024 * 1024

    private nonisolated static func openPCMStream(_ url: URL, conn: Connection, timeout: TimeInterval) async -> SpeechStreamOutcome {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue("\(StackSession.cookieName)=\(conn.sessionToken)", forHTTPHeaderField: "Cookie")

        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        let delegate = PCMStreamDelegate(continuation: continuation)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        delegate.bind(session: session, task: task)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (outcomeCont: CheckedContinuation<SpeechStreamOutcome, Never>) in
                delegate.onOutcome = { outcome in
                    switch outcome {
                    case let .audio(http):
                        let words = Int(http.value(forHTTPHeaderField: "X-Speech-Words") ?? "") ?? 0
                        let rate = Int(http.value(forHTTPHeaderField: "X-Speech-Sample-Rate") ?? "") ?? 24_000
                        outcomeCont.resume(returning: .stream(SpeechStream(
                            chunks: chunks,
                            words: words,
                            sampleRate: rate,
                            cancel: {
                                task.cancel()
                                session.invalidateAndCancel()
                                continuation.finish()
                            }
                        )))
                    case let .limited(body):
                        outcomeCont.resume(returning: .limited(message: SpeechLimitMessage.from(body)))
                    case .unavailable:
                        task.cancel()
                        session.invalidateAndCancel()
                        continuation.finish()
                        outcomeCont.resume(returning: .unavailable)
                    }
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
            session.invalidateAndCancel()
            continuation.finish()
        }
    }

    private nonisolated static func fetch(_ url: URL, conn: Connection, maxBytes: Int, timeout: TimeInterval) async -> Data? {
        await fetchResponse(url, conn: conn, maxBytes: maxBytes, timeout: timeout, type: "image/")?.data
    }

    private nonisolated static func fetchResponse(_ url: URL, conn: Connection, maxBytes: Int, timeout: TimeInterval, type: String) async -> (data: Data, response: HTTPURLResponse)? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue("\(StackSession.cookieName)=\(conn.sessionToken)", forHTTPHeaderField: "Cookie")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix(type),
              data.count <= maxBytes
        else { return nil }
        return (data, http)
    }
}

private final class PCMStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome {
        case audio(HTTPURLResponse)
        case limited(Data)
        case unavailable
    }

    /// A 429's JSON error is small; anything past this isn't a message worth reading.
    private static let maxErrorBytes = 16 * 1024

    private let lock = NSLock()
    private let continuation: AsyncStream<Data>.Continuation
    private weak var session: URLSession?
    private weak var task: URLSessionDataTask?
    private var delivered = false
    /// Set while reading a 429's body, which is delivered once the response completes.
    private var limitedBody: Data?
    var onOutcome: ((Outcome) -> Void)?

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    func bind(session: URLSession, task: URLSessionDataTask) {
        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()
    }

    private func deliver(_ outcome: Outcome) {
        lock.lock()
        guard !delivered else {
            lock.unlock()
            return
        }
        delivered = true
        let cb = onOutcome
        onOutcome = nil
        lock.unlock()
        cb?(outcome)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        if let http, http.statusCode == 200,
           (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("audio/l16") {
            deliver(.audio(http))
            completionHandler(.allow)
        } else if http?.statusCode == 429 {
            // Read the error body: it says which limit ran out and when it lifts.
            lock.lock()
            limitedBody = Data()
            lock.unlock()
            completionHandler(.allow)
        } else {
            deliver(.unavailable)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        if var body = limitedBody {
            body.append(data.prefix(max(0, Self.maxErrorBytes - body.count)))
            limitedBody = body
            lock.unlock()
            return
        }
        lock.unlock()
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let body = limitedBody
        lock.unlock()
        // A 429 counts even if its body was cut off: the limit is what matters.
        deliver(body.map { .limited($0) } ?? .unavailable)
        continuation.finish()
        session.finishTasksAndInvalidate()
    }
}
