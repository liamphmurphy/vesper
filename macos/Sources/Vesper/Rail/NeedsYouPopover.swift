import AppKit
import SwiftUI
import VesperCore

/// The Needs-you popover, anchored to the rail's button: the web tray's two tabs (Needs you, and
/// Updates that ask nothing), with Approve/Decline, Reply and a labelled Open per kind. It reads the same inbox the
/// notifications and the Dock badge do, so it updates live while it is open.
@MainActor
final class NeedsYouPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var hostController: NSHostingController<NeedsYouContent>?
    private let services: () -> SystemServices?
    private let navigate: (String) -> Void

    init(services: @escaping () -> SystemServices?, navigate: @escaping (String) -> Void) {
        self.services = services
        self.navigate = navigate
        super.init()
        popover.behavior = .semitransient
        popover.animates = true
        popover.delegate = self
    }

    func toggle(relativeTo button: NSView) {
        if popover.isShown { close(); return }
        guard let services = services() else { return }
        let root = NeedsYouContent(
            inbox: services.railInbox, services: services,
            open: { [weak self] item in
                self?.close()
                if InboxTray.shouldMarkRead(item) { self?.services()?.railMarkRead(item.id) }
                self?.go(item.href.isEmpty ? "/inbox" : item.href)
            },
            showAll: { [weak self] in
                self?.close()
                self?.navigate("/inbox")
            },
            close: { [weak self] in self?.close() })
        let host: NSHostingController<NeedsYouContent>
        if let existing = hostController {
            existing.rootView = root
            host = existing
        } else {
            let created = NSHostingController(rootView: root)
            created.sizingOptions = [.preferredContentSize]
            hostController = created
            popover.contentViewController = created
            host = created
        }
        let fitted = host.sizeThatFits(in: CGSize(width: NeedsYouContent.width, height: 520))
        if fitted.width > 0 && fitted.height > 0 {
            popover.contentSize = NSSize(width: NeedsYouContent.width, height: min(520, ceil(fitted.height)))
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minX)
    }

    /// An app route navigates in the window; a GitHub URL opens in the default browser.
    private func go(_ href: String) {
        if InboxTray.isExternalHref(href), let url = URL(string: href) { NSWorkspace.shared.open(url) } else { navigate(href) }
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
    }
}

private struct NeedsYouContent: View {
    let inbox: RailInbox
    let services: SystemServices
    let open: (InboxItem) -> Void
    let showAll: () -> Void
    let close: () -> Void

    @State private var tab: InboxTrayTab = .needs
    @State private var selection: String?
    @State private var busy: Set<String> = []
    @State private var messages: [String: String] = [:]
    @State private var drafts: [String: String] = [:]
    @FocusState private var listFocused: Bool

    static let width: CGFloat = 380

    private var list: [InboxItem] { tab == .needs ? inbox.tray.needs : inbox.tray.updates }

    var body: some View {
        let items = list
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tabButton(.needs, "Needs you")
                tabButton(.updates, "Updates")
                Spacer()
                if tab == .updates && !inbox.tray.unread.isEmpty {
                    Button("Mark all read") { inbox.tray.unread.forEach(services.railMarkRead) }
                        .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: tab == .needs ? "checkmark.circle" : "tray").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text(tab == .needs ? "Nothing needs you" : "No updates yet — finished runs and replies show up here")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 36).padding(.horizontal, 20)
            } else {
                ScrollViewReader { proxy in
                    let scroll = ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(items, id: \.id) { item in
                                row(item).id(item.id)
                            }
                        }
                        .padding(6)
                    }
                    // Avoid `.fixedSize(vertical: true)` on large lists because it defeats
                    // `LazyVStack` by forcing every row to measure synchronously on frame 0.
                    if items.count <= 5 {
                        scroll
                            .frame(maxHeight: 420)
                            .fixedSize(horizontal: false, vertical: true)
                            .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
                    } else {
                        scroll
                            .frame(height: 420)
                            .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
                    }
                }
            }
            Divider()
            Button(action: showAll) {
                HStack {
                    Text("Show all in Inbox")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: Self.width)
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onAppear {
            listFocused = true
            if selection == nil { selection = list.first?.id }
        }
        .onChange(of: list.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = ids.first }
        }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.leftArrow) { switchTab(); return .handled }
        .onKeyPress(.rightArrow) { switchTab(); return .handled }
        .onKeyPress(.return) {
            guard let item = list.first(where: { $0.id == selection }) else { return .ignored }
            open(item)
            return .handled
        }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "jkad")) { press in
            switch press.characters {
            case "j": move(1)
            case "k": move(-1)
            default:
                guard let item = list.first(where: { $0.id == selection }), RailItemActions.canDecide(item) else { return .ignored }
                decide(item, approve: press.characters == "a")
            }
            return .handled
        }
    }

    private func tabButton(_ target: InboxTrayTab, _ title: String) -> some View {
        let on = tab == target
        return Button {
            select(target)
        } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                if target == .needs {
                    Text("\(inbox.tray.needs.count)").font(.caption.monospacedDigit())
                        .foregroundStyle(inbox.tray.needs.isEmpty ? Color.secondary : Tone.human.color)
                } else {
                    Text("\(inbox.tray.updates.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if !inbox.tray.unread.isEmpty { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.primary.opacity(0.1) : .clear))
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func select(_ target: InboxTrayTab) {
        tab = target
        selection = (target == .needs ? inbox.tray.needs : inbox.tray.updates).first?.id
        listFocused = true
    }

    private func switchTab() { select(tab == .needs ? .updates : .needs) }

    /// Up and down wrap around, as the web's step does.
    private func move(_ delta: Int) {
        let ids = list.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = selection.flatMap({ ids.firstIndex(of: $0) }) else {
            selection = delta > 0 ? ids.first : ids.last
            return
        }
        selection = ids[(current + delta + ids.count) % ids.count]
    }

    @ViewBuilder
    private func row(_ item: InboxItem) -> some View {
        let isBusy = busy.contains(item.id)
        let unread = !item.needsYou && InboxTray.isOpen(item)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if unread { Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityLabel("unread") }
                Text(item.title).font(.system(size: 13, weight: unread || item.needsYou ? .semibold : .regular))
                    .foregroundStyle(unread || item.needsYou ? Color.primary : Color.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(RailItemActions.age(item.createdAt)).font(.caption).foregroundStyle(.secondary)
            }
            let subtitle = RailItemActions.subtitle(item)
            let kind = NotificationLogic.kindLabels[item.kind]
            if !subtitle.isEmpty || kind != nil {
                Text([kind, subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if RailItemActions.canReply(item) { replyField(item, disabled: isBusy) }
            actions(item, isBusy: isBusy)
            if let message = messages[item.id] {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(selection == item.id ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            selection = item.id
            open(item)
        }
    }

    /// The buttons per the web's trayAction. Updates have none: the row itself opens.
    @ViewBuilder
    private func actions(_ item: InboxItem, isBusy: Bool) -> some View {
        if let action = RailItemActions.action(item) {
            HStack(spacing: 8) {
                if RailItemActions.canDecide(item) {
                    Button("Approve") { decide(item, approve: true) }.buttonStyle(.borderedProminent).tint(.green)
                    Button("Decline") { decide(item, approve: false) }.buttonStyle(.bordered)
                } else {
                    Button(openLabel(action)) { open(item) }.buttonStyle(.bordered)
                }
                if isBusy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .controlSize(.small)
            .disabled(isBusy)
        }
    }

    /// Reply and approve that can't be done inline fall back to a plain Open, like a kind with no inline action.
    private func openLabel(_ action: InboxTrayAction) -> String {
        switch action {
        case .dispatch: return "Start"
        case .open(let label): return label
        case .approve, .reply: return "Open"
        }
    }

    private func replyField(_ item: InboxItem, disabled: Bool) -> some View {
        HStack(spacing: 6) {
            TextField(RailItemActions.replyPlaceholder(item), text: Binding(
                get: { drafts[item.id] ?? "" }, set: { drafts[item.id] = $0 }))
                .textFieldStyle(.roundedBorder)
                .onSubmit { reply(item) }
            Button { reply(item) } label: { Image(systemName: "arrow.up.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .disabled(disabled || (drafts[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send reply")
        }
        .controlSize(.small)
        .disabled(disabled)
    }

    private func decide(_ item: InboxItem, approve: Bool) {
        run(item) { await services.railDecide(item, approve: approve) }
    }

    private func reply(_ item: InboxItem) {
        let text = drafts[item.id] ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        run(item) {
            let error = await services.railReply(item, text: text)
            if error == nil { drafts[item.id] = "" }
            return error
        }
    }

    private func run(_ item: InboxItem, _ work: @escaping () async -> String?) {
        guard !busy.contains(item.id) else { return }
        busy.insert(item.id)
        messages[item.id] = nil
        Task { @MainActor in
            let error = await work()
            busy.remove(item.id)
            messages[item.id] = error
        }
    }
}
