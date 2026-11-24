import SwiftUI
import VesperCore

/// Native `/spaces/new` screen for creating a new Space.
struct NewSpaceScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var name = ""
    @State private var color: API.ChatSpaceColor = .green
    @State private var description = ""
    @State private var instructions = ""
    @State private var personaId = ""
    @State private var spaceMemory = true
    @State private var creating = false
    @State private var errorMessage: String?

    private static let personasRequest = API.listPersonas()
    private static let spacesRequest = API.listChatSpaces()

    var body: some View {
        let p = theme.palette
        let personas = context.store.entry(Self.personasRequest).data?.personas ?? []
        let spaces = context.store.entry(Self.spacesRequest).data?.spaces ?? []
        let canCreate = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !creating

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New space")
                        .vesperText(.display, theme)
                    Text("A dedicated room for ongoing work with shared instructions, repos, Knowledge folders, tasks, and isolated memory.")
                        .vesperText(.body, theme)
                        .foregroundStyle(p.secondaryText)
                }

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name").font(.caption).foregroundStyle(p.secondaryText)
                        HStack(spacing: 12) {
                            let bg = Color(cssHex: SpacesLogic.colorHex(for: color)) ?? .green
                            Text(SpacesLogic.initial(for: name))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Color.black.opacity(0.75))
                                .frame(width: 34, height: 34)
                                .background(bg, in: RoundedRectangle(cornerRadius: 8))
                            TextField("Vesper", text: $name)
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
                        TextField("What this space is for", text: $description)
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

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Assigned persona").font(.caption).foregroundStyle(p.secondaryText)
                        Picker("Assigned persona", selection: $personaId) {
                            Text("Default persona").tag("")
                            ForEach(personas, id: \.id) { persona in
                                Text(persona.name).tag(persona.id)
                            }
                        }
                        .labelsHidden()
                    }

                    Toggle("Space memory (keep memories saved here isolated from general memory)", isOn: $spaceMemory)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    }

                    HStack {
                        Spacer()
                        Button("Cancel") {
                            if let first = spaces.first {
                                context.navigate("/spaces/\(first.id)")
                            } else {
                                context.navigate("/chat")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(creating)
                        Button(creating ? "Creating\u{2026}" : "Create space") {
                            createSpace()
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
                navigator: SpacesLogic.navModel(spaces: spaces, activeSpaceId: nil, personas: personas, origin: context.baseURL())
            )
        }
        .onAppear {
            context.chrome = NativeChrome(
                title: "New space",
                navigator: SpacesLogic.navModel(spaces: spaces, activeSpaceId: nil, personas: personas, origin: context.baseURL())
            )
            context.onCommand = { cmd in
                guard let action = SpacesLogic.navAction(for: cmd) else { return }
                switch action {
                case .newSpace: break
                case .openSpace(let id, let newTab):
                    if newTab { context.openInNewTab("/spaces/\(id)") } else { context.navigate("/spaces/\(id)") }
                case .openChat(let id, let newTab):
                    if newTab { context.openInNewTab("/chat/\(id)") } else { context.navigate("/chat/\(id)") }
                }
            }
            context.store.observe(Self.spacesRequest)
            context.store.load(Self.personasRequest)
            context.store.load(Self.spacesRequest)
        }
        .onDisappear {
            context.onCommand = nil
            context.store.stopObserving(Self.spacesRequest.key)
        }
    }

    private func createSpace() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
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
                        spaceMemory: spaceMemory
                    )),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                context.navigate("/spaces/\(created.id)")
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
