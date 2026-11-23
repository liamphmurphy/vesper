import SwiftUI
import VesperCore

/// Native `/spaces` and `/spaces/new` screen for creating a new Space (with optional work tracking).
struct NewSpaceScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var name = ""
    @State private var color: API.ChatSpaceColor = .green
    @State private var description = ""
    @State private var instructions = ""
    @State private var personaId = ""
    @State private var projectKey = ""
    @State private var spaceMemory = true
    @State private var trackingWork = false
    @State private var typedKey: String?
    @State private var repoUrl = ""
    @State private var creating = false
    @State private var errorMessage: String?

    private static let personasRequest = API.listPersonas()
    private static let bootRequest = API.getBootstrap()
    private static let spacesRequest = API.listChatSpaces()

    var body: some View {
        let p = theme.palette
        let personas = context.store.entry(Self.personasRequest).data?.personas ?? []
        let projects = (context.store.entry(Self.bootRequest).data?.projects ?? []).filter { !$0.archived }
        let spaces = context.store.entry(Self.spacesRequest).data?.spaces ?? []
        let effectiveKey = (typedKey ?? SpacesLogic.suggestWorkKey(for: name)).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let workOk = !trackingWork || SpacesLogic.isValidWorkKey(effectiveKey)
        let canCreate = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && workOk && !creating

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New space")
                        .vesperText(.display, theme)
                    Text("Group chats with shared instructions, sources, isolated memory, and optional tickets/runs.")
                        .vesperText(.body, theme)
                        .foregroundStyle(p.secondaryText)
                }

                VStack(alignment: .leading, spacing: 16) {
                    // Name + color
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name").font(.caption).foregroundStyle(p.secondaryText)
                        HStack(spacing: 12) {
                            let bg = Color(cssHex: SpacesLogic.colorHex(for: color)) ?? .green
                            Text(SpacesLogic.initial(for: name))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Color.black.opacity(0.75))
                                .frame(width: 34, height: 34)
                                .background(bg, in: RoundedRectangle(cornerRadius: 8))
                            TextField("Health", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack(spacing: 8) {
                            ForEach(API.ChatSpaceColor.allKnown, id: \.rawValue) { c in
                                Button {
                                    color = c
                                } label: {
                                    Circle()
                                        .fill(Color(cssHex: SpacesLogic.colorHex(for: c)) ?? .green)
                                        .frame(width: 18, height: 18)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.primary, lineWidth: color == c ? 2 : 0)
                                                .padding(-2)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(SpacesLogic.colorLabel(for: c))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description").font(.caption).foregroundStyle(p.secondaryText)
                        TextField("Workouts, nutrition and recovery", text: $description)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Instructions").font(.caption).foregroundStyle(p.secondaryText)
                            Spacer()
                            Text("\(instructions.count) / \(SpacesLogic.maxInstructions)")
                                .font(.caption2)
                                .foregroundStyle(p.tertiaryText)
                        }
                        TextEditor(text: $instructions)
                            .font(.system(size: 13))
                            .frame(height: 110)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Default persona").font(.caption).foregroundStyle(p.secondaryText)
                            Picker("Default persona", selection: $personaId) {
                                Text("Default persona").tag("")
                                ForEach(personas, id: \.id) { persona in
                                    Text(persona.name).tag(persona.id)
                                }
                            }
                            .labelsHidden()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !trackingWork {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Project for new tickets").font(.caption).foregroundStyle(p.secondaryText)
                                Picker("Project", selection: $projectKey) {
                                    Text("None").tag("")
                                    ForEach(projects, id: \.key) { proj in
                                        Text("\(proj.name) (\(proj.key))").tag(proj.key)
                                    }
                                }
                                .labelsHidden()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Toggle("Space memory (keep memories saved here isolated from general memory)", isOn: $spaceMemory)

                    Divider()

                    Toggle("Track work (tickets, epics, runs and a repository)", isOn: $trackingWork)

                    if trackingWork {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Work key").font(.caption).foregroundStyle(p.secondaryText)
                                TextField(
                                    "PROJ",
                                    text: Binding(
                                        get: { effectiveKey },
                                        set: { typedKey = $0.uppercased() }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, design: .monospaced))
                                if !effectiveKey.isEmpty && !SpacesLogic.isValidWorkKey(effectiveKey) {
                                    Text("2\u{2013}10 letters or digits starting with a letter.")
                                        .font(.caption2)
                                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                                }
                            }
                            .frame(width: 180)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Repository URL (optional)").font(.caption).foregroundStyle(p.secondaryText)
                                TextField("https://github.com/owner/repo", text: $repoUrl)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    }

                    HStack {
                        Spacer()
                        Button("Cancel") { context.navigate("/chat") }
                            .buttonStyle(.bordered)
                            .disabled(creating)
                        Button(creating ? "Creating\u{2026}" : "Create space") {
                            createSpace(workKey: effectiveKey)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCreate)
                    }
                }
                .padding(18)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))

                if !spaces.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("EXISTING SPACES")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(p.tertiaryText)
                        ForEach(spaces, id: \.id) { sp in
                            Button {
                                context.navigate("/spaces/\(sp.id)")
                            } label: {
                                HStack(spacing: 10) {
                                    let bg = Color(cssHex: SpacesLogic.colorHex(for: sp.color)) ?? .green
                                    Text(SpacesLogic.initial(for: sp.name))
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color.black.opacity(0.75))
                                        .frame(width: 26, height: 26)
                                        .background(bg, in: RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(sp.name).font(.system(size: 13, weight: .medium)).foregroundStyle(p.text)
                                        Text(SpacesLogic.subtitle(for: sp)).font(.system(size: 11)).foregroundStyle(p.tertiaryText)
                                    }
                                    Spacer()
                                    if let key = sp.work?.key {
                                        Text(key).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.tertiaryText)
                                    }
                                }
                                .padding(10)
                                .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: spaces.map(\.id), initial: true) { _, _ in
            context.chrome = NativeChrome(
                title: "New space",
                navigator: SpacesLogic.navModel(spaces: spaces, activeSpaceId: nil)
            )
        }
        .onAppear {
            trackingWork = context.match.query["work"] == "1"
            context.chrome = NativeChrome(
                title: "New space",
                navigator: SpacesLogic.navModel(spaces: spaces, activeSpaceId: nil)
            )
            context.onCommand = { cmd in
                guard let action = SpacesLogic.navAction(for: cmd) else { return }
                switch action {
                case .backToChat: context.navigate("/chat")
                case .newSpace: break
                case .openSpace(let id, let newTab):
                    if newTab { context.openInNewTab("/spaces/\(id)") } else { context.navigate("/spaces/\(id)") }
                case .openChat(let id, let newTab):
                    if newTab { context.openInNewTab("/chat/\(id)") } else { context.navigate("/chat/\(id)") }
                }
            }
            context.store.observe(Self.spacesRequest)
            context.store.load(Self.personasRequest)
            context.store.load(Self.bootRequest)
            context.store.load(Self.spacesRequest)
        }
        .onDisappear {
            context.onCommand = nil
            context.store.stopObserving(Self.spacesRequest.key)
        }
    }

    private func createSpace(workKey: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let trimmedRepo = repoUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        creating = true
        errorMessage = nil
        Task {
            defer { creating = false }
            do {
                let created = try await context.store.mutate(
                    API.createChatSpace(body: API.NewChatSpace(
                        color: color,
                        description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                        instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
                        name: trimmedName,
                        personaId: personaId.isEmpty ? nil : personaId,
                        project: (!trackingWork && !projectKey.isEmpty) ? projectKey : nil,
                        spaceMemory: spaceMemory,
                        work: trackingWork ? API.SpaceWorkInput(key: workKey, repoUrl: trimmedRepo.isEmpty ? nil : trimmedRepo) : nil
                    )),
                    invalidating: QueryInvalidation(resources: ["spaces", "bootstrap"])
                )
                context.navigate("/spaces/\(created.id)")
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
