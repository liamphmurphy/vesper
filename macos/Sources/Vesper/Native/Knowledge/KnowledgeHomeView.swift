import SwiftUI
import VesperCore

/// Knowledge Home (`/knowledge`) and Kind Start View (`/knowledge?kind=document|deck|design`).
struct KnowledgeHomeView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let controller: KnowledgeShellController
    let startKind: KnowledgePageKind?

    var body: some View {
        if let startKind {
            KnowledgeKindStartView(controller: controller, kind: startKind)
                .id(startKind)
        } else {
            homeBody
        }
    }

    private var homeBody: some View {
        let p = theme.palette
        let agent = controller.viewMode == .agent
        let allPages = controller.rows(in: context)
        let recentEntry = context.store.entry(controller.recentPagesRequest)
        let inboxEntry = context.store.entry(controller.inboxPagesRequest)
        let proposalsEntry = context.store.entry(controller.proposalsRequest)
        let networkEntry = context.store.entry(controller.networkRequest)
        let templatesMap = context.store.entry(KnowledgeShellController.templatesRequest).data?.templates ?? [:]
        let meName = context.store.entry(KnowledgeShellController.bootstrapRequest).data?.me.name

        let recentRows = recentEntry.data?.rows ?? []
        let summary = KnowledgeShellLogic.homeSummary(
            allPages: allPages,
            recentPages: recentRows,
            inboxPages: inboxEntry.data?.rows ?? [],
            proposalPages: proposalsEntry.data?.rows ?? [],
            network: networkEntry.data
        )
        let loadedNeeds = !allPages.isEmpty || (context.store.entry(controller.treeListRequest).data != nil && inboxEntry.data != nil && proposalsEntry.data != nil)

        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        greetingHeader(name: KnowledgeShellLogic.firstName(from: meName))

                        if !agent {
                            startRow(summary: summary)
                            needsYouSection(loaded: loadedNeeds, summary: summary, inboxHasMore: inboxEntry.data?.hasMore ?? false, proposalsHasMore: proposalsEntry.data?.hasMore ?? false)
                        }

                        if let latest = summary.latestPage {
                            latestCard(latest)
                        }

                        recentSection(recentEntry: recentEntry, summary: summary)
                        vaultOverviewSection(summary: summary, templates: KnowledgeShellLogic.namedTemplates(from: templatesMap))
                    }
                    .frame(maxWidth: 780, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .onChange(of: context.find.current) { _, idx in
                    guard let idx, idx < recentRows.count else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("home-recent-\(recentRows[idx].id)", anchor: .center)
                    }
                }
            }

            Divider().overlay(p.border)
            statusBar(agent: agent, pageCount: allPages.count)
        }
        .onChange(of: recentRows.map(\.title), initial: true) { _, titles in
            context.find.texts = titles
        }
        .task(id: controller.viewMode) {
            context.store.load(controller.recentPagesRequest)
            context.store.load(controller.inboxPagesRequest)
            context.store.load(controller.proposalsRequest)
            context.store.load(controller.networkRequest)
            context.store.load(KnowledgeShellController.templatesRequest)
            context.store.load(KnowledgeShellController.bootstrapRequest)
        }
        .onAppear {
            context.store.observe(controller.recentPagesRequest)
            context.store.observe(controller.inboxPagesRequest)
            context.store.observe(controller.proposalsRequest)
            context.store.observe(controller.networkRequest)
        }
        .onChange(of: controller.viewMode) { oldMode, newMode in
            let oldAgent = oldMode == .agent
            let newAgent = newMode == .agent
            context.store.stopObserving(KnowledgeAPI.listPages(audience: oldAgent ? .agent : nil, includeAgent: oldAgent, limit: 8, offset: 0).key)
            context.store.stopObserving(KnowledgeAPI.getNetwork(includeAgent: oldAgent).key)
            let nextRecent = KnowledgeAPI.listPages(audience: newAgent ? .agent : nil, includeAgent: newAgent, limit: 8, offset: 0)
            let nextNet = KnowledgeAPI.getNetwork(includeAgent: newAgent)
            context.store.observe(nextRecent)
            context.store.observe(nextNet)
            context.store.load(nextRecent)
            context.store.load(nextNet)
        }
        .onDisappear {
            context.store.stopObserving(controller.recentPagesRequest.key)
            context.store.stopObserving(controller.inboxPagesRequest.key)
            context.store.stopObserving(controller.proposalsRequest.key)
            context.store.stopObserving(controller.networkRequest.key)
        }
    }

    private func greetingHeader(name: String?) -> some View {
        let p = theme.palette
        let now = Date()
        let greeting = KnowledgeShellLogic.greeting(for: now)
        let title = name.map { "\(greeting), \($0)" } ?? greeting
        let dateText = now.formatted(.dateTime.weekday(.wide).day().month(.wide))

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .vesperText(.display, theme)
                    .foregroundStyle(p.text)
                Text(dateText)
                    .vesperText(.reading, theme)
                    .foregroundStyle(p.tertiaryText)
            }

            FlowLayout(spacing: 8) {
                Button {
                    controller.openToday(in: context)
                } label: {
                    Label("Today\u{2019}s note", systemImage: "clock")
                }
                .buttonStyle(.vesper())

                Button {
                    controller.createDocument(in: context)
                } label: {
                    Label("New page", systemImage: "plus")
                }
                .buttonStyle(.vesper(.primary))

                Button {
                    controller.sheet = .capture
                } label: {
                    Label("Quick capture", systemImage: "tray")
                }
                .buttonStyle(.vesper())

                Button {
                    controller.openSearch(in: context)
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(.vesper())

                Button {
                    context.navigate("/knowledge/graph")
                } label: {
                    Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.vesper())
            }
        }
    }

    private func startRow(summary: KnowledgeHomeSummary) -> some View {
        let p = theme.palette
        let items: [(kind: KnowledgePageKind, label: String, plural: String, detail: String)] = [
            (.document, "Document", "Documents", "Notes, specs, writing"),
            (.deck, "Deck", "Decks", "Slides you present"),
            (.design, "Design", "Designs", "Flows and diagrams"),
        ]

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("START")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10, alignment: .top)], spacing: 10) {
                ForEach(items, id: \.kind) { item in
                    let count = summary.kindCounts[item.kind] ?? 0
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            context.navigate("/knowledge?kind=\(item.kind.rawValue)")
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: KnowledgeShellLogic.pageSymbol(kind: item.kind))
                                    .font(.system(size: 16))
                                    .foregroundStyle(p.secondaryText)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.label)
                                        .font(.system(size: theme.pointSize(.heading), weight: .semibold))
                                        .foregroundStyle(p.text)
                                    Text(item.detail)
                                        .vesperText(.small, theme)
                                        .foregroundStyle(p.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 12) {
                            Button("+ New") {
                                switch item.kind {
                                case .document: controller.createDocument(in: context)
                                case .deck: controller.createDeck(in: context)
                                case .design: controller.createDesign(in: context)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: theme.pointSize(.small), weight: .semibold))
                            .foregroundStyle(p.accent)
                            .disabled(controller.isWorking)

                            Button("All \(item.plural.lowercased()) \u{00B7} \(count) \u{2192}") {
                                context.navigate("/knowledge?kind=\(item.kind.rawValue)")
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.tertiaryText)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                }
            }
        }
    }

    private func needsYouSection(
        loaded: Bool,
        summary: KnowledgeHomeSummary,
        inboxHasMore: Bool,
        proposalsHasMore: Bool
    ) -> some View {
        let p = theme.palette
        struct NeedCard: Identifiable {
            let id: String
            let count: Int
            let more: Bool
            let label: String
            let actionLabel: String
            let hot: Bool
            let action: () -> Void
        }

        var cards: [NeedCard] = []
        if !summary.pagesToReview.isEmpty {
            let n = summary.pagesToReview.count
            cards.append(NeedCard(
                id: "review",
                count: n,
                more: false,
                label: n == 1 ? "page with suggestions to review" : "pages with suggestions to review",
                actionLabel: "Review \u{2192}",
                hot: true
            ) {
                if let first = summary.pagesToReview.first {
                    controller.openPage(first, in: context)
                }
            })
        }
        if !summary.inboxCaptures.isEmpty {
            cards.append(NeedCard(
                id: "inbox",
                count: summary.inboxCaptures.count,
                more: inboxHasMore,
                label: "inbox captures to file",
                actionLabel: "Open Inbox \u{2192}",
                hot: false
            ) {
                controller.openSearch(folder: "Inbox", in: context)
            })
        }
        if !summary.agentProposals.isEmpty {
            cards.append(NeedCard(
                id: "proposals",
                count: summary.agentProposals.count,
                more: proposalsHasMore,
                label: "agent pattern proposals",
                actionLabel: "Review \u{2192}",
                hot: false
            ) {
                if let first = summary.agentProposals.first {
                    controller.viewMode = .agent
                    controller.openPage(first, in: context)
                }
            })
        }

        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("NEEDS YOU")
            if !loaded {
                SkeletonBar(height: 76)
            } else if cards.isEmpty {
                Text("Nothing to review or file.")
                    .vesperText(.body, theme)
                    .foregroundStyle(p.tertiaryText)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10, alignment: .top)], spacing: 10) {
                    ForEach(cards) { card in
                        Button(action: card.action) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(card.count)\(card.more ? "+" : "")")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(card.hot ? p.accent : p.text)
                                Text(card.label)
                                    .vesperText(.body, theme)
                                    .foregroundStyle(p.text)
                                    .lineLimit(2)
                                Text(card.actionLabel)
                                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                                    .foregroundStyle(p.accent)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(card.hot ? p.accent.opacity(0.45) : p.border)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func latestCard(_ row: KnowledgePageRow) -> some View {
        let p = theme.palette
        let hit = context.find.matches(row.title)
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("PICK UP WHERE YOU LEFT OFF")
            Button {
                let newTab = context.currentEventModifiers.contains(.command)
                controller.openPage(row, in: context, newTab: newTab)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: KnowledgeShellLogic.pageSymbol(for: row))
                        .font(.system(size: 16))
                        .foregroundStyle(p.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(KnowledgeShellLogic.displayTitle(for: row))
                            .font(.system(size: theme.pointSize(.heading), weight: .semibold))
                            .foregroundStyle(p.text)
                            .lineLimit(1)
                        Text(row.summary.isEmpty ? "Empty page" : row.summary)
                            .vesperText(.small, theme)
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(1)
                        Text("\(KnowledgeShellLogic.folderDisplay(of: row.path)) \u{00B7} edited \(KnowledgeShellLogic.relativeAgo(row.updatedAt))")
                            .font(.system(size: theme.pointSize(.micro) + 1))
                            .foregroundStyle(p.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.accent)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hit ? p.hover : p.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(hit ? p.accent : p.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id("home-recent-\(row.id)")
            .contextMenu { rowContextMenu(row) }
        }
    }

    private func recentSection(recentEntry: QueryEntry<KnowledgePageTable>, summary: KnowledgeHomeSummary) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("RECENT")
                Spacer()
                Button("Find a page") {
                    controller.openSearch(in: context)
                }
                .buttonStyle(.plain)
                .font(.system(size: theme.pointSize(.small), weight: .medium))
                .foregroundStyle(p.accent)
            }

            if let error = recentEntry.error, recentEntry.data == nil {
                QueryErrorView(message: error.userMessage) {
                    Task { _ = await context.store.refetch(controller.recentPagesRequest) }
                }
            } else if recentEntry.data == nil {
                VStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { _ in SkeletonBar(height: 30) }
                }
            } else if (recentEntry.data?.rows ?? []).isEmpty {
                Text("No pages yet. Capture a thought or import your Obsidian vault from the explorer.")
                    .vesperText(.body, theme)
                    .foregroundStyle(p.tertiaryText)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(summary.otherRecentPages) { row in
                        recentRow(row)
                            .id("home-recent-\(row.id)")
                        Divider().overlay(p.rowBorder)
                    }
                }
            }
        }
    }

    private func recentRow(_ row: KnowledgePageRow) -> some View {
        let p = theme.palette
        let hit = context.find.matches(row.title)
        let untitled = KnowledgeShellLogic.isUntitled(row.title)
        return Button {
            let newTab = context.currentEventModifiers.contains(.command)
            controller.openPage(row, in: context, newTab: newTab)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: KnowledgeShellLogic.pageSymbol(for: row))
                    .font(.system(size: 13))
                    .foregroundStyle(p.tertiaryText)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(KnowledgeShellLogic.displayTitle(for: row))
                        .font(.system(size: theme.pointSize(.body), weight: .medium))
                        .italic(untitled)
                        .foregroundStyle(untitled ? p.secondaryText : p.text)
                        .lineLimit(1)
                    let subtitle = KnowledgeShellLogic.folderDisplay(of: row.path)
                        + (!row.summary.isEmpty && !untitled ? " \u{00B7} \(row.summary)" : (row.summary.isEmpty ? " \u{00B7} empty" : ""))
                    Text(subtitle)
                        .vesperText(.small, theme)
                        .foregroundStyle(p.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if row.pending > 0 {
                    TonePill(label: "\(row.pending) to review", tone: "human")
                }
                HStack(spacing: 4) {
                    Image(systemName: audienceSymbol(row.audience))
                        .font(.system(size: 11))
                    Text(KnowledgeShellLogic.relativeAgo(row.updatedAt))
                        .font(.system(size: theme.pointSize(.small)))
                }
                .foregroundStyle(p.tertiaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(hit ? p.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { rowContextMenu(row) }
    }

    private func vaultOverviewSection(summary: KnowledgeHomeSummary, templates: [String]) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle("OVERVIEW & TEMPLATES")

            HStack(spacing: 10) {
                overviewMetricCard(
                    title: "Unresolved links",
                    count: summary.unresolvedCount,
                    symbol: "link",
                    actionLabel: "Connect notes \u{2192}"
                ) {
                    context.navigate("/knowledge/connect")
                }
                overviewMetricCard(
                    title: "Orphan pages",
                    count: summary.orphanCount,
                    symbol: "doc.questionmark",
                    actionLabel: "View orphans \u{2192}"
                ) {
                    controller.openSearch(orphans: true, in: context)
                }
            }

            if !summary.topTags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tags")
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(p.secondaryText)
                    FlowLayout(spacing: 6) {
                        ForEach(summary.topTags, id: \.tag) { item in
                            Button {
                                controller.openSearch(tag: item.tag, in: context)
                            } label: {
                                Text("#\(item.tag) \u{00B7} \(item.count)")
                                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                                    .foregroundStyle(p.accent)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(theme.swiftUIColor("accent-soft", fallback: p.selected), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Templates")
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(p.secondaryText)
                FlowLayout(spacing: 8) {
                    Button("Blank page") {
                        controller.createDocument(in: context)
                    }
                    .buttonStyle(.vesper())

                    Button("Daily note") {
                        controller.openToday(in: context)
                    }
                    .buttonStyle(.vesper())

                    ForEach(templates, id: \.self) { name in
                        Button(name) {
                            controller.createDocument(title: name, template: name, in: context)
                        }
                        .buttonStyle(.vesper())
                    }
                }
            }
        }
    }

    private func overviewMetricCard(
        title: String,
        count: Int,
        symbol: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        let p = theme.palette
        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(p.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count) \(title.lowercased())")
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .foregroundStyle(p.text)
                    Text(actionLabel)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.accent)
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusBar(agent: Bool, pageCount: Int) -> some View {
        let p = theme.palette
        return HStack {
            Text(agent ? "Agent knowledge \u{00B7} written by runs" : "Your knowledge \u{00B7} private by default")
            Spacer()
            Text("\(pageCount) \(pageCount == 1 ? "page" : "pages")")
        }
        .font(.system(size: theme.pointSize(.micro) + 1))
        .foregroundStyle(p.tertiaryText)
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: theme.pointSize(.micro), weight: .bold))
            .tracking(0.6)
            .foregroundStyle(theme.palette.tertiaryText)
    }

    private func audienceSymbol(_ audience: KnowledgeAudience) -> String {
        switch audience {
        case .private: "lock"
        case .shared: "person.2"
        case .agent: "cpu"
        }
    }

    @ViewBuilder
    private func rowContextMenu(_ row: KnowledgePageRow) -> some View {
        Button("Open") { controller.openPage(row, in: context) }
        Button("Open in New Tab") { controller.openPage(row, in: context, newTab: true) }
        Divider()
        Button("Copy [[wikilink]]") { controller.copyPageWikilink(row, in: context) }
        Button("Copy Link") { controller.copyPageLink(row, in: context) }
    }
}

// MARK: - Kind Start View (/knowledge?kind=document|deck|design)

struct KnowledgeKindStartView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let controller: KnowledgeShellController
    let kind: KnowledgePageKind

    @State private var docTitle = ""
    @State private var deckTitle = ""
    @State private var deckTheme: API.CreateDeckBody.Theme = .light
    @State private var deckFrom = "blank"
    @State private var deckOutline = ""
    @State private var outlineError: String?
    @State private var designPrompt = ""
    @State private var galleryQuery = ""

    private var galleryRequest: APIRequest<KnowledgePageTable> {
        let q = galleryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let agent = controller.viewMode == .agent
        return KnowledgeAPI.listPages(
            q: q.isEmpty ? nil : q,
            audience: agent ? .agent : nil,
            includeAgent: agent,
            kind: kind,
            limit: 120
        )
    }

    private var pluralLabel: String {
        switch kind {
        case .document: "Documents"
        case .deck: "Decks"
        case .design: "Designs"
        }
    }

    private var descriptionText: String {
        switch kind {
        case .document: "Notes, specs and writing. Each is a page, filed in whatever folder you put it in."
        case .deck: "Slides you build and present with a persona. Each deck is a page, so it lives in whatever folder you put it in."
        case .design: "App flows, diagrams and wireframes you build with your personas. Each design is a page in Knowledge."
        }
    }

    var body: some View {
        let p = theme.palette
        let galleryEntry = context.store.entry(galleryRequest)
        let rows = galleryEntry.data?.rows ?? []

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                headerBar

                switch kind {
                case .document: documentStarter
                case .deck: deckStarter
                case .design: designStarter
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("YOUR \(pluralLabel.uppercased()) \(rows.isEmpty ? "" : "\u{00B7} \(rows.count)\(galleryEntry.data?.hasMore == true ? "+" : "")")")
                            .font(.system(size: theme.pointSize(.micro), weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(p.tertiaryText)
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(p.tertiaryText)
                            TextField("Search \(pluralLabel.lowercased())", text: $galleryQuery)
                                .textFieldStyle(.plain)
                                .frame(width: 180)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                    }

                    if let error = galleryEntry.error, galleryEntry.data == nil {
                        QueryErrorView(message: error.userMessage) {
                            Task { _ = await context.store.refetch(galleryRequest) }
                        }
                    } else if galleryEntry.data == nil {
                        VStack(spacing: 8) {
                            ForEach(0..<4, id: \.self) { _ in SkeletonBar(height: 36) }
                        }
                    } else if rows.isEmpty {
                        Text(galleryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "No \(pluralLabel.lowercased()) yet. Start one above."
                             : "No \(pluralLabel.lowercased()) match \u{201C}\(galleryQuery)\u{201D}.")
                            .vesperText(.body, theme)
                            .foregroundStyle(p.tertiaryText)
                            .padding(.vertical, 16)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(rows) { row in
                                Button {
                                    let newTab = context.currentEventModifiers.contains(.command)
                                    controller.openPage(row, in: context, newTab: newTab)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: KnowledgeShellLogic.pageSymbol(for: row))
                                            .foregroundStyle(p.tertiaryText)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(KnowledgeShellLogic.displayTitle(for: row))
                                                .font(.system(size: theme.pointSize(.body), weight: .medium))
                                                .foregroundStyle(p.text)
                                                .lineLimit(1)
                                            Text(KnowledgeShellLogic.folderDisplay(of: row.path) + (row.summary.isEmpty ? "" : " \u{00B7} \(row.summary)"))
                                                .vesperText(.small, theme)
                                                .foregroundStyle(p.tertiaryText)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        if row.pending > 0 {
                                            TonePill(label: "\(row.pending) to review", tone: "human")
                                        }
                                        Text(KnowledgeShellLogic.relativeAgo(row.updatedAt))
                                            .font(.system(size: theme.pointSize(.small)))
                                            .foregroundStyle(p.tertiaryText)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Open") { controller.openPage(row, in: context) }
                                    Button("Open in New Tab") { controller.openPage(row, in: context, newTab: true) }
                                    Divider()
                                    Button("Copy [[wikilink]]") { controller.copyPageWikilink(row, in: context) }
                                    Button("Copy Link") { controller.copyPageLink(row, in: context) }
                                }
                                Divider().overlay(p.rowBorder)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task(id: galleryRequest.key) {
            context.store.load(galleryRequest)
            context.store.load(KnowledgeShellController.templatesRequest)
            context.store.load(KnowledgeShellController.slideStartersRequest)
        }
    }

    private var headerBar: some View {
        let p = theme.palette
        let kindBinding = Binding<KnowledgePageKind>(
            get: { kind },
            set: { next in context.navigate("/knowledge?kind=\(next.rawValue)") }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Text(pluralLabel)
                    .vesperText(.display, theme)
                    .foregroundStyle(p.text)
                Picker("Kinds", selection: kindBinding) {
                    Text("Documents").tag(KnowledgePageKind.document)
                    Text("Decks").tag(KnowledgePageKind.deck)
                    Text("Designs").tag(KnowledgePageKind.design)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                Spacer()
                Button("Home") { controller.openHome(in: context) }
                    .buttonStyle(.vesper())
            }
            Text(descriptionText)
                .vesperText(.reading, theme)
                .foregroundStyle(p.secondaryText)
        }
    }

    private var documentStarter: some View {
        let p = theme.palette
        let templates = KnowledgeShellLogic.namedTemplates(
            from: context.store.entry(KnowledgeShellController.templatesRequest).data?.templates ?? [:]
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Give it a title\u{2026}", text: $docTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let name = docTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        controller.createDocument(title: name.isEmpty ? "Untitled" : name, in: context)
                    }
                Button("New document") {
                    let name = docTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    controller.createDocument(title: name.isEmpty ? "Untitled" : name, in: context)
                }
                .buttonStyle(.vesper(.primary))
                .disabled(controller.isWorking)
            }

            FlowLayout(spacing: 8) {
                Button("Blank") {
                    let name = docTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    controller.createDocument(title: name.isEmpty ? "Untitled" : name, in: context)
                }
                .buttonStyle(.vesper())
                .disabled(controller.isWorking)

                Button("Today") {
                    controller.openToday(in: context)
                }
                .buttonStyle(.vesper())

                ForEach(templates, id: \.self) { t in
                    Button(t) {
                        let name = docTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        controller.createDocument(title: name.isEmpty ? t : name, template: t, in: context)
                    }
                    .buttonStyle(.vesper())
                    .disabled(controller.isWorking)
                }
            }
            .foregroundStyle(p.text)
        }
    }

    private var deckStarter: some View {
        let p = theme.palette
        let starters = context.store.entry(KnowledgeShellController.slideStartersRequest).data?.starters ?? []
        let brief = deckFrom == "blank" && KnowledgeShellLogic.isDeckBrief(deckTitle)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Give it a title, or describe it and its persona drafts the slides\u{2026}", text: $deckTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitDeck(brief: brief) }

                Picker("Theme", selection: $deckTheme) {
                    ForEach(API.CreateDeckBody.Theme.allKnown, id: \.rawValue) { t in
                        Text(t.rawValue.capitalized).tag(t)
                    }
                }
                .labelsHidden()
                .frame(width: 120)

                Button(brief ? "\u{2726} Draft it" : "New deck") {
                    submitDeck(brief: brief)
                }
                .buttonStyle(.vesper(.primary))
                .disabled(controller.isWorking)
            }

            FlowLayout(spacing: 8) {
                starterChoiceChip(id: "blank", title: "Blank", selected: deckFrom == "blank") { deckFrom = "blank" }
                ForEach(starters, id: \.key) { s in
                    starterChoiceChip(id: s.key, title: "\(s.name) (\(s.slideCount))", selected: deckFrom == s.key) {
                        deckFrom = s.key
                    }
                }
                starterChoiceChip(id: "outline", title: "Draft from outline", selected: deckFrom == "outline") {
                    deckFrom = "outline"
                }
            }

            if deckFrom == "outline" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Outline (one slide per top-level line)")
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(p.secondaryText)
                    TextEditor(text: $deckOutline)
                        .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                        .frame(minHeight: 110, maxHeight: 160)
                        .padding(6)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                    if let outlineError {
                        Text(outlineError)
                            .vesperText(.small, theme)
                            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    }
                    HStack {
                        Text("The deck opens with its title slide; its persona drafts the rest as suggestions.")
                            .vesperText(.small, theme)
                            .foregroundStyle(p.secondaryText)
                        Spacer()
                        Button("\u{2726} Create & draft") { submitDeck(brief: brief) }
                            .buttonStyle(.vesper(.primary))
                            .disabled(controller.isWorking || deckOutline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
                .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.accent.opacity(0.5)))
            }
        }
    }

    private func submitDeck(brief: Bool) {
        let trimmed = deckTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if deckFrom == "outline" {
            let split = KnowledgeShellLogic.splitOutline(deckOutline, title: trimmed)
            guard !split.slides.isEmpty else {
                outlineError = "Add at least one line for a slide after the title."
                return
            }
            outlineError = nil
            controller.createDeck(
                title: split.title.isEmpty ? "Untitled deck" : split.title,
                theme: deckTheme,
                outline: split.slides,
                in: context
            )
        } else if deckFrom != "blank" {
            controller.createDeck(
                title: trimmed.isEmpty ? "Untitled deck" : trimmed,
                starter: API.CreateDeckBody.Starter(rawValue: deckFrom),
                theme: deckTheme,
                in: context
            )
        } else {
            controller.createDeck(
                title: brief ? "" : (trimmed.isEmpty ? "Untitled deck" : trimmed),
                theme: deckTheme,
                brief: brief ? trimmed : nil,
                in: context
            )
        }
    }

    private var designStarter: some View {
        let brief = KnowledgeShellLogic.isDesignBrief(designPrompt)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Describe a flow or diagram, or paste a ticket key\u{2026}", text: $designPrompt)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitDesign(brief: brief) }

                Button(brief ? "\u{2726} Draft it" : "New design") {
                    submitDesign(brief: brief)
                }
                .buttonStyle(.vesper(.primary))
                .disabled(controller.isWorking)
            }

            FlowLayout(spacing: 8) {
                ForEach(KnowledgeDesignStarterOption.all, id: \.starter.rawValue) { option in
                    Button(option.label) {
                        controller.createDesign(starter: option.starter, in: context)
                    }
                    .buttonStyle(.vesper())
                    .disabled(controller.isWorking)
                }
            }
        }
    }

    private func submitDesign(brief: Bool) {
        let trimmed = designPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && brief {
            controller.createDesign(
                starter: .blank,
                title: KnowledgeShellLogic.designBriefTitle(trimmed),
                brief: trimmed,
                in: context
            )
        } else {
            controller.createDesign(starter: .blank, title: trimmed, in: context)
        }
    }

    private func starterChoiceChip(id: String, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: action) {
            Text(title)
                .font(.system(size: theme.pointSize(.small), weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? p.accent : p.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? theme.swiftUIColor("accent-soft", fallback: p.selected) : p.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? p.accent : p.border))
        }
        .buttonStyle(.plain)
    }
}
