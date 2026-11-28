import SwiftUI
import VesperCore

/// Header pill + popover for managing multi-persona chat participants, switching
/// the default next speaker, and launching a structured `/roundtable`.
struct ChatParticipantsPopoverView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let session: API.ChatSession
    let allPersonas: [API.Persona]
    let onSendRoundtable: @MainActor (String) async -> String?

    @State private var open = false
    @State private var isHovered = false
    @State private var busyPersonaId: String?
    @State private var errorMessage: String?
    @State private var roundtableIds: Set<String> = []
    @State private var roundtableTopic = ""
    @State private var sendingRoundtable = false

    private var participants: [API.PersonaSummary] {
        session.participants ?? []
    }

    private var hostId: String? {
        session.persona?.id
    }

    private var speakerId: String? {
        session.speaker?.id ?? session.persona?.id
    }

    private var addablePersonas: [API.Persona] {
        let existing = Set(participants.map(\.id))
        return allPersonas.filter { !existing.contains($0.id) }
    }

    var body: some View {
        let p = theme.palette

        Button {
            if !open {
                seedRoundtableSelection()
            }
            open.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: participants.count > 1 ? "person.2.fill" : "person.badge.plus")
                    .imageScale(.small)
                if participants.count > 1 {
                    Text(participants.prefix(3).map { "@\($0.name)" }.joined(separator: " "))
                        .lineLimit(1)
                    if participants.count > 3 {
                        Text("+\(participants.count - 3)")
                            .font(.system(size: theme.pointSize(.micro), weight: .semibold, design: .monospaced))
                    }
                } else {
                    Text("Personas")
                        .lineLimit(1)
                }
            }
            .font(.system(size: theme.pointSize(.micro), weight: .medium))
            .foregroundStyle(participants.count > 1 ? p.text : p.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (open ? p.selected : (participants.count > 1 ? p.surface.opacity(0.85) : (isHovered ? p.hover : Color.clear))),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(
                    open
                        ? p.accent.opacity(0.45)
                        : (participants.count > 1 ? p.border : Color.clear)
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Manage chat participants, next speaker, or start a roundtable")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Participants")
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .foregroundStyle(p.text)
                    Spacer()
                    Text("\(max(1, participants.count)) in chat")
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(p.secondaryText)
                }

                // Current participants
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(participants, id: \.id) { part in
                        let isHost = part.id == hostId
                        let isSpeaker = part.id == speakerId
                        HStack(spacing: 8) {
                            WorkPersonaAvatarView(
                                id: part.id,
                                handle: nil,
                                name: part.name,
                                size: 20,
                                state: .idle,
                                active: isSpeaker,
                                preferCharacter: true
                            )
                            Text(part.name)
                                .font(.system(size: theme.pointSize(.small), weight: isSpeaker ? .semibold : .regular))
                                .foregroundStyle(p.text)
                                .lineLimit(1)
                            if isHost {
                                TonePill(label: "Host", tone: "neutral")
                            }
                            if isSpeaker {
                                TonePill(label: "Next", tone: "accent")
                            }
                            Spacer()
                            if !isSpeaker {
                                Button("Speak next") {
                                    Task { await setSpeaker(part.id) }
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: theme.pointSize(.micro)))
                                .disabled(busyPersonaId != nil)
                            }
                            if !isHost {
                                Button {
                                    Task { await removeParticipant(part.id) }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(p.secondaryText)
                                }
                                .buttonStyle(.plain)
                                .help("Remove \(part.name) from chat")
                                .disabled(busyPersonaId != nil)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // Add other personas
                if !addablePersonas.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add to conversation")
                            .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                            .foregroundStyle(p.secondaryText)
                        FlowWrapChips(items: addablePersonas) { persona in
                            Button {
                                Task { await addParticipant(persona.id) }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 9, weight: .bold))
                                    Text(persona.name)
                                }
                                .font(.system(size: theme.pointSize(.micro), weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(p.surface, in: Capsule())
                                .overlay(Capsule().stroke(p.border))
                            }
                            .buttonStyle(.plain)
                            .disabled(busyPersonaId != nil)
                        }
                    }
                }

                // Roundtable launcher
                if allPersonas.count >= 2 {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Roundtable", systemImage: "bubble.left.and.bubble.right")
                                .font(.system(size: theme.pointSize(.small), weight: .semibold))
                                .foregroundStyle(p.text)
                            Spacer()
                            Text("1 take each")
                                .font(.system(size: theme.pointSize(.micro)))
                                .foregroundStyle(p.tertiaryText)
                        }
                        FlowWrapChips(items: allPersonas) { persona in
                            let selected = roundtableIds.contains(persona.id)
                            Button {
                                if selected {
                                    roundtableIds.remove(persona.id)
                                } else {
                                    roundtableIds.insert(persona.id)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 10))
                                    Text(persona.name)
                                }
                                .font(.system(size: theme.pointSize(.micro), weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? p.accent : p.secondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(selected ? p.selected : p.surface, in: Capsule())
                                .overlay(Capsule().stroke(selected ? p.accent.opacity(0.6) : p.border))
                            }
                            .buttonStyle(.plain)
                        }
                        TextField("Topic or question for the roundtable…", text: $roundtableTopic)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: theme.pointSize(.small)))
                        HStack {
                            Spacer()
                            Button {
                                Task { await launchRoundtable() }
                            } label: {
                                Text(sendingRoundtable ? "Starting…" : "Start Roundtable")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(
                                sendingRoundtable
                                    || session.state == .running
                                    || roundtableIds.count < 2
                                    || roundtableTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
            }
            .padding(14)
            .frame(width: 320)
        }
    }

    private func seedRoundtableSelection() {
        if participants.count >= 2 {
            roundtableIds = Set(participants.map(\.id))
        } else {
            roundtableIds = Set(allPersonas.prefix(3).map(\.id))
        }
    }

    private func addParticipant(_ personaId: String) async {
        busyPersonaId = personaId
        errorMessage = nil
        defer { busyPersonaId = nil }
        do {
            let updated = try await context.store.mutate(
                API.addChatParticipant(id: session.id, body: API.ChatParticipantAdd(personaId: personaId)),
                invalidating: QueryInvalidation(resources: ["chats"])
            )
            context.store.setData(updated, for: API.getChat(id: session.id))
            roundtableIds.insert(personaId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeParticipant(_ personaId: String) async {
        busyPersonaId = personaId
        errorMessage = nil
        defer { busyPersonaId = nil }
        do {
            let updated = try await context.store.mutate(
                API.removeChatParticipant(id: session.id, personaId: personaId),
                invalidating: QueryInvalidation(resources: ["chats"])
            )
            context.store.setData(updated, for: API.getChat(id: session.id))
            roundtableIds.remove(personaId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setSpeaker(_ personaId: String) async {
        busyPersonaId = personaId
        errorMessage = nil
        defer { busyPersonaId = nil }
        do {
            let updated = try await context.store.mutate(
                API.setChatSpeaker(id: session.id, body: API.ChatSpeakerUpdate(personaId: .value(personaId))),
                invalidating: QueryInvalidation(resources: ["chats"])
            )
            context.store.setData(updated, for: API.getChat(id: session.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func launchRoundtable() async {
        let orderedNames = allPersonas
            .filter { roundtableIds.contains($0.id) }
            .map(\.name)
        switch ChatRoundtableLogic.buildPrompt(selectedNames: orderedNames, topic: roundtableTopic) {
        case .error(let msg):
            errorMessage = msg
        case .prompt(let prompt):
            sendingRoundtable = true
            errorMessage = nil
            defer { sendingRoundtable = false }
            if let err = await onSendRoundtable(prompt) {
                errorMessage = err
            } else {
                roundtableTopic = ""
                open = false
            }
        }
    }
}

private struct FlowWrapChips<Content: View>: View {
    let items: [API.Persona]
    @ViewBuilder let content: (API.Persona) -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.id) { item in
                    content(item)
                }
            }
        }
    }
}
