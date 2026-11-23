import Foundation

/// A paper style the `/print/knowledge/<id>` route renders (`web/lib/knowledge-print.ts`).
public enum KnowledgePrintStyle: String, CaseIterable, Sendable {
    case clean, editorial, compact, technical

    public var label: String {
        switch self {
        case .clean: "Clean"
        case .editorial: "Editorial"
        case .compact: "Compact"
        case .technical: "Technical"
        }
    }

    /// A `SidebarIcons` name, matching the web menu's icons.
    public var icon: String {
        switch self {
        case .clean: "artifacts"
        case .editorial: "wiki"
        case .compact: "board"
        case .technical: "code"
        }
    }
}

/// The Knowledge page "Print or save as PDF" submenu: one item per paper style, which opens the
/// page's print route, and Ask a Persona, which drafts a `render_pdf` request in the page's chat.
public enum KnowledgePrintLogic {
    public static let menuItemId = "page.print"
    public static let askPersonaItemId = "page.print.ask-persona"
    private static let stylePrefix = "page.print.style:"

    public static func styleItemId(_ style: KnowledgePrintStyle) -> String {
        stylePrefix + style.rawValue
    }

    public static func style(fromMenuItemId id: String) -> KnowledgePrintStyle? {
        guard id.hasPrefix(stylePrefix) else { return nil }
        return KnowledgePrintStyle(rawValue: String(id.dropFirst(stylePrefix.count)))
    }

    public static func menuItem() -> MenuItem {
        let styles = KnowledgePrintStyle.allCases.map {
            MenuItem(id: styleItemId($0), label: $0.label, icon: $0.icon)
        }
        return MenuItem(
            id: menuItemId,
            label: "Print or save as PDF",
            icon: "printer",
            children: styles + [
                MenuItem(id: "page.print.sep", separator: true),
                MenuItem(id: askPersonaItemId, label: "Ask a Persona\u{2026}", icon: "msg"),
            ]
        )
    }

    public static func printPath(pageId: String, style: KnowledgePrintStyle) -> String {
        let id = pageId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? pageId
        return "/print/knowledge/\(id)?style=\(style.rawValue)"
    }

    /// The composer draft for Ask a Persona; it links the page by path so the persona can read it.
    public static func personaPdfPrompt(path: String?, title: String) -> String {
        let trimmedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = !trimmedPath.isEmpty ? trimmedPath : (!trimmedTitle.isEmpty ? trimmedTitle : "Untitled")
        return "Export [[\(target)]] as a polished, print-ready PDF using render_pdf. "
    }
}
