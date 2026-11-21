import Foundation
import VesperCore

/// The Dev workspace's PTY stream: the runner's `/ws` WebSocket on the workspace's playground port
/// (server/internal/runner/dev_workspace.go), the same one the web's xterm.js terminal used. Output
/// arrives as binary frames; keystrokes go out as binary frames and resizes as a JSON text frame.
@MainActor
final class DevTerminalConnection {
    private(set) var state: DevTerminalLogic.Connection = .disconnected {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((DevTerminalLogic.Connection) -> Void)?
    var onOutput: (([UInt8]) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiving: Task<Void, Never>?

    /// Opens the socket with the app's session cookie and Vesper's origin (the runner refuses any
    /// other origin, so a playground on a neighbouring port can't attach). Closes any previous one.
    func connect(base: URL, port: Int, cols: Int, rows: Int, client: APIClient) {
        close()
        guard let url = DevTerminalLogic.socketURL(base: base, port: port, cols: cols, rows: rows),
              let origin = DevTerminalLogic.origin(of: base) else {
            vlog("dev terminal: no socket URL for port \(port)")
            return
        }
        var request = URLRequest(url: url)
        client.authorize(&request)
        request.setValue(origin, forHTTPHeaderField: "Origin")

        let events = SocketEvents(
            opened: { [weak self] task in Task { @MainActor in self?.opened(task) } },
            closed: { [weak self] task in Task { @MainActor in self?.closed(task) } }
        )
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: events, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        state = .connecting
        task.resume()
        receiving = Task { [weak self] in await self?.receive(from: task) }
    }

    /// Keystrokes, pastes and terminal replies, as the bytes the emulator produced.
    func send(_ bytes: ArraySlice<UInt8>) {
        guard state == .connected, let task, !bytes.isEmpty else { return }
        task.send(.data(Data(bytes))) { error in
            if let error { vlog("dev terminal: send failed: \(error.localizedDescription)") }
        }
    }

    func resize(cols: Int, rows: Int) {
        guard state == .connected, let task else { return }
        task.send(.string(DevTerminalLogic.resizeMessage(cols: cols, rows: rows))) { _ in }
    }

    func close() {
        receiving?.cancel()
        receiving = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = .disconnected
    }

    private func receive(from task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                closed(task)
                return
            }
            guard task === self.task else { return }
            switch message {
            case .data(let data): onOutput?([UInt8](data))
            // The runner writes its own errors ("failed to attach terminal") as text frames.
            case .string(let text): onOutput?(Array(text.utf8))
            @unknown default: break
            }
        }
    }

    private func opened(_ task: URLSessionWebSocketTask) {
        guard task === self.task else { return }
        state = .connected
    }

    private func closed(_ task: URLSessionWebSocketTask) {
        guard task === self.task else { return }
        receiving?.cancel()
        receiving = nil
        self.task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        state = .disconnected
    }
}

/// The URLSession delegate that reports the socket opening and closing (a WebSocket task says nothing
/// else about its handshake).
private final class SocketEvents: NSObject, URLSessionWebSocketDelegate, Sendable {
    let opened: @Sendable (URLSessionWebSocketTask) -> Void
    let closed: @Sendable (URLSessionWebSocketTask) -> Void

    init(opened: @escaping @Sendable (URLSessionWebSocketTask) -> Void, closed: @escaping @Sendable (URLSessionWebSocketTask) -> Void) {
        self.opened = opened
        self.closed = closed
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        opened(webSocketTask)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        closed(webSocketTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { vlog("dev terminal: socket ended: \(error.localizedDescription)") }
        if let socket = task as? URLSessionWebSocketTask { closed(socket) }
    }
}
