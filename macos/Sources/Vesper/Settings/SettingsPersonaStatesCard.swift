import SwiftUI
import VesperCore

/// Generate, preview, tweak and clear a persona's photorealistic state loops (LAZYAGENTS-312).
/// Generation runs on the server; this polls the list while any state is queued or running.
struct SettingsPersonaStatesCard: View {
    let aux: AuxWindows
    @Bindable var navigation: SettingsNavigation
    let persona: API.Persona

    @State private var selected: API.PersonaState = .idle
    @State private var tweak = ""
    @State private var busy = false
    @State private var errorMessage: String?

    private var store: QueryStore? { aux.store }
    private var request: APIRequest<API.PersonaStateMediaList> { API.listPersonaStateMedia(id: persona.id) }

    var body: some View {
        let rows = store?.entry(request).data?.states ?? []
        let byState = Dictionary(rows.map { ($0.state, $0) }, uniquingKeysWith: { a, _ in a })
        let generating = rows.contains { $0.status == .queued || $0.status == .running }
        let loops = Dictionary(rows.compactMap { r in r.loopUrl.map { (r.state.rawValue, $0) } }, uniquingKeysWith: { a, _ in a })
        let current = byState[selected]

        SettingsCard("Animated States", subtitle: "Photorealistic loops for each state (idle, thinking, reading, coding, creating, needs-you, talking and complete), made from \(persona.name)'s portrait and cut out on a transparent background.") {
            if let errorMessage {
                SettingsBanner(tone: .blocked, title: "Couldn't update animated states", message: errorMessage)
            }
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .underPageBackgroundColor))
                    if let url = current?.loopUrl {
                        PersonaStateStageView(loops: [selected.rawValue: url], state: characterState(selected), width: 108, label: "\(persona.name), \(label(selected))")
                    } else {
                        Text(current?.status == .failed ? "No loop" : "Not generated")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 124, height: 214)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(API.PersonaState.allKnown, id: \.rawValue) { s in
                        stateRow(s, row: byState[s])
                    }
                    if let backend = rows.first(where: { $0.backend != nil })?.backend {
                        Text(backend == "vision" ? "Matted with Apple Vision" : "Matted with ffmpeg chroma key")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Picker("Loop length", selection: Binding(
                get: { persona.loopSeconds },
                set: { setLoopSeconds($0) }
            )) {
                ForEach(4...10, id: \.self) { s in
                    Text(s == 8 ? "\(s) seconds (default)" : "\(s) seconds").tag(s)
                }
            }
            .disabled(busy)
            Text("Each state is one Omni generation either way; longer loops get more movement out of it. Applies to loops generated from now on.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Reply pace", selection: Binding(
                get: { persona.revealPace.rawValue },
                set: { setPace($0) }
            )) {
                Text("Auto (natural with a Talking loop)").tag("auto")
                Text("Off: show replies at once").tag("off")
                Text("Relaxed (~25 words/s)").tag("relaxed")
                Text("Natural (~15 words/s)").tag("natural")
                Text("Deliberate (~8 words/s)").tag("deliberate")
            }
            .disabled(busy)
            Text("How fast a new reply is revealed in chats while \(persona.name)'s Talking loop plays.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            HStack(spacing: 8) {
                TextField(current?.canTweak == true ? "Tweak \(label(selected)) (optional), e.g. tap the chin more slowly" : "Regenerate \(label(selected)) from the portrait",
                          text: $tweak)
                    .textFieldStyle(.roundedBorder)
                    .disabled(current?.canTweak != true)
                Button("Regenerate \(label(selected).capitalized)") { regenerate(selected, canTweak: current?.canTweak == true) }
                    .disabled(busy || isRunning(current))
            }
            HStack {
                Button(generating ? "Generating…" : (rows.isEmpty ? "Generate Animated States" : "Regenerate All")) { generate(states: nil) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || generating)
                if !rows.isEmpty {
                    Button("Clear Animated States") { clear() }
                        .disabled(busy)
                }
                Spacer()
                Text("Uses the persona's reference image, else its photo, and the workspace's video provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Media providers…") {
                    navigation.navigate("/settings?section=workspace#media")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .task(id: persona.id) { await refresh() }
        .task(id: generating) {
            // Progress has no realtime event; poll while anything is in flight.
            while generating, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await refresh()
            }
        }
    }

    @ViewBuilder private func stateRow(_ s: API.PersonaState, row: API.PersonaStateMedia?) -> some View {
        Button {
            selected = s
            tweak = ""
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected == s ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected == s ? Color.accentColor : .secondary)
                Text(label(s).capitalized).font(.callout.weight(selected == s ? .semibold : .regular))
                Spacer(minLength: 8)
                statusChip(row)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row?.error ?? row?.stageNote ?? "")
    }

    @ViewBuilder private func statusChip(_ row: API.PersonaStateMedia?) -> some View {
        switch row?.status {
        case .some(.queued), .some(.running):
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(row.map { "\($0.percent)%" + ($0.stageNote.map { " · \($0)" } ?? "") } ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .some(.ready):
            SettingsBadge(label: "Ready", tone: .done)
        case .some(.failed):
            HStack(spacing: 4) {
                SettingsBadge(label: row?.loopUrl != nil ? "Retry failed" : "Failed", tone: .blocked)
                Text(row?.error ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        default:
            Text("—").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func isRunning(_ row: API.PersonaStateMedia?) -> Bool {
        row?.status == .queued || row?.status == .running
    }

    private func label(_ s: API.PersonaState) -> String {
        s == .needsYou ? "needs-you" : s.rawValue
    }

    private func characterState(_ s: API.PersonaState) -> CharacterState {
        CharacterState(rawValue: s.rawValue) ?? .idle
    }

    private func refresh() async {
        guard let store else { return }
        await store.refetch(request)
        // The Persona summaries other screens play from follow the list.
        await store.refetch(API.listPersonas())
    }

    private func regenerate(_ s: API.PersonaState, canTweak: Bool) {
        let t = tweak.trimmingCharacters(in: .whitespacesAndNewlines)
        generate(states: [s], tweak: canTweak && !t.isEmpty ? t : nil)
        tweak = ""
    }

    private func generate(states: [API.PersonaState]?, tweak: String? = nil) {
        guard let store else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.generatePersonaStateMedia(id: persona.id, body: API.GeneratePersonaStateMedia(states: states, tweak: tweak)))
                await refresh()
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func setLoopSeconds(_ seconds: Int) {
        guard let store, seconds != persona.loopSeconds else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.updatePersona(id: persona.id, body: API.PersonaPatch(
                    loopSeconds: seconds,
                    revision: persona.revision
                )))
                await store.refetch(API.listPersonas())
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func setPace(_ pace: String) {
        guard let store, pace != persona.revealPace.rawValue else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.updatePersona(id: persona.id, body: API.PersonaPatch(
                    revealPace: API.PersonaRevealPace(rawValue: pace),
                    revision: persona.revision
                )))
                await store.refetch(API.listPersonas())
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func clear() {
        guard SettingsFilePanels.confirm(
            title: "Clear \(persona.name)'s animated states?",
            message: "Removes every state loop and stops any generation in progress. \(persona.name) goes back to its picture or character.",
            confirmLabel: "Clear"
        ) else { return }
        guard let store else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.clearPersonaStateMedia(id: persona.id))
                await refresh()
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }
}
