import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

/// Native `/spaces/:id` screen: space header & inline editor, work tabs, new-chat composer,
/// sortable chat list, sources management sheet, and native About + Companion Chat inspector.
struct SpaceScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var editing = false
    @State private var showSourcesSheet = false
    @State private var showDeleteAlert = false
    @State private var chatSort: SpacesLogic.ChatSort = .newest
    @State private var showAllChats = false
    @State private var inspectorOpen = true
    @State private var inspectorTabId = "about"

    // Inline new-chat composer
    @State private var composerText = ""
    @State private var pickedPersonaId: String?
    @State private var pickedHarness: API.Harness?
    @State private var pickedModel: String?
    @State private var researchMode = false
    @State private var startingChat = false
    @State private var composerError: String?

    // Edit header/settings form
    @State private var editName = ""
    @State private var editDescription = ""
    @State private var editInstructions = ""
    @State private var editColor: API.ChatSpaceColor = .green
    @State private var editWorkKey = ""
    @State private var editWorkRepo = ""
    @State private var savingEdit = false
    @State private var editError: String?
    @State private var deleting = false
    @State private var watchedKeys: [QueryKey] = []

    private static let personasRequest = API.listPersonas()
    private static let modelsRequest = API.listChatModels()
    private static let bootRequest = API.getBootstrap()
    private static let connectorsRequest = API.listConnectors()
    private static let spacesRequest = API.listChatSpaces()

    private var spaceId: String {
        context.match.params["id"] ?? ""
    }

    private var spaceRequest: APIRequest<API.ChatSpace> {
        API.getChatSpace(spaceId: spaceId)
    }

    private var sourcesRequest: APIRequest<API.ChatSpaceSourceList> {
        API.listChatSpaceSources(spaceId: spaceId)
    }

    private var chatsRequest: APIRequest<API.ListChatsResponse> {
        API.listChats(space: spaceId)
    }

    var body: some View {
        let p = theme.palette
        let spaceEntry = context.store.entry(spaceRequest)
        let space = spaceEntry.data
        let sourcesData = context.store.entry(sourcesRequest).data
        let sources = sourcesData?.sources ?? []
        let chatsEntry = context.store.entry(chatsRequest)
        let personasList = context.store.entry(Self.personasRequest).data
        let personas = personasList?.personas ?? []
        let models = context.store.entry(Self.modelsRequest).data ?? []
        let boot = context.store.entry(Self.bootRequest).data
        let connectors = context.store.entry(Self.connectorsRequest).data?.connectors ?? []
        let spaces = context.store.entry(Self.spacesRequest).data?.spaces ?? []
        let spaceChats = chatsEntry.data?.chats ?? []

        Group {
            if let error = spaceEntry.error, space == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Couldn\u{2019}t open this space")
                        .vesperText(.heading, theme)
                    Text(error.userMessage)
                        .vesperText(.body, theme)
                        .foregroundStyle(p.secondaryText)
                    Button("Back to Chat") { context.navigate("/chat") }
                        .buttonStyle(.bordered)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let space {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        headerSection(space: space, p: p)

                        if let work = space.work {
                            workTabsBar(space: space, work: work, p: p)
                        }

                        composerCard(
                            space: space,
                            personas: personas,
                            defaultPersonaId: personasList?.defaultPersonaId,
                            models: models,
                            p: p
                        )

                        chatsSection(
                            space: space,
                            chatsEntry: chatsEntry,
                            p: p
                        )
                    }
                    .frame(maxWidth: 960, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .sheet(isPresented: $showSourcesSheet) {
                    SpaceSourcesSheet(spaceId: space.id, spaceName: space.name)
                        .environment(context)
                        .environment(\.vesperTheme, theme)
                }
                .alert("Delete \(space.name)?", isPresented: $showDeleteAlert) {
                    Button("Cancel", role: .cancel) {}
                    if space.work == nil {
                        Button("Delete space", role: .destructive) {
                            deleteSpace(space)
                        }
                    }
                } message: {
                    if let work = space.work {
                        Text("\(space.name) tracks work (\(work.key)), so it stays while it does. Stop tracking work first.")
                    } else {
                        Text("Its instructions, \(space.sourceCount) \(space.sourceCount == 1 ? "source" : "sources") and \(space.memoryCount) \(space.memoryCount == 1 ? "memory" : "memories") are deleted. Its \(space.chatCount) \(space.chatCount == 1 ? "chat moves" : "chats move") to Recent.")
                    }
                }
            } else {
                ProgressView("Loading space\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: spaceId) {
            editing = false
            showAllChats = false
            syncWatches()
        }
        .onChange(of: chromeFingerprint(space: space, sources: sources, personasCount: personas.count, spacesCount: spaces.count, chatsCount: spaceChats.count)) { _, _ in
            publishChrome(
                space: space,
                sourcesData: sourcesData,
                personas: personas,
                projects: boot?.projects ?? [],
                connectors: connectors,
                spaces: spaces,
                chats: spaceChats
            )
        }
        .onAppear {
            publishChrome(
                space: space,
                sourcesData: sourcesData,
                personas: personas,
                projects: boot?.projects ?? [],
                connectors: connectors,
                spaces: spaces,
                chats: spaceChats
            )
            installCommands(space: space)
        }
        .onChange(of: space?.id) { _, _ in
            installCommands(space: space)
        }
        .onDisappear {
            context.onCommand = nil
            for key in watchedKeys { context.store.stopObserving(key) }
            watchedKeys = []
        }
    }

    // MARK: - Header & Edit Form

    @ViewBuilder
    private func headerSection(space: API.ChatSpace, p: NativePalette) -> some View {
        if editing {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    spaceTile(name: editName.isEmpty ? space.name : editName, color: editColor, size: 36)
                    TextField("Space name", text: $editName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 16, weight: .semibold))
                }

                HStack(spacing: 6) {
                    ForEach(API.ChatSpaceColor.allKnown, id: \.rawValue) { c in
                        Button {
                            editColor = c
                        } label: {
                            Circle()
                                .fill(Color(cssHex: SpacesLogic.colorHex(for: c)) ?? .green)
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary, lineWidth: editColor == c ? 2 : 0)
                                        .padding(-2)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(SpacesLogic.colorLabel(for: c))
                    }
                }

                TextField("What this space is for", text: $editDescription)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Instructions").font(.caption).foregroundStyle(p.secondaryText)
                        Spacer()
                        Text("\(editInstructions.count) / \(SpacesLogic.maxInstructions)")
                            .font(.caption2)
                            .foregroundStyle(p.tertiaryText)
                    }
                    TextEditor(text: $editInstructions)
                        .font(.system(size: 13))
                        .frame(height: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                }

                if let work = space.work {
                    HStack(spacing: 10) {
                        Text("Tracking work as \(work.key)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(p.secondaryText)
                        Spacer()
                        Button("Stop tracking work", role: .destructive) {
                            stopTrackingWork(space: space)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(savingEdit)
                    }
                } else {
                    HStack(spacing: 8) {
                        TextField("Work key (e.g. \(SpacesLogic.suggestWorkKey(for: editName.isEmpty ? space.name : editName)))", text: $editWorkKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        TextField("Repository URL (optional)", text: $editWorkRepo)
                            .textFieldStyle(.roundedBorder)
                        Button("Track work") {
                            startTrackingWork(space: space)
                        }
                        .buttonStyle(.bordered)
                        .disabled(savingEdit || !SpacesLogic.isValidWorkKey(editWorkKey))
                    }
                }

                if let editError {
                    Text(editError)
                        .font(.caption)
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }

                HStack(spacing: 8) {
                    Button(savingEdit ? "Saving\u{2026}" : "Save") {
                        saveEdits(space: space)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(savingEdit || editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Cancel") { editing = false }
                        .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
        } else {
            HStack(alignment: .top, spacing: 12) {
                spaceTile(name: space.name, color: space.color, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(space.name)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(p.text)
                            .lineLimit(1)
                        if let work = space.work {
                            Text(work.key)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(p.tertiaryText)
                        }
                    }
                    Text(SpacesLogic.subtitle(for: space))
                        .font(.system(size: 13))
                        .foregroundStyle(p.tertiaryText)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
    }

    private func workTabsBar(space: API.ChatSpace, work: API.SpaceWork, p: NativePalette) -> some View {
        let encoded = work.key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? work.key
        return HStack(spacing: 20) {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    Text("Chats").font(.system(size: 13, weight: .medium)).foregroundStyle(p.text)
                    Text("\(space.chatCount)").font(.system(size: 12)).foregroundStyle(p.tertiaryText)
                }
                Rectangle().fill(p.accent).frame(height: 2)
            }
            .fixedSize()

            tabLink("Tickets", href: "/tickets?project=\(encoded)", p: p)
            tabLink("Epics", href: "/epics?project=\(encoded)", p: p)
            tabLink("Runs", href: "/runs?project=\(encoded)", p: p)
            Spacer()
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(p.border).frame(height: 1)
        }
    }

    private func tabLink(_ title: String, href: String, p: NativePalette) -> some View {
        Button {
            context.navigate(href)
        } label: {
            VStack(spacing: 6) {
                Text(title).font(.system(size: 13)).foregroundStyle(p.secondaryText)
                Rectangle().fill(Color.clear).frame(height: 2)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Inline Composer

    private func composerCard(
        space: API.ChatSpace,
        personas: [API.Persona],
        defaultPersonaId: String?,
        models: [API.ChatHarnessModels],
        p: NativePalette
    ) -> some View {
        let effectivePersonaId = pickedPersonaId ?? space.personaId ?? defaultPersonaId
        let activePersona = personas.first(where: { $0.id == effectivePersonaId }) ?? personas.first

        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                TextField(
                    researchMode ? "What should \(space.name) research?" : "New chat in \(space.name)",
                    text: $composerText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...8)
                .disabled(startingChat)
                .onSubmit {
                    startSpaceChat(space: space)
                }

                HStack(spacing: 8) {
                    // Persona menu
                    Menu {
                        ForEach(personas, id: \.id) { persona in
                            Button {
                                pickedPersonaId = persona.id
                            } label: {
                                if persona.id == effectivePersonaId {
                                    Label(persona.name, systemImage: "checkmark")
                                } else {
                                    Text(persona.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            WorkPersonaAvatarView(
                                id: activePersona?.id,
                                handle: nil,
                                name: activePersona?.name ?? "Assistant",
                                size: 16,
                                active: false
                            )
                            Text(activePersona?.name ?? "Assistant")
                                .font(.system(size: 12))
                                .foregroundStyle(p.text)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(p.tertiaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(p.surface, in: Capsule())
                        .overlay(Capsule().stroke(p.border))
                    }
                    .menuStyle(.borderlessButton)

                    // Model menu
                    Menu {
                        Button("Default model") {
                            pickedHarness = nil
                            pickedModel = nil
                        }
                        ForEach(models, id: \.harness.rawValue) { group in
                            Section(group.label) {
                                ForEach(group.models, id: \.id) { m in
                                    Button {
                                        pickedHarness = group.harness
                                        pickedModel = m.id
                                    } label: {
                                        let selected = pickedHarness == group.harness && pickedModel == m.id
                                        if selected {
                                            Label(m.label, systemImage: "checkmark")
                                        } else {
                                            Text(m.label)
                                        }
                                    }
                                    .disabled(!group.available)
                                }
                            }
                        }
                    } label: {
                        let modelName: String = {
                            if let h = pickedHarness, let m = pickedModel,
                               let label = models.first(where: { $0.harness == h })?.models.first(where: { $0.id == m })?.label {
                                return label
                            }
                            return "Default model"
                        }()
                        HStack(spacing: 4) {
                            Text(modelName)
                                .font(.system(size: 12))
                                .foregroundStyle(p.secondaryText)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(p.tertiaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(p.surface, in: Capsule())
                        .overlay(Capsule().stroke(p.border))
                    }
                    .menuStyle(.borderlessButton)

                    Toggle("Research", isOn: $researchMode)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .disabled(startingChat)

                    Spacer()

                    Button {
                        startSpaceChat(space: space)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !startingChat ? p.accent : p.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .disabled(startingChat || composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(researchMode ? "Plan research" : "Start chat")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.border))

            if let composerError {
                Text(composerError)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            } else {
                Text(
                    researchMode
                        ? "The persona proposes a research plan to approve; its report joins \(space.name)\u{2019}s sources."
                        : SpacesLogic.usesSummary(for: space)
                )
                .font(.system(size: 12))
                .foregroundStyle(p.tertiaryText)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Chat List

    private func chatsSection(
        space: API.ChatSpace,
        chatsEntry: QueryEntry<API.ListChatsResponse>,
        p: NativePalette
    ) -> some View {
        let sorted = SpacesLogic.sortChats(chatsEntry.data?.chats ?? [], sort: chatSort)
        let visible = showAllChats ? sorted : Array(sorted.prefix(SpacesLogic.pageChatsLimit))
        let remaining = sorted.count - visible.count

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(p.text)
                Spacer()
                Picker("Sort", selection: $chatSort) {
                    ForEach(SpacesLogic.ChatSort.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 100)
            }
            .padding(.bottom, 10)

            Divider()

            if let error = chatsEntry.error {
                Text("Couldn\u{2019}t load chats: \(error.userMessage)")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    .padding(.vertical, 14)
            } else if chatsEntry.data == nil && chatsEntry.isFetching {
                ProgressView().controlSize(.small).padding(.vertical, 16)
            } else if sorted.isEmpty {
                Text("No chats in \(space.name) yet. Start one above.")
                    .font(.system(size: 13))
                    .foregroundStyle(p.secondaryText)
                    .padding(.vertical, 18)
            } else {
                ForEach(visible, id: \.id) { chat in
                    Button {
                        context.navigate("/chat/\(chat.id)")
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    if chat.state == .running {
                                        Circle()
                                            .fill(theme.swiftUIColor("state-done", fallback: .green))
                                            .frame(width: 6, height: 6)
                                    }
                                    Text(chat.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled chat" : chat.title)
                                        .font(.system(size: 14))
                                        .foregroundStyle(p.text)
                                        .lineLimit(1)
                                }
                                Text(chat.preview ?? "No replies yet")
                                    .font(.system(size: 12))
                                    .foregroundStyle(p.tertiaryText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(APIDate.shortAgo(chat.lastMessageAt ?? chat.createdAt))
                                .font(.system(size: 11))
                                .foregroundStyle(p.tertiaryText)
                            WorkPersonaAvatarView(
                                id: chat.persona?.id,
                                handle: nil,
                                name: chat.persona?.name ?? "Assistant",
                                size: 18,
                                active: false
                            )
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                if remaining > 0 {
                    Button("Show \(remaining) more") {
                        showAllChats = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(p.accent)
                    .padding(.top, 12)
                }
            }
        }
    }

    private func spaceTile(name: String, color: API.ChatSpaceColor, size: CGFloat) -> some View {
        let bg = Color(cssHex: SpacesLogic.colorHex(for: color)) ?? .green
        return Text(SpacesLogic.initial(for: name))
            .font(.system(size: size * 0.48, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.75))
            .frame(width: size, height: size)
            .background(bg, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Chrome & Mutations

    private func chromeFingerprint(
        space: API.ChatSpace?,
        sources: [API.ChatSpaceSource],
        personasCount: Int,
        spacesCount: Int,
        chatsCount: Int
    ) -> String {
        "\(space?.id ?? "")|\(space?.name ?? "")|\(space?.instructions.count ?? 0)|\(space?.spaceMemory ?? false)|\(space?.personaId ?? "")|\(space?.sourceCount ?? 0)|\(sources.count)|\(personasCount)|\(spacesCount)|\(chatsCount)|\(editing)|\(inspectorOpen)|\(inspectorTabId)"
    }

    private func publishChrome(
        space: API.ChatSpace?,
        sourcesData: API.ChatSpaceSourceList?,
        personas: [API.Persona],
        projects: [API.Project],
        connectors: [API.Connector],
        spaces: [API.ChatSpace],
        chats: [API.ChatSession]
    ) {
        let nav = SpacesLogic.navModel(spaces: spaces, activeSpaceId: spaceId.isEmpty ? nil : spaceId, chats: chats)
        guard let space else {
            context.chrome = NativeChrome(title: "Space", navigator: nav)
            return
        }
        let projectName = space.project.flatMap { key in projects.first(where: { $0.key == key })?.name ?? key }
        let connectorNames = space.connectorIds.compactMap { id in connectors.first(where: { $0.id == id })?.name }
        let connectorsSummary = connectorNames.isEmpty ? "None" : connectorNames.joined(separator: ", ")

        let aboutSections = SpacesLogic.buildAboutInspectorSections(
            space: space,
            sources: sourcesData?.sources ?? [],
            inlineBudget: sourcesData?.inlineBudget ?? 40_000,
            inlineTokens: sourcesData?.inlineTokens ?? space.inlineTokens,
            personas: personas,
            projectName: projectName,
            connectorsSummary: connectorsSummary
        )

        let toolbar: [ShellToolbarItem] = editing ? [] : [
            ShellToolbarItem(id: "space.settings", label: "Settings", icon: "gear", kind: .button, showsLabel: true),
            ShellToolbarItem(
                id: "space.more",
                label: "More for this space",
                icon: "dots",
                kind: .menu,
                menu: [
                    MenuItem(id: "space.sources", label: "Manage sources", icon: "artifacts"),
                    MenuItem(id: "space.delete", label: "Delete space\u{2026}", icon: "trash", destructive: true),
                ]
            ),
        ]

        let inspector = InspectorModel(
            id: "space:\(space.id)",
            open: inspectorOpen,
            activeTabId: inspectorTabId,
            tabs: [
                InspectorTab(id: "about", label: "About", icon: "sidebar", kind: .native, sections: aboutSections),
                InspectorTab(id: "chat", label: "Chat", icon: "msg", kind: .companion),
            ],
            companion: CompanionContext(path: "/spaces/\(space.id)")
        )

        context.chrome = NativeChrome(
            title: space.name,
            toolbarItems: toolbar,
            inspector: inspector,
            navigator: nav
        )
    }

    private func installCommands(space: API.ChatSpace?) {
        context.onCommand = { cmd in
            if let navAction = SpacesLogic.navAction(for: cmd) {
                switch navAction {
                case .backToChat: context.navigate("/chat")
                case .newSpace: context.navigate("/spaces/new")
                case .openSpace(let id, let newTab):
                    if newTab { context.openInNewTab("/spaces/\(id)") } else { context.navigate("/spaces/\(id)") }
                case .openChat(let id, let newTab):
                    if newTab { context.openInNewTab("/chat/\(id)") } else { context.navigate("/chat/\(id)") }
                }
                return
            }
            switch cmd {
            case .inspectorVisibility(let open):
                inspectorOpen = open
            case .inspectorSelectTab(let tabId):
                inspectorTabId = tabId
                inspectorOpen = true
            case .toolbarAction(let itemId, let menuItemId):
                if itemId == "space.settings" {
                    if let space { beginEditing(space) }
                } else if menuItemId == "space.sources" {
                    showSourcesSheet = true
                } else if menuItemId == "space.delete" {
                    showDeleteAlert = true
                }
            case .inspectorAction(_, let actionId, _, _):
                if actionId == "edit_space", let space {
                    beginEditing(space)
                } else if actionId == "manage_sources" {
                    showSourcesSheet = true
                }
            case .inspectorToggle(_, let fieldId, let checked):
                if fieldId == "space_memory", let space {
                    patchSpace(space.id, patch: API.ChatSpacePatch(spaceMemory: checked))
                }
            case .inspectorChange(_, let fieldId, let value):
                if fieldId == "persona_id", let space {
                    patchSpace(space.id, patch: API.ChatSpacePatch(personaId: value))
                }
            default:
                break
            }
        }
    }

    private func beginEditing(_ space: API.ChatSpace) {
        editName = space.name
        editDescription = space.description
        editInstructions = space.instructions
        editColor = space.color
        editWorkKey = SpacesLogic.suggestWorkKey(for: space.name)
        editWorkRepo = ""
        editError = nil
        editing = true
    }

    private func patchSpace(_ id: String, patch: API.ChatSpacePatch) {
        Task {
            do {
                let updated = try await context.store.mutate(
                    API.updateChatSpace(spaceId: id, body: patch),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                context.store.setData(updated, for: spaceRequest)
            } catch {
                context.showToast(ToastItemModel(id: "space.patch", title: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
            }
        }
    }

    private func saveEdits(space: API.ChatSpace) {
        let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        savingEdit = true
        editError = nil
        Task {
            defer { savingEdit = false }
            do {
                let updated = try await context.store.mutate(
                    API.updateChatSpace(
                        spaceId: space.id,
                        body: API.ChatSpacePatch(
                            color: editColor,
                            description: editDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                            instructions: editInstructions.trimmingCharacters(in: .whitespacesAndNewlines),
                            name: name
                        )
                    ),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                context.store.setData(updated, for: spaceRequest)
                editing = false
            } catch {
                editError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func startTrackingWork(space: API.ChatSpace) {
        let key = editWorkKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard SpacesLogic.isValidWorkKey(key) else { return }
        let repo = editWorkRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        savingEdit = true
        editError = nil
        Task {
            defer { savingEdit = false }
            do {
                let updated = try await context.store.mutate(
                    API.trackSpaceWork(spaceId: space.id, body: API.SpaceWorkInput(key: key, repoUrl: repo.isEmpty ? nil : repo)),
                    invalidating: QueryInvalidation(resources: ["spaces", "bootstrap"])
                )
                context.store.setData(updated, for: spaceRequest)
            } catch {
                editError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func stopTrackingWork(space: API.ChatSpace) {
        savingEdit = true
        editError = nil
        Task {
            defer { savingEdit = false }
            do {
                let updated = try await context.store.mutate(
                    API.stopSpaceWork(spaceId: space.id),
                    invalidating: QueryInvalidation(resources: ["spaces", "bootstrap"])
                )
                context.store.setData(updated, for: spaceRequest)
            } catch {
                editError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func deleteSpace(_ space: API.ChatSpace) {
        deleting = true
        Task {
            defer { deleting = false }
            do {
                _ = try await context.store.mutate(
                    API.deleteChatSpace(spaceId: space.id),
                    invalidating: QueryInvalidation(resources: ["spaces", "chats"])
                )
                context.navigate("/chat")
            } catch {
                context.showToast(ToastItemModel(id: "space.del", title: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
            }
        }
    }

    private func startSpaceChat(space: API.ChatSpace) {
        let body = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !startingChat else { return }
        startingChat = true
        composerError = nil
        Task {
            defer { startingChat = false }
            do {
                let created = try await context.store.mutate(
                    API.createChat(body: API.NewChat(
                        harness: pickedHarness,
                        model: pickedModel,
                        personaId: pickedPersonaId,
                        spaceId: space.id
                    )),
                    invalidating: QueryInvalidation(resources: ["chats", "spaces"])
                )
                _ = try await context.store.mutate(
                    API.postChatMessage(
                        id: created.id,
                        body: API.NewChatMessage(body: body, research: researchMode ? true : nil)
                    ),
                    invalidating: QueryInvalidation(resources: ["chats", "spaces"])
                )
                composerText = ""
                context.navigate("/chat/\(created.id)")
            } catch {
                composerError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func syncWatches() {
        for key in watchedKeys { context.store.stopObserving(key) }
        watchedKeys = []

        func watch<T: Decodable & Sendable>(_ req: APIRequest<T>) {
            context.store.observe(req)
            context.store.load(req)
            watchedKeys.append(req.key)
        }

        if !spaceId.isEmpty {
            watch(spaceRequest)
            watch(sourcesRequest)
            watch(chatsRequest)
        }
        watch(Self.personasRequest)
        watch(Self.modelsRequest)
        watch(Self.bootRequest)
        watch(Self.connectorsRequest)
        watch(Self.spacesRequest)
    }
}

/// Sources management modal for a Space: upload files, paste text, add websites, and remove sources.
private struct SpaceSourcesSheet: View {
    enum AddMode { case list, text, website }

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let spaceId: String
    let spaceName: String

    @State private var mode: AddMode = .list
    @State private var titleInput = ""
    @State private var textInput = ""
    @State private var urlInput = ""
    @State private var busy = false
    @State private var errorMessage: String?

    private var sourcesRequest: APIRequest<API.ChatSpaceSourceList> {
        API.listChatSpaceSources(spaceId: spaceId)
    }

    var body: some View {
        let p = theme.palette
        let data = context.store.entry(sourcesRequest).data
        let sources = data?.sources ?? []

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(spaceName) sources")
                    .font(.headline)
                Spacer()
                if let data {
                    Text("\(SpacesLogic.formatTokens(data.inlineTokens)) / \(SpacesLogic.formatTokens(data.inlineBudget)) inline")
                        .font(.caption.monospaced())
                        .foregroundStyle(p.tertiaryText)
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark").foregroundStyle(p.secondaryText)
                }
                .buttonStyle(.plain)
            }

            if mode == .list {
                HStack(spacing: 8) {
                    Button { uploadFile() } label: {
                        Label("Upload file", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)

                    Button {
                        mode = .text
                        titleInput = ""
                        textInput = ""
                        errorMessage = nil
                    } label: {
                        Label("Paste text", systemImage: "text.alignleft")
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)

                    Button {
                        mode = .website
                        urlInput = ""
                        errorMessage = nil
                    } label: {
                        Label("Add website", systemImage: "globe")
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }

                Divider()

                if sources.isEmpty {
                    Text("No sources yet. Upload files, paste notes, or add websites for every chat in this space.")
                        .font(.callout)
                        .foregroundStyle(p.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(sources, id: \.id) { s in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(SpacesLogic.sourceName(s))
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(1)
                                        Text(SpacesLogic.sourceDetail(s))
                                            .font(.system(size: 11))
                                            .foregroundStyle(p.tertiaryText)
                                    }
                                    Spacer()
                                    Text(s.delivery == .inline ? "Inline" : "Searched")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(s.delivery == .inline ? theme.swiftUIColor("state-done", fallback: .green) : p.accent)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(p.surface, in: Capsule())
                                        .overlay(Capsule().stroke(p.border))
                                    if let url = s.url, !url.isEmpty {
                                        Button { context.openExternal(url) } label: {
                                            Image(systemName: "arrow.up.right.square").font(.system(size: 12))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Open URL")
                                    }
                                    Button {
                                        removeSource(s.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 12))
                                            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(busy)
                                }
                                .padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }
                    .frame(minHeight: 200, maxHeight: 340)
                }
            } else if mode == .text {
                TextField("Title", text: $titleInput).textFieldStyle(.roundedBorder)
                TextEditor(text: $textInput)
                    .font(.system(size: 13))
                    .frame(height: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
                HStack {
                    Button("Back") { mode = .list }
                    Spacer()
                    Button(busy ? "Adding\u{2026}" : "Add text source") {
                        addTextSource()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if mode == .website {
                TextField("https://example.com/guide", text: $urlInput).textFieldStyle(.roundedBorder)
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
                HStack {
                    Button("Back") { mode = .list }
                    Spacer()
                    Button(busy ? "Fetching\u{2026}" : "Add website") {
                        addWebsiteSource()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { context.store.load(sourcesRequest) }
    }

    private func addTextSource() {
        let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = titleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await context.store.mutate(
                    API.addChatSpaceSource(
                        spaceId: spaceId,
                        body: API.NewChatSpaceSource(kind: .text, text: text, title: title.isEmpty ? "Notes" : title)
                    ),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                _ = await context.store.refetch(sourcesRequest)
                mode = .list
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func addWebsiteSource() {
        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await context.store.mutate(
                    API.addChatSpaceSource(
                        spaceId: spaceId,
                        body: API.NewChatSpaceSource(kind: .website, url: url)
                    ),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                _ = await context.store.refetch(sourcesRequest)
                mode = .list
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func uploadFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf, .plainText, .commaSeparatedText, .json, .png, .jpeg, .gif, .webP]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Couldn\u{2019}t read selected file."
            return
        }
        var form = APIMultipartForm()
        let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        form.addFile("file", filename: url.lastPathComponent, contentType: contentType, data: data)
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await context.store.mutate(
                    API.uploadChatSpaceSource(spaceId: spaceId, body: form),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                _ = await context.store.refetch(sourcesRequest)
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func removeSource(_ sourceId: String) {
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await context.store.mutate(
                    API.deleteChatSpaceSource(spaceId: spaceId, sourceId: sourceId),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                _ = await context.store.refetch(sourcesRequest)
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
