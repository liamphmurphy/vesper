import Foundation

// Swift mirror of web/lib/native-shell/protocol.ts (version 1). Change both together and add a
// fixture in protocol/native-bridge/. Page messages are decoded; commands are encoded (and
// decodable, for the fixture round-trip test).

public let nativeProtocolVersion = 1

public enum Tone: String, Codable, Sendable, Hashable {
    case neutral, accent, done, human, blocked, warning, danger

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Tone(rawValue: raw) ?? .neutral
    }
}

public enum ColorMode: String, Codable, Sendable, Hashable {
    case dark, light
}

public struct MenuItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String?
    public var icon: String?
    public var separator: Bool?
    public var destructive: Bool?
    public var disabled: Bool?
    public var checked: Bool?
    public var shortcut: String?
    public var children: [MenuItem]?

    public init(id: String, label: String? = nil, icon: String? = nil, separator: Bool? = nil, destructive: Bool? = nil,
                disabled: Bool? = nil, checked: Bool? = nil, shortcut: String? = nil, children: [MenuItem]? = nil) {
        self.id = id; self.label = label; self.icon = icon; self.separator = separator; self.destructive = destructive
        self.disabled = disabled; self.checked = checked; self.shortcut = shortcut; self.children = children
    }
}

public struct Avatar: Codable, Sendable, Hashable {
    public var initials: String
    public var color: String?
    public var imageUrl: String?

    public init(initials: String, color: String? = nil, imageUrl: String? = nil) {
        self.initials = initials; self.color = color; self.imageUrl = imageUrl
    }
}

public struct NavBadge: Codable, Sendable, Hashable {
    public var text: String
    public var tone: Tone?

    public init(text: String, tone: Tone? = nil) { self.text = text; self.tone = tone }
}

public struct NavItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: String?
    public var avatar: Avatar?
    public var badge: NavBadge?
    public var status: Tone?
    public var trailing: String?
    public var href: String?
    public var children: [NavItem]?
    public var expanded: Bool?
    public var disabled: Bool?
    public var contextMenu: [MenuItem]?

    public init(id: String, title: String, subtitle: String? = nil, icon: String? = nil, avatar: Avatar? = nil,
                badge: NavBadge? = nil, status: Tone? = nil, trailing: String? = nil, href: String? = nil,
                children: [NavItem]? = nil, expanded: Bool? = nil, disabled: Bool? = nil, contextMenu: [MenuItem]? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.icon = icon; self.avatar = avatar
        self.badge = badge; self.status = status; self.trailing = trailing; self.href = href
        self.children = children; self.expanded = expanded; self.disabled = disabled; self.contextMenu = contextMenu
    }
}

public struct NavAction: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var icon: String
    public var accent: Bool?
    public var disabled: Bool?
    public var menu: [MenuItem]?
    public var showsLabel: Bool?

    public init(id: String, label: String, icon: String, accent: Bool? = nil, disabled: Bool? = nil, menu: [MenuItem]? = nil,
                showsLabel: Bool? = nil) {
        self.id = id; self.label = label; self.icon = icon; self.accent = accent; self.disabled = disabled; self.menu = menu
        self.showsLabel = showsLabel
    }
}

public struct NavSection: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String?
    public var items: [NavItem]
    public var actions: [NavAction]?
    public var collapsible: Bool?
    public var collapsed: Bool?
    public var badge: NavBadge?
    public var emptyText: String?

    public init(id: String, title: String? = nil, items: [NavItem], actions: [NavAction]? = nil,
                collapsible: Bool? = nil, collapsed: Bool? = nil, badge: NavBadge? = nil, emptyText: String? = nil) {
        self.id = id; self.title = title; self.items = items; self.actions = actions
        self.collapsible = collapsible; self.collapsed = collapsed; self.badge = badge; self.emptyText = emptyText
    }
}

public struct NavPickerOption: Codable, Sendable, Hashable {
    public var value: String
    public var label: String
    public var icon: String?

    public init(value: String, label: String, icon: String? = nil) { self.value = value; self.label = label; self.icon = icon }
}

public struct NavPicker: Codable, Sendable, Hashable {
    public var id: String
    public var value: String
    public var options: [NavPickerOption]

    public init(id: String, value: String, options: [NavPickerOption]) { self.id = id; self.value = value; self.options = options }
}

public struct NavFilterOption: Codable, Sendable, Hashable {
    public var value: String
    public var label: String
    public var checked: Bool

    public init(value: String, label: String, checked: Bool) { self.value = value; self.label = label; self.checked = checked }
}

/// A pull-down with check marks in the header row; choosing an option sends `nav.filter`.
public struct NavFilterMenu: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var icon: String?
    public var options: [NavFilterOption]
    public var multiple: Bool?

    public init(id: String, label: String, icon: String? = nil, options: [NavFilterOption], multiple: Bool? = nil) {
        self.id = id; self.label = label; self.icon = icon; self.options = options; self.multiple = multiple
    }
}

public struct NavSearch: Codable, Sendable, Hashable {
    public var id: String
    public var placeholder: String
    public var value: String

    public init(id: String, placeholder: String, value: String) { self.id = id; self.placeholder = placeholder; self.value = value }
}

public struct NavModel: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String?
    public var actions: [NavAction]?
    public var picker: NavPicker?
    public var filters: [NavFilterMenu]?
    public var search: NavSearch?
    public var sections: [NavSection]
    public var selectedId: String?

    public init(id: String, title: String? = nil, actions: [NavAction]? = nil, picker: NavPicker? = nil,
                filters: [NavFilterMenu]? = nil, search: NavSearch? = nil, sections: [NavSection], selectedId: String? = nil) {
        self.id = id; self.title = title; self.actions = actions; self.picker = picker; self.filters = filters; self.search = search
        self.sections = sections; self.selectedId = selectedId
    }
}

public enum AreaId: String, Codable, Sendable, Hashable {
    case chat, spaces, knowledge, library, apps
}

public struct AreaBadge: Codable, Sendable, Hashable {
    public var text: String?
    public var tone: Tone?

    public init(text: String? = nil, tone: Tone? = nil) { self.text = text; self.tone = tone }
}

public struct ShellArea: Codable, Sendable, Hashable, Identifiable {
    public var id: AreaId
    public var label: String
    public var icon: String
    public var href: String
    public var badge: AreaBadge?

    public init(id: AreaId, label: String, icon: String, href: String, badge: AreaBadge? = nil) {
        self.id = id; self.label = label; self.icon = icon; self.href = href; self.badge = badge
    }
}

public struct ShellApp: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var icon: String
    public var href: String

    public init(id: String, label: String, icon: String, href: String) {
        self.id = id; self.label = label; self.icon = icon; self.href = href
    }
}

public struct ShellModel: Codable, Sendable, Hashable {
    public var areas: [ShellArea]
    public var apps: [ShellApp]
    public var currentArea: AreaId?

    public init(areas: [ShellArea], apps: [ShellApp], currentArea: AreaId?) {
        self.areas = areas; self.apps = apps; self.currentArea = currentArea
    }

    // currentArea is `AreaId | null`: always present on the wire.
    enum CodingKeys: String, CodingKey { case areas, apps, currentArea }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(areas, forKey: .areas)
        try c.encode(apps, forKey: .apps)
        try c.encode(currentArea, forKey: .currentArea)
    }
}

public enum ToolbarItemKind: String, Codable, Sendable, Hashable {
    case button, menu, toggle
}

public struct ToolbarItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var icon: String?
    public var kind: ToolbarItemKind
    public var menu: [MenuItem]?
    public var on: Bool?
    public var disabled: Bool?
    public var accent: Bool?
    /// Show the label as text next to the icon or avatar.
    public var showsLabel: Bool?
    /// A picture or initials instead of the icon.
    public var avatar: Avatar?
    /// Right after the title (or tabs), or (default) before the shell's own items.
    public var placement: ToolbarPlacement?

    public init(id: String, label: String, icon: String? = nil, kind: ToolbarItemKind, menu: [MenuItem]? = nil,
                on: Bool? = nil, disabled: Bool? = nil, accent: Bool? = nil, showsLabel: Bool? = nil,
                avatar: Avatar? = nil, placement: ToolbarPlacement? = nil) {
        self.id = id; self.label = label; self.icon = icon; self.kind = kind; self.menu = menu
        self.on = on; self.disabled = disabled; self.accent = accent
        self.showsLabel = showsLabel; self.avatar = avatar; self.placement = placement
    }
}

public enum ToolbarPlacement: String, Codable, Sendable, Hashable {
    case leading, trailing
}

/// One button in the right rail (protocol.ts RailItem).
public struct RailItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var icon: String?
    public var avatar: Avatar?
    public var badge: AreaBadge?
    public var status: Tone?
    public var active: Bool?
    /// .needsYou: the shell shows its own Needs-you popover instead of sending rail.action.
    public var kind: RailItemKind?
    public var menu: [MenuItem]?
    public var disabled: Bool?
    /// An agent harness's animated character; the shell draws it in the button.
    public var character: RailCharacter?
    /// Usage rows the shell draws above `menu` in the item's popover.
    public var usage: [RailUsage]?

    public init(id: String, label: String, icon: String? = nil, avatar: Avatar? = nil, badge: AreaBadge? = nil, status: Tone? = nil,
                active: Bool? = nil, kind: RailItemKind? = nil, menu: [MenuItem]? = nil, disabled: Bool? = nil,
                character: RailCharacter? = nil, usage: [RailUsage]? = nil) {
        self.id = id; self.label = label; self.icon = icon; self.avatar = avatar; self.badge = badge; self.status = status
        self.active = active; self.kind = kind; self.menu = menu; self.disabled = disabled
        self.character = character; self.usage = usage
    }
}

public struct RailCharacter: Codable, Sendable, Hashable {
    /// "claude-code", "codex" or "antigravity"; any other name has no character.
    public var harness: String
    public var working: Bool
    /// The small label under the character.
    public var name: String?

    public init(harness: String, working: Bool, name: String? = nil) { self.harness = harness; self.working = working; self.name = name }
}

public enum UsageTone: String, Codable, Sendable, Hashable {
    case normal, warn, limited

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = UsageTone(rawValue: raw) ?? .normal
    }
}

/// One usage reading in a rail popover (protocol.ts RailUsage).
public struct RailUsage: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var value: String?
    /// Bar fill, 0...1.
    public var fraction: Double?
    public var tone: UsageTone?
    public var unavailable: Bool?
    /// The line under the bar: left text, optional right text.
    public var meta: [String]?
    public var sub: String?
    public var footnote: String?

    public init(id: String, title: String, value: String? = nil, fraction: Double? = nil, tone: UsageTone? = nil,
                unavailable: Bool? = nil, meta: [String]? = nil, sub: String? = nil, footnote: String? = nil) {
        self.id = id; self.title = title; self.value = value; self.fraction = fraction; self.tone = tone
        self.unavailable = unavailable; self.meta = meta; self.sub = sub; self.footnote = footnote
    }
}

public enum RailItemKind: String, Codable, Sendable, Hashable {
    case button, needsYou
}

/// The right rail, top to bottom: the page's dock controls, then status, then links.
public struct RailModel: Codable, Sendable, Hashable {
    public var top: [RailItem]
    public var middle: [RailItem]
    public var foot: [RailItem]

    public init(top: [RailItem] = [], middle: [RailItem] = [], foot: [RailItem] = []) {
        self.top = top; self.middle = middle; self.foot = foot
    }
}

// MARK: - Native inspector

public enum CompanionSubjectKind: String, Codable, Sendable, Hashable {
    case run, ticket

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CompanionSubjectKind(rawValue: raw) ?? .ticket
    }
}

public struct CompanionSubject: Codable, Sendable, Hashable {
    public var kind: CompanionSubjectKind
    public var id: String
    public var title: String
    public var agent: String?
    public var ticketKey: String?

    public init(kind: CompanionSubjectKind, id: String, title: String, agent: String? = nil, ticketKey: String? = nil) {
        self.kind = kind; self.id = id; self.title = title; self.agent = agent; self.ticketKey = ticketKey
    }
}

public struct CompanionContext: Codable, Sendable, Hashable {
    public var subject: CompanionSubject?
    public var path: String?

    public init(subject: CompanionSubject? = nil, path: String? = nil) {
        self.subject = subject; self.path = path
    }
}

public enum InspectorTabKind: String, Codable, Sendable, Hashable {
    case native, companion, panel, web

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InspectorTabKind(rawValue: raw) ?? .web
    }
}

public enum InspectorWidth: String, Codable, Sendable, Hashable {
    case regular, wide, max

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InspectorWidth(rawValue: raw) ?? .regular
    }
}

public struct InspectorPanelSpec: Codable, Sendable, Hashable {
    public var kind: String
    public var key: String
    public var propsJson: String

    public init(kind: String, key: String, propsJson: String) {
        self.kind = kind; self.key = key; self.propsJson = propsJson
    }
}

public struct InspectorPanelContext: Codable, Sendable, Hashable {
    public var active: InspectorPanelSpec?
    public var keepKeys: [String]
    public var path: String?

    public init(active: InspectorPanelSpec? = nil, keepKeys: [String] = [], path: String? = nil) {
        self.active = active; self.keepKeys = keepKeys; self.path = path
    }

    // active is `InspectorPanelSpec | null`: always present on the wire.
    enum CodingKeys: String, CodingKey { case active, keepKeys, path }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(active, forKey: .active)
        try c.encode(keepKeys, forKey: .keepKeys)
        try c.encodeIfPresent(path, forKey: .path)
    }
}

public struct InspectorOption: Codable, Sendable, Hashable {
    public var value: String
    public var label: String
    public var icon: String?
    public var tone: Tone?

    public init(value: String, label: String, icon: String? = nil, tone: Tone? = nil) {
        self.value = value; self.label = label; self.icon = icon; self.tone = tone
    }
}

public struct InspectorAction: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var icon: String?
    public var accent: Bool?
    public var destructive: Bool?
    public var active: Bool?
    public var disabled: Bool?
    public var menu: [MenuItem]?

    public init(id: String, label: String, icon: String? = nil, accent: Bool? = nil, destructive: Bool? = nil,
                active: Bool? = nil, disabled: Bool? = nil, menu: [MenuItem]? = nil) {
        self.id = id; self.label = label; self.icon = icon; self.accent = accent; self.destructive = destructive
        self.active = active; self.disabled = disabled; self.menu = menu
    }
}

public struct InspectorChip: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var color: String?
    public var tone: Tone?
    public var icon: String?
    public var href: String?
    public var removable: Bool?

    public init(id: String, text: String, color: String? = nil, tone: Tone? = nil,
                icon: String? = nil, href: String? = nil, removable: Bool? = nil) {
        self.id = id; self.text = text; self.color = color; self.tone = tone
        self.icon = icon; self.href = href; self.removable = removable
    }
}

public enum InspectorStepState: String, Codable, Sendable, Hashable {
    case done, current, pending, failed
    case needsHuman = "needs_human"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InspectorStepState(rawValue: raw) ?? .pending
    }
}

public struct InspectorStep: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var state: InspectorStepState
    public var interactive: Bool?

    public init(id: String, text: String, state: InspectorStepState, interactive: Bool? = nil) {
        self.id = id; self.text = text; self.state = state; self.interactive = interactive
    }
}

public struct InspectorBarPoint: Codable, Sendable, Hashable {
    public var label: String
    public var value: Double
    public var secondary: Double?

    public init(label: String, value: Double, secondary: Double? = nil) {
        self.label = label; self.value = value; self.secondary = secondary
    }
}

public enum InspectorItemKind: String, Codable, Sendable, Hashable {
    case fact, picker, segmented, toggle, text, checklist, progress, chips, list, actions, note, chart

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InspectorItemKind(rawValue: raw) ?? .note
    }
}

public struct InspectorItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: InspectorItemKind
    public var label: String?
    public var value: String?
    public var detail: String?
    public var placeholder: String?
    public var icon: String?
    public var tone: Tone?
    public var mono: Bool?
    public var multiline: Bool?
    public var inputType: String?
    public var checked: Bool?
    public var disabled: Bool?
    public var fraction: Double?
    public var href: String?
    public var url: String?
    public var actionId: String?
    public var badge: NavBadge?
    public var options: [InspectorOption]?
    public var steps: [InspectorStep]?
    public var chips: [InspectorChip]?
    public var rows: [NavItem]?
    public var actions: [InspectorAction]?
    public var menu: [MenuItem]?
    public var points: [InspectorBarPoint]?

    public init(id: String, kind: InspectorItemKind, label: String? = nil, value: String? = nil, detail: String? = nil,
                placeholder: String? = nil, icon: String? = nil, tone: Tone? = nil, mono: Bool? = nil, multiline: Bool? = nil,
                inputType: String? = nil, checked: Bool? = nil, disabled: Bool? = nil, fraction: Double? = nil,
                href: String? = nil, url: String? = nil, actionId: String? = nil, badge: NavBadge? = nil,
                options: [InspectorOption]? = nil, steps: [InspectorStep]? = nil, chips: [InspectorChip]? = nil,
                rows: [NavItem]? = nil, actions: [InspectorAction]? = nil, menu: [MenuItem]? = nil,
                points: [InspectorBarPoint]? = nil) {
        self.id = id; self.kind = kind; self.label = label; self.value = value; self.detail = detail
        self.placeholder = placeholder; self.icon = icon; self.tone = tone; self.mono = mono; self.multiline = multiline
        self.inputType = inputType; self.checked = checked; self.disabled = disabled; self.fraction = fraction
        self.href = href; self.url = url; self.actionId = actionId; self.badge = badge
        self.options = options; self.steps = steps; self.chips = chips; self.rows = rows
        self.actions = actions; self.menu = menu; self.points = points
    }
}

public struct InspectorSection: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String?
    public var aside: String?
    public var collapsible: Bool?
    public var collapsed: Bool?
    public var badge: NavBadge?
    public var emptyText: String?
    public var items: [InspectorItem]

    public init(id: String, title: String? = nil, aside: String? = nil, collapsible: Bool? = nil,
                collapsed: Bool? = nil, badge: NavBadge? = nil, emptyText: String? = nil, items: [InspectorItem]) {
        self.id = id; self.title = title; self.aside = aside; self.collapsible = collapsible
        self.collapsed = collapsed; self.badge = badge; self.emptyText = emptyText; self.items = items
    }
}

public struct InspectorTab: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var icon: String
    public var kind: InspectorTabKind
    public var width: InspectorWidth?
    public var busy: Bool?
    public var unread: Bool?
    public var badge: NavBadge?
    public var headerActions: [InspectorAction]?
    public var sections: [InspectorSection]?
    public var emptyText: String?
    public var panel: InspectorPanelSpec?

    public init(id: String, label: String, icon: String, kind: InspectorTabKind, width: InspectorWidth? = nil,
                busy: Bool? = nil, unread: Bool? = nil, badge: NavBadge? = nil, headerActions: [InspectorAction]? = nil,
                sections: [InspectorSection]? = nil, emptyText: String? = nil, panel: InspectorPanelSpec? = nil) {
        self.id = id; self.label = label; self.icon = icon; self.kind = kind; self.width = width; self.busy = busy
        self.unread = unread; self.badge = badge; self.headerActions = headerActions
        self.sections = sections; self.emptyText = emptyText; self.panel = panel
    }
}

public struct InspectorModel: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var open: Bool
    public var activeTabId: String
    public var tabs: [InspectorTab]
    public var companion: CompanionContext?

    public init(id: String, open: Bool, activeTabId: String, tabs: [InspectorTab], companion: CompanionContext? = nil) {
        self.id = id; self.open = open; self.activeTabId = activeTabId; self.tabs = tabs; self.companion = companion
    }
}

public enum ApprovalScope: String, Codable, Sendable, Hashable {
    case runApprovals = "run_approvals"
    case pushRequests = "push_requests"
    case connectorApprovals = "connector_approvals"
    case secretApprovals = "secret_approvals"
}

public enum ToastTone: String, Codable, Sendable, Hashable {
    case neutral, success, error

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ToastTone(rawValue: raw) ?? .neutral
    }
}

public enum ToastEventKind: String, Codable, Sendable, Hashable {
    case action, dismissed, timeout
}

public enum CommandPaletteScope: String, Codable, Sendable, Hashable {
    case all, page, knowledge, type
}

public struct CommandPaletteRequest: Codable, Sendable, Hashable {
    public var path: String?
    public var search: String?
    public var scope: CommandPaletteScope?
    public var scopeType: String?
    public var scopeLabel: String?
    public var includeAgent: Bool?
    public var query: String?

    public init(path: String? = nil, search: String? = nil, scope: CommandPaletteScope? = nil,
                scopeType: String? = nil, scopeLabel: String? = nil, includeAgent: Bool? = nil,
                query: String? = nil) {
        self.path = path; self.search = search; self.scope = scope
        self.scopeType = scopeType; self.scopeLabel = scopeLabel
        self.includeAgent = includeAgent; self.query = query
    }
}

public struct QuickLookItem: Codable, Sendable, Hashable {
    public var url: String
    public var title: String
    public var filename: String?
    public var contentType: String?

    public init(url: String, title: String, filename: String? = nil, contentType: String? = nil) {
        self.url = url; self.title = title; self.filename = filename; self.contentType = contentType
    }
}

// MARK: - Page -> shell

/// Page → shell. Decoded from `window.webkit.messageHandlers.vesper.postMessage`.
public enum PageMessage: Sendable, Equatable, Decodable {
    case ready(path: String)
    case route(path: String, area: AreaId?)
    /// `menu`: the title's own menu (rename, archive…), on a chevron next to the title.
    case title(title: String, subtitle: String?, menu: [MenuItem]? = nil)
    /// The right rail; nil: the page has none.
    case rail(RailModel?)
    /// The native inspector model; nil: the page has none.
    case inspector(InspectorModel?)
    /// Forwards an interactive event from `/inspector-panel` back to the main page's active dock tab.
    case panelEvent(tabId: String, event: String, payloadJson: String? = nil)
    /// Asks the shell to open an in-app path in the main pane (or a new tab).
    case openInMain(path: String, newTab: Bool = false)
    case shell(ShellModel)
    case navigator(NavModel?)
    case navigatorFallback(active: Bool)
    /// True while a screen wants the whole window (a video in theater mode): the sidebar folds, then comes back.
    case sidebarHidden(Bool)
    case toolbar([ToolbarItem])
    /// background: the page's "#RRGGBB" colour, shown past its edges and behind an unpainted tab.
    /// theme: the palette's resolved colours and text size, for native screens.
    case appearance(mode: ColorMode, background: String? = nil, theme: ThemeTokens? = nil)
    case confirmApproval(requestId: String, scope: ApprovalScope)
    case openWorkspaceMenu(requestId: String, folder: String)
    case contextMenu(requestId: String, items: [MenuItem], x: Double, y: Double)
    /// An "Are you sure?" shown as a sheet on the window; reply ok only for the confirm button.
    case confirm(requestId: String, title: String, body: String?, confirmLabel: String, cancelLabel: String?, destructive: Bool)
    /// A single-line text input sheet on the window; reply ok with `value` when confirmed.
    case prompt(requestId: String, title: String, body: String?, label: String?, value: String?,
                placeholder: String?, confirmLabel: String, cancelLabel: String?, maxLength: Int?)
    case toastShow(id: String, title: String, description: String?, tone: ToastTone, actionLabel: String?, durationMs: Int)
    case toastDismiss(id: String)
    case showShortcuts
    case commandPaletteOpen(request: CommandPaletteRequest?)
    case commandPaletteClose
    case quickLook(items: [QuickLookItem], index: Int?)
    case openCustomAppWindow(slug: String)

    private enum Keys: String, CodingKey {
        case v, type, path, area, title, subtitle, model, active, hidden, items, requestId, scope, folder, x, y, mode, menu
        case body, confirmLabel, cancelLabel, destructive, background, newTab, tokens, textSize
        case tabId, event, payloadJson
        case label, value, placeholder, maxLength, id, description, tone, actionLabel, durationMs, request, index, slug
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let v = try c.decode(Int.self, forKey: .v)
        guard v == nativeProtocolVersion else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "unsupported protocol version \(v)")
        }
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "ready":
            self = .ready(path: try c.decode(String.self, forKey: .path))
        case "route":
            self = .route(path: try c.decode(String.self, forKey: .path), area: try c.decodeIfPresent(AreaId.self, forKey: .area))
        case "title":
            self = .title(title: try c.decode(String.self, forKey: .title), subtitle: try c.decodeIfPresent(String.self, forKey: .subtitle),
                          menu: try c.decodeIfPresent([MenuItem].self, forKey: .menu))
        case "rail":
            self = .rail(try c.decodeIfPresent(RailModel.self, forKey: .model))
        case "inspector":
            self = .inspector(try c.decodeIfPresent(InspectorModel.self, forKey: .model))
        case "panel.event":
            self = .panelEvent(tabId: try c.decode(String.self, forKey: .tabId),
                               event: try c.decode(String.self, forKey: .event),
                               payloadJson: try c.decodeIfPresent(String.self, forKey: .payloadJson))
        case "openInMain":
            self = .openInMain(path: try c.decode(String.self, forKey: .path),
                               newTab: try c.decodeIfPresent(Bool.self, forKey: .newTab) ?? false)
        case "shell":
            self = .shell(try c.decode(ShellModel.self, forKey: .model))
        case "navigator":
            self = .navigator(try c.decodeIfPresent(NavModel.self, forKey: .model))
        case "navigatorFallback":
            self = .navigatorFallback(active: try c.decode(Bool.self, forKey: .active))
        case "sidebarHidden":
            self = .sidebarHidden(try c.decode(Bool.self, forKey: .hidden))
        case "toolbar":
            self = .toolbar(try c.decode([ToolbarItem].self, forKey: .items))
        case "appearance":
            let mode = try c.decode(ColorMode.self, forKey: .mode)
            let tokens = try c.decodeIfPresent([String: String].self, forKey: .tokens)
            let textSize = try c.decodeIfPresent(String.self, forKey: .textSize)
            self = .appearance(
                mode: mode, background: try c.decodeIfPresent(String.self, forKey: .background),
                theme: tokens == nil && textSize == nil ? nil : ThemeTokens(mode: mode, colors: tokens ?? [:], textSize: textSize))
        case "confirmApproval":
            self = .confirmApproval(requestId: try c.decode(String.self, forKey: .requestId), scope: try c.decode(ApprovalScope.self, forKey: .scope))
        case "openWorkspaceMenu":
            self = .openWorkspaceMenu(requestId: try c.decode(String.self, forKey: .requestId), folder: try c.decode(String.self, forKey: .folder))
        case "contextMenu":
            self = .contextMenu(requestId: try c.decode(String.self, forKey: .requestId), items: try c.decode([MenuItem].self, forKey: .items),
                                x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y))
        case "confirm":
            self = .confirm(requestId: try c.decode(String.self, forKey: .requestId), title: try c.decode(String.self, forKey: .title),
                            body: try c.decodeIfPresent(String.self, forKey: .body), confirmLabel: try c.decode(String.self, forKey: .confirmLabel),
                            cancelLabel: try c.decodeIfPresent(String.self, forKey: .cancelLabel),
                            destructive: try c.decodeIfPresent(Bool.self, forKey: .destructive) ?? true)
        case "prompt":
            self = .prompt(requestId: try c.decode(String.self, forKey: .requestId), title: try c.decode(String.self, forKey: .title),
                           body: try c.decodeIfPresent(String.self, forKey: .body), label: try c.decodeIfPresent(String.self, forKey: .label),
                           value: try c.decodeIfPresent(String.self, forKey: .value), placeholder: try c.decodeIfPresent(String.self, forKey: .placeholder),
                           confirmLabel: try c.decode(String.self, forKey: .confirmLabel), cancelLabel: try c.decodeIfPresent(String.self, forKey: .cancelLabel),
                           maxLength: try c.decodeIfPresent(Int.self, forKey: .maxLength))
        case "toast.show":
            self = .toastShow(id: try c.decode(String.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                              description: try c.decodeIfPresent(String.self, forKey: .description), tone: try c.decode(ToastTone.self, forKey: .tone),
                              actionLabel: try c.decodeIfPresent(String.self, forKey: .actionLabel), durationMs: try c.decode(Int.self, forKey: .durationMs))
        case "toast.dismiss":
            self = .toastDismiss(id: try c.decode(String.self, forKey: .id))
        case "showShortcuts":
            self = .showShortcuts
        case "commandPalette.open":
            self = .commandPaletteOpen(request: try c.decodeIfPresent(CommandPaletteRequest.self, forKey: .request))
        case "commandPalette.close":
            self = .commandPaletteClose
        case "quickLook":
            self = .quickLook(items: try c.decode([QuickLookItem].self, forKey: .items),
                              index: try c.decodeIfPresent(Int.self, forKey: .index))
        case "openCustomAppWindow":
            let slug = try c.decode(String.self, forKey: .slug)
            guard AppsHomeLogic.validateSlug(slug) == nil else {
                throw DecodingError.dataCorruptedError(forKey: .slug, in: c, debugDescription: "invalid custom app slug \(slug)")
            }
            self = .openCustomAppWindow(slug: slug)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown page message type \(type)")
        }
    }

    /// Decodes a message as handed over by WebKit (a JSON-compatible NSObject graph).
    public static func decode(fromJSONObject object: Any) throws -> PageMessage {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a JSON object"))
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(PageMessage.self, from: data)
    }
}

// MARK: - Shell -> page

public enum ShellCommandName: String, Codable, Sendable, Hashable, CaseIterable {
    case openCommandMenu, newChat, toggleCompanion, showShortcuts, find, focusContent
}

/// Shell → page. Encoded to JSON and dispatched as the detail of a "vesper-native" CustomEvent.
public enum NativeCommand: Sendable, Equatable, Codable {
    case navigate(path: String)
    /// `newTab`: the row was ⌘-clicked, so the page opens its href in a new tab. Sent only when true.
    case navActivate(navigatorId: String, itemId: String, newTab: Bool = false)
    case navAction(navigatorId: String, actionId: String, itemId: String? = nil, menuItemId: String? = nil)
    case navPicker(navigatorId: String, pickerId: String, value: String)
    case navFilter(navigatorId: String, filterId: String, value: String, checked: Bool)
    case navSearch(navigatorId: String, searchId: String, value: String)
    case navToggle(navigatorId: String, itemId: String, expanded: Bool)
    case toolbarAction(itemId: String, menuItemId: String? = nil)
    /// An item chosen from the title's menu.
    case titleAction(menuItemId: String)
    /// A right-rail button, or an item from its menu.
    case railAction(itemId: String, menuItemId: String? = nil)
    case inspectorVisibility(open: Bool)
    case inspectorSelectTab(tabId: String)
    case inspectorAction(tabId: String, actionId: String, itemId: String? = nil, menuItemId: String? = nil)
    case inspectorChange(tabId: String, fieldId: String, value: String)
    case inspectorToggle(tabId: String, fieldId: String, checked: Bool)
    case companionContext(CompanionContext)
    case panelContext(InspectorPanelContext)
    case panelEvent(tabId: String, event: String, payloadJson: String? = nil)
    /// macOS's accent colour ("#RRGGBB") and effective appearance, plus optional user appearance preferences.
    case appearance(accent: String, mode: ColorMode, themePref: AppearanceMode? = nil, settingsJson: String? = nil)
    /// `query` only means something for openCommandMenu: the text to open the palette with.
    case command(ShellCommandName, query: String? = nil)
    /// `selectedId`/`value`: `nil` omits the field, `.some(nil)` sends JSON null, `.some("x")` a value.
    case reply(requestId: String, ok: Bool, selectedId: String?? = nil, value: String?? = nil, error: String? = nil)
    case toastEvent(id: String, event: ToastEventKind)
    case paletteOpen(request: CommandPaletteRequest)

    private enum Keys: String, CodingKey {
        case v, type, path, navigatorId, itemId, actionId, menuItemId, pickerId, searchId, filterId, value, expanded, checked, name, query, newTab
        case open, tabId, fieldId, context, event, payloadJson
        case accent, mode, themePref, settingsJson
        case requestId, ok, selectedId, error
        case id, request
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard try c.decode(Int.self, forKey: .v) == nativeProtocolVersion else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "unsupported protocol version")
        }
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "navigate": self = .navigate(path: try c.decode(String.self, forKey: .path))
        case "nav.activate":
            self = .navActivate(navigatorId: try c.decode(String.self, forKey: .navigatorId), itemId: try c.decode(String.self, forKey: .itemId),
                                newTab: try c.decodeIfPresent(Bool.self, forKey: .newTab) ?? false)
        case "nav.action":
            self = .navAction(navigatorId: try c.decode(String.self, forKey: .navigatorId), actionId: try c.decode(String.self, forKey: .actionId),
                              itemId: try c.decodeIfPresent(String.self, forKey: .itemId), menuItemId: try c.decodeIfPresent(String.self, forKey: .menuItemId))
        case "nav.picker":
            self = .navPicker(navigatorId: try c.decode(String.self, forKey: .navigatorId), pickerId: try c.decode(String.self, forKey: .pickerId), value: try c.decode(String.self, forKey: .value))
        case "nav.filter":
            self = .navFilter(navigatorId: try c.decode(String.self, forKey: .navigatorId), filterId: try c.decode(String.self, forKey: .filterId),
                              value: try c.decode(String.self, forKey: .value), checked: try c.decode(Bool.self, forKey: .checked))
        case "appearance":
            self = .appearance(
                accent: try c.decode(String.self, forKey: .accent),
                mode: try c.decode(ColorMode.self, forKey: .mode),
                themePref: try c.decodeIfPresent(AppearanceMode.self, forKey: .themePref),
                settingsJson: try c.decodeIfPresent(String.self, forKey: .settingsJson)
            )
        case "nav.search":
            self = .navSearch(navigatorId: try c.decode(String.self, forKey: .navigatorId), searchId: try c.decode(String.self, forKey: .searchId), value: try c.decode(String.self, forKey: .value))
        case "nav.toggle":
            self = .navToggle(navigatorId: try c.decode(String.self, forKey: .navigatorId), itemId: try c.decode(String.self, forKey: .itemId), expanded: try c.decode(Bool.self, forKey: .expanded))
        case "toolbar.action":
            self = .toolbarAction(itemId: try c.decode(String.self, forKey: .itemId), menuItemId: try c.decodeIfPresent(String.self, forKey: .menuItemId))
        case "title.action":
            self = .titleAction(menuItemId: try c.decode(String.self, forKey: .menuItemId))
        case "rail.action":
            self = .railAction(itemId: try c.decode(String.self, forKey: .itemId), menuItemId: try c.decodeIfPresent(String.self, forKey: .menuItemId))
        case "inspector.visibility":
            self = .inspectorVisibility(open: try c.decode(Bool.self, forKey: .open))
        case "inspector.selectTab":
            self = .inspectorSelectTab(tabId: try c.decode(String.self, forKey: .tabId))
        case "inspector.action":
            self = .inspectorAction(tabId: try c.decode(String.self, forKey: .tabId), actionId: try c.decode(String.self, forKey: .actionId),
                                    itemId: try c.decodeIfPresent(String.self, forKey: .itemId), menuItemId: try c.decodeIfPresent(String.self, forKey: .menuItemId))
        case "inspector.change":
            self = .inspectorChange(tabId: try c.decode(String.self, forKey: .tabId), fieldId: try c.decode(String.self, forKey: .fieldId), value: try c.decode(String.self, forKey: .value))
        case "inspector.toggle":
            self = .inspectorToggle(tabId: try c.decode(String.self, forKey: .tabId), fieldId: try c.decode(String.self, forKey: .fieldId), checked: try c.decode(Bool.self, forKey: .checked))
        case "companion.context":
            self = .companionContext(try c.decode(CompanionContext.self, forKey: .context))
        case "panel.context":
            self = .panelContext(try c.decode(InspectorPanelContext.self, forKey: .context))
        case "panel.event":
            self = .panelEvent(tabId: try c.decode(String.self, forKey: .tabId),
                               event: try c.decode(String.self, forKey: .event),
                               payloadJson: try c.decodeIfPresent(String.self, forKey: .payloadJson))
        case "command": self = .command(try c.decode(ShellCommandName.self, forKey: .name), query: try c.decodeIfPresent(String.self, forKey: .query))
        case "reply":
            let selected: String??
            if c.contains(.selectedId) {
                selected = .some(try c.decodeIfPresent(String.self, forKey: .selectedId))
            } else {
                selected = nil
            }
            let value: String??
            if c.contains(.value) {
                value = .some(try c.decodeIfPresent(String.self, forKey: .value))
            } else {
                value = nil
            }
            self = .reply(requestId: try c.decode(String.self, forKey: .requestId), ok: try c.decode(Bool.self, forKey: .ok),
                          selectedId: selected, value: value, error: try c.decodeIfPresent(String.self, forKey: .error))
        case "toast.event":
            self = .toastEvent(id: try c.decode(String.self, forKey: .id), event: try c.decode(ToastEventKind.self, forKey: .event))
        case "palette.open":
            self = .paletteOpen(request: try c.decode(CommandPaletteRequest.self, forKey: .request))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown command type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(nativeProtocolVersion, forKey: .v)
        switch self {
        case .navigate(let path):
            try c.encode("navigate", forKey: .type); try c.encode(path, forKey: .path)
        case .navActivate(let nav, let item, let newTab):
            try c.encode("nav.activate", forKey: .type); try c.encode(nav, forKey: .navigatorId); try c.encode(item, forKey: .itemId)
            if newTab { try c.encode(true, forKey: .newTab) }
        case .navAction(let nav, let action, let item, let menuItem):
            try c.encode("nav.action", forKey: .type); try c.encode(nav, forKey: .navigatorId); try c.encode(action, forKey: .actionId)
            try c.encodeIfPresent(item, forKey: .itemId); try c.encodeIfPresent(menuItem, forKey: .menuItemId)
        case .navPicker(let nav, let picker, let value):
            try c.encode("nav.picker", forKey: .type); try c.encode(nav, forKey: .navigatorId); try c.encode(picker, forKey: .pickerId); try c.encode(value, forKey: .value)
        case .navFilter(let nav, let filter, let value, let checked):
            try c.encode("nav.filter", forKey: .type); try c.encode(nav, forKey: .navigatorId); try c.encode(filter, forKey: .filterId)
            try c.encode(value, forKey: .value); try c.encode(checked, forKey: .checked)
        case .appearance(let accent, let mode, let themePref, let settingsJson):
            try c.encode("appearance", forKey: .type)
            try c.encode(accent, forKey: .accent)
            try c.encode(mode, forKey: .mode)
            try c.encodeIfPresent(themePref, forKey: .themePref)
            try c.encodeIfPresent(settingsJson, forKey: .settingsJson)
        case .navSearch(let nav, let search, let value):
            try c.encode("nav.search", forKey: .type); try c.encode(nav, forKey: .navigatorId); try c.encode(search, forKey: .searchId); try c.encode(value, forKey: .value)
        case .navToggle(let nav, let item, let expanded):
            try c.encode("nav.toggle", forKey: .type); try c.encode(nav, forKey: .navigatorId); try c.encode(item, forKey: .itemId); try c.encode(expanded, forKey: .expanded)
        case .toolbarAction(let item, let menuItem):
            try c.encode("toolbar.action", forKey: .type); try c.encode(item, forKey: .itemId); try c.encodeIfPresent(menuItem, forKey: .menuItemId)
        case .titleAction(let menuItem):
            try c.encode("title.action", forKey: .type); try c.encode(menuItem, forKey: .menuItemId)
        case .railAction(let item, let menuItem):
            try c.encode("rail.action", forKey: .type); try c.encode(item, forKey: .itemId); try c.encodeIfPresent(menuItem, forKey: .menuItemId)
        case .inspectorVisibility(let open):
            try c.encode("inspector.visibility", forKey: .type); try c.encode(open, forKey: .open)
        case .inspectorSelectTab(let tabId):
            try c.encode("inspector.selectTab", forKey: .type); try c.encode(tabId, forKey: .tabId)
        case .inspectorAction(let tabId, let actionId, let itemId, let menuItemId):
            try c.encode("inspector.action", forKey: .type); try c.encode(tabId, forKey: .tabId); try c.encode(actionId, forKey: .actionId)
            try c.encodeIfPresent(itemId, forKey: .itemId); try c.encodeIfPresent(menuItemId, forKey: .menuItemId)
        case .inspectorChange(let tabId, let fieldId, let value):
            try c.encode("inspector.change", forKey: .type); try c.encode(tabId, forKey: .tabId); try c.encode(fieldId, forKey: .fieldId); try c.encode(value, forKey: .value)
        case .inspectorToggle(let tabId, let fieldId, let checked):
            try c.encode("inspector.toggle", forKey: .type); try c.encode(tabId, forKey: .tabId); try c.encode(fieldId, forKey: .fieldId); try c.encode(checked, forKey: .checked)
        case .companionContext(let context):
            try c.encode("companion.context", forKey: .type); try c.encode(context, forKey: .context)
        case .panelContext(let context):
            try c.encode("panel.context", forKey: .type); try c.encode(context, forKey: .context)
        case .panelEvent(let tabId, let event, let payloadJson):
            try c.encode("panel.event", forKey: .type); try c.encode(tabId, forKey: .tabId); try c.encode(event, forKey: .event)
            try c.encodeIfPresent(payloadJson, forKey: .payloadJson)
        case .command(let name, let query):
            try c.encode("command", forKey: .type); try c.encode(name, forKey: .name)
            try c.encodeIfPresent(query, forKey: .query)
        case .reply(let requestId, let ok, let selected, let value, let error):
            try c.encode("reply", forKey: .type); try c.encode(requestId, forKey: .requestId); try c.encode(ok, forKey: .ok)
            if let selected { try c.encode(selected, forKey: .selectedId) }
            if let value { try c.encode(value, forKey: .value) }
            try c.encodeIfPresent(error, forKey: .error)
        case .toastEvent(let id, let event):
            try c.encode("toast.event", forKey: .type); try c.encode(id, forKey: .id); try c.encode(event, forKey: .event)
        case .paletteOpen(let request):
            try c.encode("palette.open", forKey: .type); try c.encode(request, forKey: .request)
        }
    }

    /// The JSON text of this command.
    public func jsonString() throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try enc.encode(self), as: UTF8.self)
    }
}
