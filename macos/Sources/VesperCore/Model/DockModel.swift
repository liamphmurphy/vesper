import Foundation

// Port of desktop/src/dock-model.ts: the Dock icon's menu and progress as data.

public struct PersonaSummary: Sendable, Equatable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct DockMenuInput: Sendable {
    public var items: [InboxItem]
    public var personas: [PersonaSummary]
    /// Offer Screenshot to Chat.
    public var screenshot: Bool
    public var maxItems: Int
    public var maxPersonas: Int
    public init(items: [InboxItem] = [], personas: [PersonaSummary] = [], screenshot: Bool = true, maxItems: Int = 5, maxPersonas: Int = 6) {
        self.items = items
        self.personas = personas
        self.screenshot = screenshot
        self.maxItems = maxItems
        self.maxPersonas = maxPersonas
    }
}

public enum DockModel {
    /// The web app's "new chat" page, with a persona when it's a valid id.
    public static func newChatHref(personaId: String? = nil) -> String {
        if let id = personaId, id.range(of: uuidPattern, options: .regularExpression) != nil { return "/chat?new&persona=\(id)" }
        return "/chat?new"
    }

    public static func buildDockMenu(_ input: DockMenuInput) -> [TrayMenuItem] {
        var out: [TrayMenuItem] = []
        let needs = TrayModel.newestNeedsYou(input.items)
        if !needs.isEmpty {
            out.append(.header("Needs you (\(needs.count))"))
            for item in needs.prefix(input.maxItems) {
                let who = item.ticketKey.flatMap { $0.isEmpty ? nil : "\($0) · " } ?? ""
                out.append(.item(label: TrayModel.clipLabel("\(who)\(item.title)"), action: .openHref(item.href.isEmpty ? "/inbox" : item.href)))
            }
            if needs.count > input.maxItems { out.append(.item(label: "Show all \(needs.count) in Inbox…", action: .openHref("/inbox"))) }
            out.append(.separator)
        }
        out.append(.item(label: "New Chat", action: .openHref(newChatHref())))
        let personas = input.personas
            .filter { $0.id.range(of: uuidPattern, options: .regularExpression) != nil && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(input.maxPersonas)
        for p in personas {
            let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(.item(label: TrayModel.clipLabel("New Chat with \(name)"), action: .openHref(newChatHref(personaId: p.id))))
        }
        out.append(.separator)
        out.append(.item(label: "Quick Capture…", action: .quickCapture))
        if input.screenshot { out.append(.item(label: "Screenshot to Chat…", action: .screenshot)) }
        return out
    }

    /// Dock progress: the run image download's fraction, or -1 for none.
    public static func dockProgress(_ health: StackHealth) -> Double {
        guard health.phase == .downloading, let done = health.downloadedBytes, let total = health.totalBytes, total > 0 else { return -1 }
        return min(1, max(0, Double(done) / Double(total)))
    }

    public enum ShowHide: Equatable, Sendable { case show, hide }

    /// Hide Vesper when it's the active app with a window showing, otherwise bring it forward.
    public static func showHideAction(appFocused: Bool, visibleWindows: Int) -> ShowHide {
        appFocused && visibleWindows > 0 ? .hide : .show
    }
}
