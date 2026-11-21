import AppKit
import SwiftUI
import VesperCore

/// Hides a card at once, offers Undo in a toast, and only deletes once the toast goes without it
/// (the web's `undoable`).
@MainActor
private func undoableRemove(
    context: NativeScreenContext, id: String, title: String, description: String? = nil, failed: String,
    hide: @escaping @MainActor () -> Void, restore: @escaping @MainActor () -> Void, commit: @escaping @MainActor () async throws -> Void
) {
    hide()
    context.showToast(ToastItemModel(id: "library.undo.\(id)", title: title, description: description, actionLabel: "Undo")) { event in
        if event == .action {
            restore()
            return
        }
        Task {
            do {
                try await commit()
            } catch {
                restore()
                context.showToast(ToastItemModel(id: "library.undo-failed.\(id)", title: failed,
                                                 description: (error as? APIError)?.userMessage, tone: .error))
            }
        }
    }
}

/// A small pill toggle (the web's rounded filter buttons).
private struct PillToggle: View {
    @Environment(\.vesperTheme) private var theme
    let label: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .fontWeight(on ? .semibold : .regular)
                .foregroundStyle(on ? theme.palette.accent : theme.palette.secondaryText)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(on ? theme.swiftUIColor("accent-soft", fallback: theme.palette.selected) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: Links

/// The Library's Links: pages and videos saved from a persona's recommendation (web library/links.tsx).
struct LibraryLinksView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @State private var queue = LibraryLogic.LinkQueue.toRead
    @State private var filter = LibraryLogic.LinkFilter.all
    @State private var offsets = [0]
    @State private var hidden: Set<String> = []

    private func page(_ offset: Int) -> APIRequest<API.LibraryList> { API.listLibraryItems(kind: .link, offset: offset == 0 ? nil : offset) }
    private var pageKeys: [QueryKey] { offsets.map { page($0).key } }

    /// Every loaded page's links, each once, without those waiting out an Undo.
    private var items: [API.LibraryItem] {
        var seen = Set<String>()
        return offsets.flatMap { context.store.entry(page($0)).data?.items ?? [] }
            .filter { seen.insert($0.id).inserted && !hidden.contains($0.id) }
    }

    var body: some View {
        let items = self.items
        let first = context.store.entry(page(0))
        let columns = [GridItem(.adaptive(minimum: 250), spacing: 16, alignment: .top)]
        Group {
            if first.data == nil, let error = first.error {
                QueryErrorView(message: "Couldn\u{2019}t load your links: \(error.userMessage)") {
                    Task { await context.store.refetch(page(0)) }
                }
            } else if first.data == nil {
                LazyVGrid(columns: columns, spacing: 16) { ForEach(0..<3, id: \.self) { _ in SkeletonBar(height: 150) } }
            } else if items.isEmpty {
                LibraryEmptyState(title: "No saved links yet",
                                  message: "When a persona recommends a page or video in a chat, choose Save to Library on its card to keep it here.")
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        HStack(spacing: 4) {
                            ForEach(LibraryLogic.LinkQueue.allCases, id: \.self) { q in
                                PillToggle(label: "\(q == .done ? "Done" : "To read") (\(LibraryLogic.linkCount(items, queue: q)))", on: queue == q) { queue = q }
                            }
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(LibraryLogic.LinkFilter.allCases, id: \.self) { f in
                                PillToggle(label: f == .all ? "All" : f == .video ? "Videos" : "Pages", on: filter == f) { filter = f }
                            }
                        }
                    }
                    .font(.system(size: theme.pointSize(.small)))
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(LibraryLogic.links(items, queue: queue, filter: filter), id: \.id) { item in
                            LinkCard(item: item, pages: offsets.map(page)) { hide in
                                if hide { hidden.insert(item.id) } else { hidden.remove(item.id) }
                            }
                        }
                    }
                    if context.store.entry(page(offsets.last ?? 0)).data?.hasMore == true {
                        HStack {
                            Spacer()
                            Button("Show more") { if !offsets.contains(items.count + hidden.count) { offsets.append(items.count + hidden.count) } }
                                .buttonStyle(.vesper())
                            Spacer()
                        }
                    }
                }
            }
        }
        .onChange(of: pageKeys, initial: true) { old, new in
            for key in old where !new.contains(key) { context.store.stopObserving(key) }
            for offset in offsets {
                let request = page(offset)
                context.store.load(request)
                if old == new || !old.contains(request.key) { context.store.observe(request) }
            }
        }
        .onDisappear { for key in pageKeys { context.store.stopObserving(key) } }
    }
}

private struct LinkCard: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let item: API.LibraryItem
    let pages: [APIRequest<API.LibraryList>]
    let setHidden: (Bool) -> Void
    @State private var busy = false

    var body: some View {
        let url = item.url ?? ""
        let done = LibraryLogic.isDone(item)
        VStack(alignment: .leading, spacing: 0) {
            if item.sizeBytes > 0 {
                Button { context.openExternal(url) } label: {
                    Color.clear
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { LibraryImageView(path: LibraryLogic.contentPath(item.id)) }
                        .clipped()
                        .overlay {
                            if item.videoId != nil {
                                Image(systemName: "play.circle.fill").font(.system(size: 36)).foregroundStyle(.white).shadow(radius: 4)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(url)
            }
            VStack(alignment: .leading, spacing: 4) {
                Button { context.openExternal(url) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(item.title).font(.system(size: theme.pointSize(.reading), weight: .semibold)).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "link").font(.system(size: 11)).foregroundStyle(theme.palette.tertiaryText)
                    }
                }
                .buttonStyle(.plain)
                Text(item.site.flatMap { $0.isEmpty ? nil : $0 } ?? LibraryLogic.host(url))
                    .font(.system(size: theme.pointSize(.small))).foregroundStyle(theme.palette.tertiaryText).lineLimit(1)
                if let note = item.note, !note.isEmpty {
                    Text("\u{201C}\(note)\u{201D}").italic().vesperText(.body, theme).foregroundStyle(theme.palette.secondaryText).padding(.top, 4)
                }
                if let summary = item.summary, !summary.isEmpty {
                    DisclosureGroup("Summary") {
                        Text(Self.markdown(LibraryLogic.summaryText(summary)))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .vesperText(.body, theme)
                    .foregroundStyle(theme.palette.secondaryText)
                    .padding(.top, 4)
                }
                HStack(spacing: 8) {
                    Text("From \(item.personaName ?? "Assistant") · \(APIDate.timeline(item.createdAt))").lineLimit(1)
                    Spacer(minLength: 4)
                    Button(done ? "Move to To read" : "Mark done") { setStatus(done ? .toRead : .done) }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.palette.accent)
                        .disabled(busy)
                    Button { remove() } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(item.title)")
                }
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.palette.tertiaryText)
                .padding(.top, 8)
            }
            .padding(12)
        }
        .background(theme.palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
        .contextMenu {
            Button("Open Link") { context.openExternal(url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
            Divider()
            Button(done ? "Move to To read" : "Mark done") { setStatus(done ? .toRead : .done) }
            Button("Remove", role: .destructive) { remove() }
        }
        .onDrag { URL(string: url).map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider() }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func setStatus(_ status: API.LibraryLinkStatus) {
        busy = true
        Task {
            do {
                _ = try await context.store.mutate(
                    API.setLibraryLinkStatus(itemId: item.id, body: .init(status: status)),
                    optimistic: pages.map { page in .update(page) { list in
                        for i in list.items.indices where list.items[i].id == item.id { list.items[i].linkStatus = status }
                    } },
                    invalidating: QueryInvalidation(resources: ["library"]))
            } catch {
                context.showToast(ToastItemModel(id: "library.link-status.\(item.id)", title: "Couldn\u{2019}t move \(item.title)",
                                                 description: (error as? APIError)?.userMessage, tone: .error))
            }
            busy = false
        }
    }

    private func remove() {
        let store = context.store
        let id = item.id
        undoableRemove(
            context: context, id: id, title: "Removed \(item.title)", failed: "Couldn\u{2019}t remove \(item.title)",
            hide: { setHidden(true) }, restore: { setHidden(false) },
            commit: {
                do {
                    _ = try await store.mutate(API.deleteLibraryItem(itemId: id), invalidating: QueryInvalidation(resources: ["library", "link-previews"]))
                } catch APIError.http(status: 404, _) {
                    store.invalidate(QueryInvalidation(resources: ["library"]))
                }
            })
    }
}

// MARK: Fridge

/// The Library's Fridge: the moments each persona chose to keep from your chats, newest first
/// (web library/fridge.tsx).
struct LibraryFridgeView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @State private var persona = ""
    @State private var adding = false
    @State private var offsets = [0]
    @State private var hidden: Set<String> = []

    private static let personas = API.listPersonas()

    private func page(_ offset: Int) -> APIRequest<API.MemoryList> {
        API.listMemories(type: "moment", offset: offset == 0 ? nil : offset, about: persona.isEmpty ? .persona : nil,
                         personaId: persona.isEmpty ? nil : persona, sort: .created)
    }

    private var pageKeys: [QueryKey] { offsets.map { page($0).key } }

    private var moments: [API.Memory] {
        var seen = Set<String>()
        return offsets.flatMap { context.store.entry(page($0)).data?.memories ?? [] }
            .filter { seen.insert($0.id).inserted && !hidden.contains($0.id) }
    }

    var body: some View {
        let personas = context.store.entry(Self.personas).data?.personas ?? []
        let moments = self.moments
        let first = context.store.entry(page(0))
        let columns = [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)]
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 4) {
                filterButton(id: "", name: "Everyone", color: nil)
                ForEach(personas, id: \.id) { p in filterButton(id: p.id, name: p.name, color: Color(cssHex: p.color)) }
                Spacer()
                if !personas.isEmpty, !adding {
                    Button { adding = true } label: { Label("Add a moment", systemImage: "plus") }.buttonStyle(.vesper())
                }
            }
            .font(.system(size: theme.pointSize(.small)))
            if adding {
                AddMomentForm(personas: personas, initial: persona) { adding = false }
            }
            if first.data == nil, let error = first.error {
                QueryErrorView(message: "Couldn\u{2019}t load the Fridge: \(error.userMessage)") {
                    Task { await context.store.refetch(page(0)) }
                }
            } else if first.data == nil {
                LazyVGrid(columns: columns, spacing: 12) { ForEach(0..<3, id: \.self) { _ in SkeletonBar(height: 112) } }
            } else if moments.isEmpty {
                LibraryEmptyState(icon: "bookmark", title: "Nothing on the Fridge yet",
                                  message: "When a persona wants to keep a moment you shared, it pins it here. You can add one yourself too.")
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(moments, id: \.id) { m in
                        MomentCard(moment: m, persona: personas.first { $0.id == m.personaId }) { hide in
                            if hide { hidden.insert(m.id) } else { hidden.remove(m.id) }
                        }
                    }
                }
                if context.store.entry(page(offsets.last ?? 0)).data?.hasMore == true {
                    HStack {
                        Spacer()
                        Button("Show more") { if !offsets.contains(moments.count + hidden.count) { offsets.append(moments.count + hidden.count) } }
                            .buttonStyle(.vesper())
                        Spacer()
                    }
                }
            }
        }
        .onChange(of: persona) { _, _ in offsets = [0] }
        .onChange(of: pageKeys, initial: true) { old, new in
            for key in old where !new.contains(key) { context.store.stopObserving(key) }
            for offset in offsets {
                let request = page(offset)
                context.store.load(request)
                if old == new || !old.contains(request.key) { context.store.observe(request) }
            }
        }
        .task { context.store.load(Self.personas) }
        .onDisappear { for key in pageKeys { context.store.stopObserving(key) } }
    }

    private func filterButton(id: String, name: String, color: Color?) -> some View {
        let on = persona == id
        return Button { persona = id } label: {
            HStack(spacing: 6) {
                if let color { Circle().fill(color).frame(width: 8, height: 8) }
                Text(name)
            }
            .foregroundStyle(on ? theme.palette.text : theme.palette.secondaryText)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(on ? theme.palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// One moment, pinned like a note on the fridge in its persona's colour.
private struct MomentCard: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let moment: API.Memory
    let persona: API.Persona?
    let setHidden: (Bool) -> Void

    var body: some View {
        let color = Color(cssHex: persona?.color) ?? theme.swiftUIColor("border-strong", fallback: theme.palette.border)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(moment.title).font(.system(size: theme.pointSize(.body), weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                Button { remove() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.palette.tertiaryText)
                    .accessibilityLabel("Delete \(moment.title)")
            }
            if !moment.summary.isEmpty {
                Text(moment.summary).vesperText(.body, theme).foregroundStyle(theme.palette.secondaryText)
            }
            if !moment.body.isEmpty, moment.body != moment.summary {
                Text(moment.body).font(.system(size: theme.pointSize(.small))).foregroundStyle(theme.palette.secondaryText)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(persona?.name ?? "A deleted persona")
                Text("· \(APIDate.parse(moment.createdAt)?.formatted(date: .abbreviated, time: .omitted) ?? "")")
                if let chat = moment.sourceChatId {
                    Text("·")
                    Button("Open chat") { context.navigate("/chat/\(chat)") }.buttonStyle(.plain).foregroundStyle(theme.palette.accent)
                }
            }
            .font(.system(size: theme.pointSize(.small)))
            .foregroundStyle(theme.palette.tertiaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(theme.palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(color).frame(height: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
        .contextMenu {
            if let chat = moment.sourceChatId { Button("Open Chat") { context.navigate("/chat/\(chat)") } }
            Button("Delete", role: .destructive) { remove() }
        }
    }

    private func remove() {
        let store = context.store
        let id = moment.id
        undoableRemove(
            context: context, id: id, title: "Moment deleted",
            description: "\(persona?.name ?? "The persona") will no longer remember it.", failed: "Couldn\u{2019}t delete the moment",
            hide: { setHidden(true) }, restore: { setHidden(false) },
            commit: {
                do {
                    _ = try await store.mutate(API.deleteMemory(id: id), invalidating: QueryInvalidation(resources: ["memories"]))
                } catch APIError.http(status: 404, _) {
                    store.invalidate(QueryInvalidation(resources: ["memories"]))
                }
            })
    }
}

/// Pin a moment by hand to one persona's own memory.
private struct AddMomentForm: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let personas: [API.Persona]
    let initial: String
    let done: () -> Void
    @State private var persona = ""
    @State private var title = ""
    @State private var summary = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        let ready = !title.trimmingCharacters(in: .whitespaces).isEmpty && !persona.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Persona", selection: $persona) {
                    ForEach(personas, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 160)
                TextField("What happened, in a few words", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFocused)
                    .onChange(of: title) { _, v in if v.count > 200 { title = String(v.prefix(200)) } }
                    .accessibilityLabel("Title")
            }
            TextField("One line to remember it by", text: $summary, axis: .vertical)
                .lineLimit(2...3)
                .textFieldStyle(.roundedBorder)
                .onChange(of: summary) { _, v in if v.count > 300 { summary = String(v.prefix(300)) } }
                .accessibilityLabel("Summary")
            if let error {
                Text(error).font(.system(size: theme.pointSize(.small))).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
            HStack(spacing: 8) {
                Button("Pin it", action: submit).buttonStyle(.vesper(.primary)).disabled(saving || !ready).keyboardShortcut(.defaultAction)
                Button("Cancel", action: done).buttonStyle(.vesper()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.accent))
        .onAppear {
            persona = initial.isEmpty ? (personas.first?.id ?? "") : initial
            titleFocused = true
        }
    }

    private func submit() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !persona.isEmpty else { return }
        saving = true
        Task {
            do {
                _ = try await context.store.mutate(
                    API.createMemory(body: .init(personaId: persona, summary: summary.trimmingCharacters(in: .whitespacesAndNewlines), title: trimmed, type: "moment")),
                    invalidating: QueryInvalidation(resources: ["memories"]))
                done()
            } catch {
                self.error = (error as? APIError)?.userMessage ?? "Something went wrong. Please try again."
            }
            saving = false
        }
    }
}
