import AppKit
import SwiftUI
import VesperCore

/// The Needs-you popover, anchored to the rail's button: the inbox items that wait on the person,
/// newest first, with Approve/Decline, Reply and Open on each. It reads the same inbox the
/// notifications and the Dock badge do, so it updates live while it is open.
@MainActor
final class NeedsYouPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
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
            open: { [weak self] href in
                self?.close()
                self?.navigate(href)
            },
            showAll: { [weak self] in
                self?.close()
                self?.navigate("/inbox")
            },
            close: { [weak self] in self?.close() })
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minX)
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
    }
}

private struct NeedsYouContent: View {
    let inbox: RailInbox
    let services: SystemServices
    let open: (String) -> Void
    let showAll: () -> Void
    let close: () -> Void

    @State private var selection: String?
    @State private var busy: Set<String> = []
    @State private var messages: [String: String] = [:]
    @State private var drafts: [String: String] = [:]
    @FocusState private var listFocused: Bool

    private static let width: CGFloat = 380

    var body: some View {
        let items = inbox.needsYou
        VStack(spacing: 0) {
            HStack {
                Text("Needs you").font(.headline)
                if !items.isEmpty {
                    Text("\(items.count)").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Tone.human.color))
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("Nothing needs you").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 36)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(items, id: \.id) { item in
                                row(item).id(item.id)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 420)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
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
            if selection == nil { selection = inbox.needsYou.first?.id }
        }
        .onChange(of: inbox.needsYou.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = ids.first }
        }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) {
            guard let item = inbox.needsYou.first(where: { $0.id == selection }) else { return .ignored }
            open(item.href.isEmpty ? "/inbox" : item.href)
            return .handled
        }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func move(_ delta: Int) {
        let ids = inbox.needsYou.map(\.id)
        guard !ids.isEmpty else { return }
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        selection = ids[min(max(current + delta, 0), ids.count - 1)]
    }

    @ViewBuilder
    private func row(_ item: InboxItem) -> some View {
        let isBusy = busy.contains(item.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
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
            HStack(spacing: 8) {
                if RailItemActions.canDecide(item) {
                    Button("Approve") { decide(item, approve: true) }.buttonStyle(.borderedProminent).tint(.green)
                    Button("Decline") { decide(item, approve: false) }.buttonStyle(.bordered)
                }
                Button("Open") { open(item.href.isEmpty ? "/inbox" : item.href) }.buttonStyle(.bordered)
                if isBusy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .controlSize(.small)
            .disabled(isBusy)
            if let message = messages[item.id] {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(selection == item.id ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { selection = item.id }
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
