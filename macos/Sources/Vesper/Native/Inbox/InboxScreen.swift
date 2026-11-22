import AppKit
import SwiftUI
import VesperCore

/// The keys the detail pane handles for the selected item (web PaneActions): the list's key
/// handler calls them.
struct InboxPaneActions {
    var approve: (() -> Void)?
    var deny: (() -> Void)?
    /// R: focus the reply or note box.
    var focus: (() -> Void)?
    var done: (() -> Void)?
}

/// The Inbox's per-tab state: view, sort, project filter and selection.
@MainActor
@Observable
final class InboxModel {
    var view: InboxLogic.View = .open
    var sort: InboxLogic.Sort = .oldest
    /// "" is All projects. Remembered across launches; the web keeps its own in the page's storage.
    var project: String = UserDefaults.standard.string(forKey: InboxModel.projectKey) ?? "" {
        didSet { UserDefaults.standard.set(project, forKey: Self.projectKey) }
    }
    /// The item the pane shows (the keyboard's focus), and its slot so focus keeps it when the item leaves.
    var focused: String?
    var focusedIndex = 0
    /// Every selected row (⌘/⇧-click); always includes `focused` when it's set.
    var selection: Set<String> = []
    var anchor: String?
    /// Items whose action was sent: they show "Sent" until the live update moves them.
    var sent: Set<String> = []
    var pane = InboxPaneActions()
    var listFocused = false

    static let projectKey = "VesperNativeInboxProject"

    func select(_ id: String, ids: [String], modifiers: NSEvent.ModifierFlags = []) {
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if modifiers.contains(.shift), let anchor, let from = ids.firstIndex(of: anchor), let to = ids.firstIndex(of: id) {
            selection = Set(ids[min(from, to)...max(from, to)])
        } else {
            selection = [id]
            anchor = id
        }
        focused = id
        focusedIndex = ids.firstIndex(of: id) ?? 0
    }

    func resetSelection() {
        focused = nil
        focusedIndex = 0
        selection = []
        anchor = nil
    }
}

/// /inbox: everything waiting on the person, grouped by urgency, with the selected item's details
/// and actions beside it (web app/(app)/inbox, desktop layout).
struct InboxScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @State private var model = InboxModel()
    @FocusState private var listHasFocus: Bool

    private var request: APIRequest<API.ListInboxResponse> { API.listInbox(project: model.project.isEmpty ? nil : model.project) }
    private static let bootstrap = API.getBootstrap()

    var body: some View {
        let entry = context.store.entry(request)
        let items = entry.data?.items ?? []
        let groups = InboxLogic.group(items, view: model.view, sort: model.sort)
        let ids = groups.flatMap { $0.items.map(\.id) }
        let current = InboxLogic.nextSelection(ids, selected: model.focused, lastIndex: model.focusedIndex)
        let item = items.first { $0.id == current }
        let openCount = items.filter(InboxLogic.isOpen).count

        HStack(spacing: 0) {
            VStack(spacing: 0) {
                filterBar(openCount: openCount, doneCount: items.count - openCount)
                Divider().overlay(theme.palette.border)
                list(entry: entry, groups: groups, ids: ids, current: current, doneCount: items.count - openCount)
                shortcutFooter
            }
            .frame(minWidth: 480, maxWidth: .infinity)
            if let item {
                Divider().overlay(theme.palette.border)
                InboxDetailPane(item: item, model: model, actions: actions(items: items))
                    .id(item.id)
                    .frame(minWidth: 380, idealWidth: 440, maxWidth: 560)
            }
        }
        .onChange(of: ids) { _, newIds in
            let next = InboxLogic.nextSelection(newIds, selected: model.focused, lastIndex: model.focusedIndex)
            if next != model.focused {
                model.focused = next
                model.selection = next.map { [$0] } ?? []
            }
            model.focusedIndex = next.flatMap { newIds.firstIndex(of: $0) } ?? 0
            model.selection.formIntersection(newIds)
            if let next { model.selection.insert(next) }
            context.find.texts = groups.flatMap { $0.items.map(Self.searchText) }
        }
        .onChange(of: context.find.current) { _, index in
            guard let index, index < ids.count else { return }
            model.select(ids[index], ids: ids)
        }
        .onChange(of: openCount, initial: true) { _, count in publishChrome(openCount: count) }
        .task(id: model.project) {
            context.store.load(request)
            context.store.load(Self.bootstrap)
        }
        .onAppear {
            context.store.observe(request)
            context.onCommand = { [context] command in
                if case .toolbarAction(itemId: "inbox.shortcuts", _) = command { context.showShortcuts() }
            }
            listHasFocus = true
        }
        .onDisappear { context.store.stopObserving(request.key) }
        .onKeyPress(phases: .down) { press in handleKey(press, ids: ids, item: item) }
    }

    private static func searchText(_ item: API.InboxItem) -> String {
        [item.title, item.summary, item.ticketKey, item.project, item.agent?.name ?? ""].joined(separator: " ")
    }

    private func publishChrome(openCount: Int) {
        context.chrome = NativeChrome(
            title: "Inbox",
            subtitle: openCount > 0 ? "\(openCount) waiting on you" : "Nothing waiting on you",
            toolbarItems: [ShellToolbarItem(id: "inbox.shortcuts", label: "Shortcuts", icon: "bolt", kind: .button, showsLabel: true)]
        )
    }

    // MARK: Filter bar

    private func filterBar(openCount: Int, doneCount: Int) -> some View {
        let projects = (context.store.entry(Self.bootstrap).data?.projects ?? []).filter { !$0.archived }
        return HStack(spacing: 12) {
            Picker("Show", selection: Binding(get: { model.view }, set: { model.view = $0; model.resetSelection() })) {
                Text("Open \(openCount)").tag(InboxLogic.View.open)
                Text("Done \(doneCount)").tag(InboxLogic.View.done)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Menu {
                Picker("Sort", selection: Binding(get: { model.sort }, set: { model.sort = $0 })) {
                    Text("Longest wait first").tag(InboxLogic.Sort.oldest)
                    Text("Newest first").tag(InboxLogic.Sort.newest)
                }
                .pickerStyle(.inline)
            } label: {
                Text(model.sort == .oldest ? "Longest wait first" : "Newest first")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Text("Project").foregroundStyle(theme.palette.tertiaryText)
            Menu {
                Picker("Filter space", selection: Binding(get: { model.project }, set: { model.project = $0; model.resetSelection() })) {
                    Text("All").tag("")
                    ForEach(projects, id: \.key) { Text($0.name).tag($0.key) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(projects.first { $0.key == model.project }?.name ?? "All")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .vesperText(.small, theme)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: List

    @ViewBuilder
    private func list(entry: QueryEntry<API.ListInboxResponse>, groups: [InboxLogic.Group<API.InboxItem>], ids: [String],
                      current: String?, doneCount: Int) -> some View {
        if entry.data == nil, entry.error == nil {
            VStack(spacing: 12) { ForEach(0..<3, id: \.self) { _ in SkeletonBar(height: 60) } }
                .padding(20)
                .frame(maxHeight: .infinity, alignment: .top)
        } else if entry.data == nil, entry.error != nil {
            QueryErrorView(message: "Couldn\u{2019}t load your inbox.") { Task { await context.store.refetch(request) } }
                .frame(maxHeight: .infinity, alignment: .top)
        } else if groups.isEmpty {
            ScrollView {
                if model.view == .open {
                    InboxAllClear(project: model.project, done: doneCount) { model.view = .done }
                } else {
                    VStack(spacing: 12) {
                        Text("Nothing done yet").vesperText(.heading, theme)
                        Text("Items you resolve or mark done appear here until they change again.")
                            .vesperText(.body, theme).foregroundStyle(theme.palette.secondaryText)
                        Button("Show open") { model.view = .open }.buttonStyle(.vesper())
                    }
                    .padding(.vertical, 56)
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.items, id: \.id) { item in
                                    row(item, ids: ids, current: current).id(item.id)
                                }
                            } header: {
                                HStack(spacing: 8) {
                                    Text(group.label)
                                    Text("\(group.items.count)").font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                                        .foregroundStyle(theme.palette.tertiaryText)
                                }
                                .font(.system(size: theme.pointSize(.small), weight: .medium))
                                .foregroundStyle(theme.palette.secondaryText)
                                .padding(.horizontal, 20)
                                .frame(maxWidth: .infinity, minHeight: 33, alignment: .leading)
                                .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))
                            }
                        }
                    }
                }
                .focusable()
                .focused($listHasFocus)
                .focusEffectDisabled()
                .onChange(of: current) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
        }
    }

    private func row(_ item: API.InboxItem, ids: [String], current: String?) -> some View {
        let kind = InboxLogic.kind(item.kind.rawValue)
        let isCurrent = item.id == current
        let isSelected = model.selection.contains(item.id) || isCurrent
        let tone = switch kind.tone { case .human: "human"; case .blocked: "blocked"; case .info: "review" }
        let findHit = context.find.matches(Self.searchText(item))
        return HStack(spacing: 12) {
            if let agent = item.agent {
                WorkPersonaAvatarView(agent: agent, size: 24)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.tertiaryText)
                    .frame(width: 24, height: 24)
                    .background(theme.swiftUIColor("track", fallback: Color.secondary.opacity(0.15)), in: RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    TonePill(label: kind.label, tone: tone)
                    let scope = item.ticketKey.isEmpty ? item.project : item.ticketKey
                    if !scope.isEmpty {
                        Text(scope).font(.system(size: theme.pointSize(.small), design: .monospaced)).foregroundStyle(theme.palette.tertiaryText)
                    }
                    Text(item.title).font(.system(size: theme.pointSize(.body), weight: .semibold)).lineLimit(1)
                }
                (Text(item.agent.map { "\($0.name) · " } ?? "").foregroundStyle(theme.palette.secondaryText)
                    + Text(item.summary).foregroundStyle(theme.palette.tertiaryText))
                    .font(.system(size: theme.pointSize(.body)))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.sent.contains(item.id) {
                Text("Sent").font(.system(size: theme.pointSize(.small), weight: .medium)).foregroundStyle(theme.palette.accent)
            } else {
                Text(APIDate.waited(item.createdAt))
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(APIDate.longWait(item.createdAt) ? theme.swiftUIColor("pill-human-fg", fallback: .orange) : theme.palette.tertiaryText)
                    .help(APIDate.parse(item.createdAt)?.formatted(date: .abbreviated, time: .shortened) ?? "")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .background(isSelected ? theme.palette.selected : findHit ? theme.palette.hover : .clear)
        .overlay(alignment: .leading) { if isCurrent { Rectangle().fill(theme.palette.accent).frame(width: 2) } }
        .overlay(alignment: .bottom) { Rectangle().fill(theme.swiftUIColor("border-subtle", fallback: theme.palette.rowBorder)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(item) }
        .onTapGesture {
            model.select(item.id, ids: ids, modifiers: NSEvent.modifierFlags)
            listHasFocus = true
        }
        .contextMenu { contextMenu(for: item, ids: ids) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private func contextMenu(for item: API.InboxItem, ids: [String]) -> some View {
        let targets = model.selection.contains(item.id) && model.selection.count > 1 ? Array(model.selection) : [item.id]
        let items = context.store.entry(request).data?.items ?? []
        let chosen = items.filter { targets.contains($0.id) }
        Button("Open") { open(item) }
        if !InboxLogic.isExternalHref(item.href) {
            Button("Open in New Tab") { context.openInNewTab(item.href) }
        }
        Button("Copy Link") { copyLink(item) }
        Divider()
        let open = chosen.filter(InboxLogic.isOpen)
        if !open.isEmpty {
            Button(open.count > 1 ? "Mark \(open.count) Done" : "Mark Done") { markDone(open.map(\.id)) }
        }
        let done = chosen.filter { !InboxLogic.isOpen($0) && !$0.resolved }
        if !done.isEmpty {
            Button(done.count > 1 ? "Reopen \(done.count)" : "Reopen") { reopen(done.map(\.id)) }
        }
        if targets.count == 1, item.kind.rawValue == "approval", InboxLogic.isOpen(item) {
            Divider()
            Button("Approve") { model.select(item.id, ids: ids); model.pane.approve?() }
            Button("Deny") { model.select(item.id, ids: ids); model.pane.deny?() }
        }
    }

    private var shortcutFooter: some View {
        HStack(spacing: 16) {
            hint(["J", "K"], "move"); hint(["A"], "approve"); hint(["D"], "deny"); hint(["R"], "reply")
            hint(["E"], "done"); hint(["↵"], "open"); hint(["?"], "all shortcuts")
            Spacer()
        }
        .font(.system(size: theme.pointSize(.small)))
        .foregroundStyle(theme.palette.tertiaryText)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(theme.palette.border).frame(height: 1) }
        .accessibilityHidden(true)
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { KeyCap(key: $0) }
            Text(label)
        }
    }

    // MARK: Actions

    private func handleKey(_ press: KeyPress, ids: [String], item: API.InboxItem?) -> KeyPress.Result {
        guard listHasFocus, press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        switch press.key {
        case .return:
            guard let item else { return .ignored }
            open(item)
            return .handled
        default:
            break
        }
        switch press.characters.lowercased() {
        case "j", "k":
            if let next = InboxLogic.step(ids, selected: item?.id, by: press.characters.lowercased() == "j" ? 1 : -1) {
                model.select(next, ids: ids)
            }
            return .handled
        case "?":
            context.showShortcuts()
            return .handled
        case "a": return run(model.pane.approve)
        case "d": return run(model.pane.deny)
        case "r":
            guard let focus = model.pane.focus else { return .ignored }
            listHasFocus = false
            focus()
            return .handled
        case "e":
            let targets = model.selection.count > 1 ? Array(model.selection) : (item.map { [$0.id] } ?? [])
            let items = context.store.entry(request).data?.items ?? []
            let open = items.filter { targets.contains($0.id) && InboxLogic.isOpen($0) }.map(\.id)
            guard !open.isEmpty else { return .ignored }
            markDone(open)
            return .handled
        default:
            return .ignored
        }
    }

    private func run(_ action: (() -> Void)?) -> KeyPress.Result {
        guard let action else { return .ignored }
        action()
        return .handled
    }

    private func open(_ item: API.InboxItem) {
        if InboxLogic.isExternalHref(item.href) { context.openExternal(item.href) } else { context.navigate(item.href) }
    }

    private func copyLink(_ item: API.InboxItem) {
        let link = InboxLogic.isExternalHref(item.href) ? item.href : (DeepLinks.hrefToVesperLink(item.href) ?? item.href)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    private func actions(items: [API.InboxItem]) -> InboxActions {
        InboxActions(
            markDone: { markDone($0) },
            sent: { model.sent.insert($0) },
            leave: { listHasFocus = true },
            register: { model.pane = $0 }
        )
    }

    /// Marks items done at once, then lets the person take it back from the toast or with ⌘Z.
    private func markDone(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        setRead(ids, read: true)
        let title = ids.count == 1 ? "Marked done" : "Marked \(ids.count) done"
        context.showToast(ToastItemModel(id: "inbox.done.\(ids.sorted().joined(separator: ","))", title: title, actionLabel: "Undo")) { event in
            if event == .action { reopen(ids) }
        }
        context.undoManager?.registerUndo(withTarget: model) { _ in
            MainActor.assumeIsolated { reopen(ids) }
        }
        context.undoManager?.setActionName(title)
    }

    private func reopen(_ ids: [String]) {
        setRead(ids, read: false)
    }

    private func setRead(_ ids: [String], read: Bool) {
        let list = request
        Task {
            for (index, id) in ids.enumerated() {
                let call = read ? API.readInboxItem(body: .init(id: id)) : API.unreadInboxItem(body: .init(id: id))
                do {
                    try await context.store.mutate(
                        call,
                        optimistic: [.update(list) { response in
                            for i in response.items.indices where response.items[i].id == id { response.items[i].read = read }
                        }],
                        invalidating: index == ids.count - 1 ? QueryInvalidation(resources: ["inbox"]) : QueryInvalidation()
                    )
                } catch {
                    context.showToast(ToastItemModel(
                        id: "inbox.error.\(id)", title: read ? "Couldn\u{2019}t mark it done" : "Couldn\u{2019}t reopen it",
                        description: (error as? APIError)?.userMessage, tone: .error))
                }
            }
        }
    }
}

/// What the detail pane needs from the list.
struct InboxActions {
    let markDone: ([String]) -> Void
    let sent: (String) -> Void
    /// Esc in a text box: back to the list.
    let leave: () -> Void
    let register: (InboxPaneActions) -> Void
}

/// Nothing waits on the person: say so, and show what is still running (web AllClear).
struct InboxAllClear: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let project: String
    let done: Int
    let showDone: () -> Void

    private static let overviews = API.listAgentOverviews()

    var body: some View {
        let entry = context.store.entry(Self.overviews)
        let running = (entry.data?.agents ?? [])
            .flatMap { o in o.assignments.map { (work: $0, agent: o.agent) } }
            .filter { project.isEmpty || $0.work.ticket.key.hasPrefix("\(project)-") }
        let doneColor = theme.swiftUIColor("state-done", fallback: .green)
        VStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(doneColor)
                .frame(width: 48, height: 48)
                .background(doneColor.opacity(0.1), in: Circle())
                .overlay(Circle().stroke(doneColor.opacity(0.5)))
            Text("All clear").vesperText(.title, theme)
            Text("No approvals, questions, mockups, proposals or failed runs need you in \(project.isEmpty ? "All spaces" : project).")
                .vesperText(.body, theme).foregroundStyle(theme.palette.secondaryText).multilineTextAlignment(.center)
            if done > 0 {
                Button("\(done) done · Show done", action: showDone).buttonStyle(.link).font(.system(size: theme.pointSize(.body)))
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("Still running")
                    Text("\(running.count)").font(.system(size: theme.pointSize(.small), design: .monospaced)).foregroundStyle(theme.palette.tertiaryText)
                }
                .font(.system(size: theme.pointSize(.small), weight: .medium))
                .foregroundStyle(theme.palette.secondaryText)
                .padding(.horizontal, 20).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))
                Divider()
                if entry.data == nil {
                    SkeletonBar(height: 32).padding(16)
                } else if running.isEmpty {
                    HStack(spacing: 4) {
                        Text("No runs in progress.").foregroundStyle(theme.palette.tertiaryText)
                        Button("Dispatch a ready ticket from the Board.") { context.navigate("/tickets?layout=board") }.buttonStyle(.link)
                    }
                    .vesperText(.body, theme)
                    .padding(.horizontal, 20).padding(.vertical, 16)
                } else {
                    ForEach(running, id: \.work.runId) { w in
                        Button { context.navigate("/runs/\(w.work.runId)") } label: {
                            HStack(spacing: 12) {
                                WorkPersonaAvatarView(id: w.agent.id, handle: w.agent.handle, name: w.agent.name, colorIndex: w.agent.colorIndex, size: 20)
                                Text(w.work.ticket.key).font(.system(size: theme.pointSize(.small), design: .monospaced))
                                    .foregroundStyle(theme.palette.tertiaryText).frame(width: 112, alignment: .leading).lineLimit(1)
                                (Text(w.work.ticket.title) + Text(" · \(w.agent.name)").foregroundStyle(theme.palette.tertiaryText))
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Text(w.work.state == "queued" ? "queued" : "\(w.work.state.replacingOccurrences(of: "_", with: " ")) \(APIDate.duration(since: w.work.startedAt))")
                                    .font(.system(size: theme.pointSize(.small))).foregroundStyle(theme.palette.tertiaryText)
                            }
                            .vesperText(.body, theme)
                            .padding(.horizontal, 20).frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                Button("View all runs \u{2192}") { context.navigate("/runs") }
                    .buttonStyle(.link).font(.system(size: theme.pointSize(.body)))
                    .padding(.horizontal, 20).padding(.vertical, 10)
            }
            .background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
            .frame(maxWidth: 580)
            .padding(.top, 16)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 56)
        .frame(maxWidth: .infinity)
        .task { context.store.load(Self.overviews) }
        .onAppear { context.store.observe(Self.overviews) }
        .onDisappear { context.store.stopObserving(Self.overviews.key) }
    }
}
