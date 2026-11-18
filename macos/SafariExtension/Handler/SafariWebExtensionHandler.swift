import AppKit
import Foundation
import SafariServices

/// Vesper for Safari's native handler: Safari hands it each
/// browser.runtime.sendNativeMessage from the extension's background script.
/// All the logic is in SafariBridge; this only unwraps and replies.
@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        SafariBridge.handle(message, open: { NSWorkspace.shared.open($0) }) { reply in
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: reply]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }
}
