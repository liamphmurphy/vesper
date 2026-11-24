import AppKit
import UniformTypeIdentifiers
import VesperCore
import WebKit

/// Narrow `WKScriptMessageHandler` bridging opt-in macOS OS capabilities (`os.notifications`,
/// `os.clipboard`, `os.file_picker`) to Custom Apps.
///
/// Enforces origin, main-frame, URL-to-slug matching, and server-authoritative capability state
/// (`allowed | requires_approval | denied`) on every invocation so revocation takes effect immediately
/// and denied capabilities can never be bypassed.
@MainActor
final class CustomAppOSBridge: NSObject, WKScriptMessageHandler {
    private weak var app: AppModel?
    weak var webView: WKWebView?
    /// Vesper server origin; messages from any other origin or non-main frames are dropped.
    var baseURL: URL?

    init(app: AppModel) {
        self.app = app
        super.init()
    }

    static func install(on controller: WKUserContentController, bridge: CustomAppOSBridge) {
        controller.add(bridge, name: CustomAppOSLimits.handlerName)
    }

    func teardown(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: CustomAppOSLimits.handlerName)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == CustomAppOSLimits.handlerName else { return }
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        guard frame.isMainFrame, let baseURL,
              BridgeOrigin.matches(scheme: origin.protocol, host: origin.host, port: origin.port, base: baseURL) else {
            vlog("custom-app-os: dropped message from \(origin.protocol)://\(origin.host):\(origin.port) mainFrame=\(frame.isMainFrame)")
            return
        }

        let request: CustomAppOSRequest
        do {
            request = try CustomAppOSRequest.decode(fromJSONObject: message.body)
        } catch {
            vlog("custom-app-os: rejected malformed message: \(error)")
            if let dict = message.body as? [String: Any], let reqId = dict["requestId"] as? String, !reqId.isEmpty {
                let errMsg: String
                if case CustomAppOSRequestError.malformed(let detail) = error {
                    errMsg = detail
                } else {
                    errMsg = "Invalid OS capability request"
                }
                send(.failure(requestId: reqId, error: errMsg))
            }
            return
        }

        // Confirm the web view is actually serving `/apps/<slug>` so no other route can spoof a slug.
        guard CustomAppOSPolicy.urlMatchesSlug(webView?.url, slug: request.slug) else {
            vlog("custom-app-os: slug mismatch for \(request.slug) on \(webView?.url?.path ?? "nil")")
            send(.failure(requestId: request.requestId, error: "Custom app context mismatch"))
            return
        }

        Task { @MainActor [weak self] in
            await self?.handle(request)
        }
    }

    private func handle(_ request: CustomAppOSRequest) async {
        guard let app, let client = app.aux.client() else {
            send(.failure(requestId: request.requestId, error: "Vesper server is not connected"))
            return
        }

        let detail: API.CustomAppDetail
        do {
            detail = try await client.send(API.getCustomApp(slug: request.slug))
        } catch {
            let msg = (error as? APIError)?.userMessage ?? "Couldn\u{2019}t verify app capabilities"
            send(.failure(requestId: request.requestId, error: msg))
            return
        }

        switch CustomAppOSPolicy.evaluate(slug: request.slug, capabilities: detail.capabilities, request: request) {
        case .deny(let message):
            send(.failure(requestId: request.requestId, error: message))
            return
        case .requireApproval(let cap, let summary):
            send(.approvalRequired(requestId: request.requestId, capability: cap, summary: summary))
            return
        case .allow:
            break
        }

        switch request.action {
        case .notify:
            executeNotify(request, app: app, appName: detail.name)
        case .clipboardRead:
            executeClipboardRead(request)
        case .clipboardWrite:
            executeClipboardWrite(request)
        case .filePicker:
            await executeFilePicker(request, appName: detail.name)
        }
    }

    private func executeNotify(_ request: CustomAppOSRequest, app: AppModel, appName: String) {
        let title = request.title ?? appName
        let delivered = app.system.sendCustomAppNotification(
            slug: request.slug,
            title: title,
            subtitle: request.subtitle ?? appName,
            body: request.body ?? "",
            silent: request.silent
        )
        if delivered {
            send(.success(requestId: request.requestId, data: .object(["delivered": .bool(true)])))
        } else {
            send(.failure(requestId: request.requestId, error: "macOS notifications require the packaged Vesper.app"))
        }
    }

    private func executeClipboardRead(_ request: CustomAppOSRequest) {
        guard webView?.window?.isVisible == true, NSApp.isActive else {
            send(.failure(requestId: request.requestId, error: "Clipboard read requires the app window to be active"))
            return
        }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard text.utf8.count <= CustomAppOSLimits.maxClipboardBytes else {
            send(.failure(requestId: request.requestId, error: "Clipboard text exceeds 1 MB limit"))
            return
        }
        send(.success(requestId: request.requestId, data: .object(["text": .string(text)])))
    }

    private func executeClipboardWrite(_ request: CustomAppOSRequest) {
        guard webView?.window?.isVisible == true, NSApp.isActive else {
            send(.failure(requestId: request.requestId, error: "Clipboard write requires the app window to be active"))
            return
        }
        let text = request.text ?? ""
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        send(.success(requestId: request.requestId, data: .object(["ok": .bool(true)])))
    }

    private func executeFilePicker(_ request: CustomAppOSRequest, appName: String) async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = request.multiple
        panel.prompt = "Choose"
        panel.message = request.title ?? "Choose \(request.multiple ? "files" : "a file") for \(appName)"
        if !request.extensions.isEmpty {
            let types = request.extensions.compactMap { UTType(filenameExtension: $0) }
            if !types.isEmpty {
                panel.allowedContentTypes = types
            }
        }

        let response: NSApplication.ModalResponse
        if let window = webView?.window, window.isVisible, window.attachedSheet == nil {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }

        guard response == .OK else {
            send(.success(requestId: request.requestId, data: .object([
                "canceled": .bool(true),
                "files": .array([]),
            ])))
            return
        }

        let urls = Array(panel.urls.prefix(CustomAppOSLimits.maxPickedFiles))
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[JSONValue], PickedFileReadError> in
            var encoded: [JSONValue] = []
            var totalBytes = 0
            for url in urls {
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                if let fileSize = (attrs?[.size] as? NSNumber)?.intValue,
                   fileSize > CustomAppOSLimits.maxPickedFileBytes {
                    return .failure(PickedFileReadError("File \"\(url.lastPathComponent)\" exceeds 2 MB limit"))
                }
                let data: Data
                do {
                    data = try Data(contentsOf: url, options: [.mappedIfSafe])
                } catch {
                    return .failure(PickedFileReadError("Couldn\u{2019}t read \"\(url.lastPathComponent)\": \(error.localizedDescription)"))
                }
                guard data.count <= CustomAppOSLimits.maxPickedFileBytes else {
                    return .failure(PickedFileReadError("File \"\(url.lastPathComponent)\" exceeds 2 MB limit"))
                }
                totalBytes += data.count
                guard totalBytes <= CustomAppOSLimits.maxPickedTotalBytes else {
                    return .failure(PickedFileReadError("Selected files exceed 5 MB total limit"))
                }
                let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                encoded.append(CustomAppOSPolicy.encodePickedFile(name: url.lastPathComponent, data: data, contentType: contentType))
            }
            return .success(encoded)
        }.value

        switch result {
        case .success(let files):
            send(.success(requestId: request.requestId, data: .object([
                "canceled": .bool(false),
                "files": .array(files),
            ])))
        case .failure(let err):
            send(.failure(requestId: request.requestId, error: err.message))
        }
    }

    private func send(_ response: CustomAppOSResponse) {
        guard let webView else { return }
        do {
            let object = try response.toJSONObject()
            let js = "window.dispatchEvent(new CustomEvent('\(CustomAppOSLimits.eventName)', { detail: msg }))"
            Task { @MainActor in
                do {
                    _ = try await webView.callAsyncJavaScript(js, arguments: ["msg": object], in: nil, contentWorld: .page)
                } catch {
                    vlog("custom-app-os: reply dispatch failed: \(error)")
                }
            }
        } catch {
            vlog("custom-app-os: reply encode failed: \(error)")
        }
    }
}

private struct PickedFileReadError: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}
