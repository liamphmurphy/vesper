import AVFoundation
import SwiftUI
import VesperCore

/// A persona's spoken voice for the talking phase: when it speaks, which voice, how it delivers,
/// with a preview before saving. Replies are spoken up to about 120 words of prose.
struct SettingsPersonaVoiceCard: View {
    let aux: AuxWindows
    let persona: API.Persona

    @State private var mode = "off"
    @State private var voice = ""
    @State private var style = ""
    @State private var busy = false
    @State private var previewing = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var player: AVAudioPlayer?

    private var store: QueryStore? { aux.store }
    private static let voicesRequest = API.listPersonaVoices()

    var body: some View {
        let list = store?.entry(Self.voicesRequest).data
        let changed = mode != persona.voice.mode.rawValue || voice != persona.voice.name || style != persona.voice.style

        SettingsCard("Voice", subtitle: "\(persona.name) can read new replies aloud while the Talking loop plays: up to about 120 words of prose, never code or links. Each spoken reply costs about a cent and is cached, so replays are free.") {
            if let errorMessage {
                SettingsBanner(tone: .blocked, title: "Couldn't update the voice", message: errorMessage)
            }
            if let statusMessage {
                SettingsBanner(tone: .done, title: statusMessage)
            }
            if let list, !list.available {
                Text(list.reason ?? "No speech provider is configured.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Picker("Speak", selection: $mode) {
                Text("Off").tag("off")
                Text("In the pop-out only").tag("popout")
                Text("Always (pop-out and chat)").tag("always")
            }
            .pickerStyle(.segmented)
            Picker("Voice", selection: $voice) {
                Text("Default\(list?.defaultVoice.map { " (\($0))" } ?? "")").tag("")
                ForEach(list?.voices ?? [], id: \.name) { v in
                    Text("\(v.name) · \(v.tone)").tag(v.name)
                }
            }
            .disabled(list?.available != true)
            TextField("Delivery, e.g. warm, unhurried, a little playful", text: $style)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(previewing ? "Speaking…" : "Preview") { preview() }
                    .disabled(previewing || list?.available != true)
                Text("The mute switch on the chat companion silences every persona.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(busy ? "Saving…" : "Save Voice") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !changed)
            }
        }
        .task { store?.load(Self.voicesRequest) }
        .onAppear { sync() }
        .onChange(of: persona.revision) { _, _ in sync() }
    }

    private func sync() {
        mode = persona.voice.mode.rawValue
        voice = persona.voice.name
        style = persona.voice.style
    }

    private func preview() {
        guard let client = aux.client() else { return }
        previewing = true
        errorMessage = nil
        Task {
            defer { previewing = false }
            do {
                let data = try await client.send(API.previewPersonaVoice(id: persona.id, body: API.PreviewPersonaVoiceBody(voiceName: voice, voiceStyle: style)))
                let audio = try AVAudioPlayer(data: data)
                player = audio
                audio.play()
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func save() {
        guard let store else { return }
        busy = true
        errorMessage = nil
        statusMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.updatePersona(id: persona.id, body: API.PersonaPatch(
                    revision: persona.revision,
                    voiceMode: API.PersonaVoiceMode(rawValue: mode),
                    voiceName: voice,
                    voiceStyle: style
                )))
                await store.refetch(API.listPersonas())
                statusMessage = "Voice saved."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }
}
