import AppKit
import SwiftUI
import VesperCore

/// /native-debug (and /native-debug/:id), behind `NativeDebug`: proves a native screen end to end
/// (routing, the shared store with live invalidation, theme tokens, find, context menus, toolbar,
/// title menu and inspector) before real screens move over. Not a product screen.
struct DebugPlaceholderScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    static let rows = (1...40).map { "Sample row \($0)" + ($0 % 5 == 0 ? " · milestone" : "") }
    static let inbox = API.listInbox()
    private static let swatches = ["bg", "surface", "text", "text-secondary", "accent", "state-done", "state-blocked", "state-human"]

    var body: some View {
        let palette = theme.palette
        let inbox = context.store.entry(Self.inbox)
        ScrollViewReader { proxy in
            List {
                Section("Route") {
                    fact("Path", context.match.path)
                    ForEach(context.match.params.sorted(by: { $0.key < $1.key }), id: \.key) { fact(":\($0.key)", $0.value) }
                    ForEach(context.match.query.sorted(by: { $0.key < $1.key }), id: \.key) { fact("?\($0.key)", $0.value) }
                }
                Section("Theme") {
                    HStack(spacing: 6) {
                        ForEach(Self.swatches, id: \.self) { name in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.swiftUIColor(name, fallback: .clear))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border))
                                .frame(width: 22, height: 22)
                                .help(name)
                        }
                    }
                    fact("Text size", "\(theme.textSize ?? "default") (×\(theme.typeScale))")
                    ForEach([ThemeTokens.TextStyle.title, .heading, .body, .small, .mono], id: \.self) { style in
                        Text("\(style.rawValue) \(Int(theme.pointSize(style)))pt").vesperText(style, theme)
                    }
                }
                Section("Data (GET /inbox, refreshed by /events)") {
                    if let items = inbox.data?.items {
                        fact("Items", "\(items.count)")
                    } else if let error = inbox.error {
                        fact("Error", error.userMessage)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if inbox.isFetching { Text("Refreshing…").foregroundStyle(palette.tertiaryText) }
                }
                Section("Rows (⌘F searches these)") {
                    ForEach(Self.rows.indices, id: \.self) { index in
                        row(index)
                            .id(index)
                            .contextMenu {
                                Button("Open in New Tab") { context.openInNewTab("/native-debug/\(index + 1)") }
                                Button("Copy Text") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(Self.rows[index], forType: .string)
                                }
                            }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: context.find.current) { _, index in
                if let index { withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
        }
        .task(id: context.match) {
            context.find.texts = Self.rows
            context.onCommand = { [context] command in Self.handle(command, context) }
            context.chrome = Self.chrome(context, showQuery: context.chrome.inspector.map(Self.showsQuery) ?? true)
            context.store.load(Self.inbox)
        }
        .onAppear { context.store.observe(Self.inbox) }
        .onDisappear { context.store.stopObserving(Self.inbox.key) }
    }

    private func row(_ index: Int) -> some View {
        let text = Self.rows[index]
        let palette = theme.palette
        let isCurrent = context.find.current == index
        return Text(text)
            .vesperText(.body, theme)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isCurrent ? palette.accent.opacity(0.35) : context.find.matches(text) ? palette.selected : .clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { context.navigate("/native-debug/\(index + 1)") }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(theme.palette.secondaryText)
            Spacer()
            Text(value).textSelection(.enabled)
        }
        .vesperText(.body, theme)
    }

    // MARK: Chrome and commands

    static func chrome(_ context: NativeScreenContext, showQuery: Bool) -> NativeChrome {
        let match = context.match
        return NativeChrome(
            title: match.params["id"].map { "Native screen \($0)" } ?? "Native screen",
            subtitle: match.path,
            titleMenu: [MenuItem(id: "copy-path", label: "Copy Path", icon: "copy")],
            toolbarItems: [ShellToolbarItem(id: "refresh", label: "Refresh", icon: "refresh", kind: .button)],
            inspector: InspectorModel(
                id: "native-debug", open: context.chrome.inspector?.open ?? true, activeTabId: "details",
                tabs: [InspectorTab(
                    id: "details", label: "Details", icon: "sliders", kind: .native,
                    sections: [InspectorSection(id: "route", title: "Route", items: [
                        InspectorItem(id: "path", kind: .fact, label: "Path", value: match.path, mono: true),
                        InspectorItem(id: "query", kind: .fact, label: "Query",
                                      value: showQuery ? (match.query.isEmpty ? "none" : match.query.map { "\($0)=\($1)" }.sorted().joined(separator: "&")) : "hidden"),
                        InspectorItem(id: "show-query", kind: .toggle, label: "Show query", checked: showQuery),
                    ])]
                )]
            )
        )
    }

    private static func showsQuery(_ inspector: InspectorModel) -> Bool {
        inspector.tabs.first?.sections?.first?.items.first { $0.id == "show-query" }?.checked ?? true
    }

    @MainActor
    static func handle(_ command: NativeCommand, _ context: NativeScreenContext) {
        switch command {
        case .toolbarAction(itemId: "refresh", _):
            Task { await context.store.refetch(inbox) }
        case .titleAction(menuItemId: "copy-path"):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(context.match.path, forType: .string)
        case .inspectorVisibility(let open):
            context.chrome.inspector?.open = open
        case .inspectorSelectTab(let tabId):
            context.chrome.inspector?.activeTabId = tabId
            context.chrome.inspector?.open = true
        case .inspectorToggle(_, fieldId: "show-query", let checked):
            context.chrome = chrome(context, showQuery: checked)
        default:
            vlog("native-debug: unhandled \(command)")
        }
    }
}
