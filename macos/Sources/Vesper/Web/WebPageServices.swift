import AppKit
import VesperCore
import WebKit

/// Things Chromium does for a page that WKWebView does not: `window.print()` and clipboard writes
/// that WebKit refuses (no user gesture, e.g. the dev terminal's OSC 52 copy).
///
/// These are separate script message handlers, not the `vesper` bridge: they take only a trusted
/// main frame at the Vesper origin, and nothing here reads the clipboard.
@MainActor
final class WebPageServices: NSObject, WKScriptMessageHandler {
    static let printHandler = "vesperPrint"
    static let clipboardHandler = "vesperClipboard"
    /// Clipboard text above this is refused (a runaway page must not fill the pasteboard).
    static let maxClipboardBytes = 1_000_000

    /// The Vesper server origin; messages from anywhere else are dropped. Set on connect.
    var baseURL: URL?
    weak var webView: WKWebView?
    private var printing = false

    /// Overrides window.print (WKWebView on macOS ignores it).
    static let printScript = """
    (function () {
      try {
        var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vesperPrint;
        if (!h) return;
        Object.defineProperty(window, "print", { value: function () { h.postMessage({}); }, writable: true, configurable: true });
      } catch (e) {}
    })();
    """

    /// Wraps navigator.clipboard.writeText: WebKit's own write goes first; when it refuses (a
    /// rejected promise), the text goes to the native handler instead. Read is never wrapped.
    static let clipboardScript = """
    (function () {
      try {
        var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vesperClipboard;
        var c = navigator.clipboard;
        if (!h || !c || typeof c.writeText !== "function") return;
        var orig = c.writeText.bind(c);
        Object.defineProperty(c, "writeText", {
          configurable: true, writable: true,
          value: function (text) {
            var s = String(text);
            return orig(s).catch(function (err) {
              if (s.length > 1000000) throw err;
              h.postMessage({ text: s });
            });
          }
        });
      } catch (e) {}
    })();
    """

    static func install(on controller: WKUserContentController, services: WebPageServices) {
        for source in [printScript, clipboardScript] {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        controller.add(services, name: printHandler)
        controller.add(services, name: clipboardHandler)
    }

    func teardown(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.printHandler)
        controller.removeScriptMessageHandler(forName: Self.clipboardHandler)
    }

    private func trusted(_ message: WKScriptMessage) -> Bool {
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        guard frame.isMainFrame, let baseURL,
              BridgeOrigin.matches(scheme: origin.protocol, host: origin.host, port: origin.port, base: baseURL) else {
            vlog("page services: dropped \(message.name) from \(origin.protocol)://\(origin.host):\(origin.port) mainFrame=\(frame.isMainFrame)")
            return false
        }
        return true
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard trusted(message) else { return }
        switch message.name {
        case Self.printHandler: printPage()
        case Self.clipboardHandler:
            guard let body = message.body as? [String: Any], let text = body["text"] as? String,
                  text.utf8.count <= Self.maxClipboardBytes else {
                vlog("clipboard: refused message")
                return
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            vlog("clipboard: wrote \(text.utf8.count) bytes natively")
        default: break
        }
    }

    /// The print panel as a sheet on the window; Save as PDF is in its PDF menu.
    func printPage() {
        guard !printing, let webView, let window = webView.window else { return }
        printing = true
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        let op = webView.printOperation(with: info)
        op.view?.frame = webView.bounds
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.runModal(for: window, delegate: self, didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printing = false
        vlog("print finished success=\(success)")
    }
}
