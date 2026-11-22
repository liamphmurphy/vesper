import AppKit
import AVFoundation
import SwiftUI
import VesperCore

/// What a chat's persona companion is doing (web lib/companion-store.ts): the character state its
/// working card publishes, and the reply it's revealing. One per chat, so the transcript row, the
/// docked companion and the pop-out all read the same reveal. Each row reads only the properties
/// it needs, so a reveal's tick redraws just the revealing row.
@Observable
@MainActor
final class ChatCompanion {
    var work: CharacterState? {
        didSet {
            // A stopped turn (static) or one waiting on the person isn't work done.
            if let work, work != .staticState, work != .needsYou { hadWork = true }
            if work == .staticState { hadWork = false }
        }
    }
    /// Playing the brief complete beat after a turn that did work delivered its reply.
    private(set) var complete = false
    private(set) var revealingId: String?
    private(set) var shown = ""
    /// The reply's voice is playing; it can outlast the text's reveal.
    private(set) var speaking = false

    @ObservationIgnored private var fullText = ""
    @ObservationIgnored private var wordsPerSecond = 0.0
    @ObservationIgnored private var started = Date()
    /// Words already revealed when the current pace began (the lead's, once the rest plays).
    @ObservationIgnored private var revealBase = 0
    /// While the lead plays and the rest may follow, the text stops at the lead's last word.
    @ObservationIgnored private var revealCap: Int?
    @ObservationIgnored private var revealed: Set<String> = []
    @ObservationIgnored private var seenFirstList = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var hadWork = false
    @ObservationIgnored private var celebrate = false
    @ObservationIgnored private var completeTask: Task<Void, Never>?
    /// Held at the start while the reply's speech loads, so text and voice begin together.
    @ObservationIgnored private var waitingForVoice = false
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playerEnd: VoicePlaybackEnd?
    @ObservationIgnored private var voiceTask: Task<Void, Never>?
    /// The rest of the reply's speech, voiced while the lead plays.
    @ObservationIgnored private var rest: RestClip = .none
    @ObservationIgnored private var leadDone = false

    private enum RestClip {
        case none
        case pending
        case ready(data: Data, words: Int)
    }
    /// The pop-out is open, for voices set to speak only there.
    @ObservationIgnored var popoutOpen = false
    /// Live Voice is open; it speaks "pop-out only" voices too.
    @ObservationIgnored var liveVoiceOpen = false

    /// How long a reveal waits for its speech before going ahead silently.
    static let voiceWait: Duration = .seconds(8)

    /// How long the complete beat plays: about one loop.
    static let completeDuration: Duration = .milliseconds(3500)

    /// Talking starts with the first word on screen, not when the reply arrives: a spoken reply
    /// holds its text while the voice loads, and even an instant pace shows nothing for a beat.
    var talking: Bool { revealingId != nil && !shown.isEmpty }

    /// Takes in the chat's messages: the first list a chat shows is history and never replays;
    /// a reply that arrives later is revealed at its author's pace.
    func observe(chatId: String?, messages: [API.ChatMessage], personas: [API.Persona], hostPersonaId: String?) {
        let replies = messages.filter { $0.role == .assistant }
        guard seenFirstList else {
            if !messages.isEmpty || !personas.isEmpty {
                seenFirstList = true
                revealed.formUnion(replies.map(\.id))
            }
            return
        }
        guard let last = replies.last else { return }
        revealed.formUnion(replies.dropLast().map(\.id))
        guard !revealed.contains(last.id), revealingId != last.id else { return }
        celebrate = hadWork
        hadWork = false
        let author = personas.first { $0.id == (last.persona?.id ?? hostPersonaId) }
        let wps = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0
            : PersonaStateLoops.revealWordsPerSecond(pace: author?.revealPace.rawValue, loops: author?.stateMedia?.loops)
        let mode = author?.voice.mode.rawValue ?? "off"
        let speaks = !PersonaVoiceMute.isMuted && (mode == "always" || (mode == "popout" && (popoutOpen || liveVoiceOpen)))
        guard wps > 0 || (speaks && chatId != nil) else {
            revealed.insert(last.id)
            startComplete()
            return
        }
        fullText = companionRevealText(last.bodyMd)
        wordsPerSecond = wps > 0 ? wps : 15
        started = Date()
        revealBase = 0
        shown = ""
        revealingId = last.id
        stopVoice()
        if speaks, let chatId {
            // The voice sets the pace: hold the text until it plays, then reveal in time with it.
            if liveVoiceOpen { LiveVoiceLatencyLog.shared.markReplyObserved(messageId: last.id) }
            waitingForVoice = true
            let messageId = last.id
            voiceTask = Task { [weak self] in await self?.playVoice(chatId: chatId, messageId: messageId) }
        }
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Shows the rest of the reply at once (a click on it, or the person sending).
    func finishReveal() {
        guard let id = revealingId else { return }
        if shown != fullText { stopVoice() } // skipped: a voice that finished on its own just ends
        revealed.insert(id)
        revealingId = nil
        shown = ""
        timer?.invalidate()
        timer = nil
        startComplete()
    }

    private func startComplete() {
        guard celebrate else { return }
        celebrate = false
        complete = true
        completeTask?.cancel()
        completeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.completeDuration)
            guard !Task.isCancelled else { return }
            self?.complete = false
        }
    }

    /// Speaks the reply in two parts voiced at once: the short lead plays as soon as it's ready
    /// while the rest is still being voiced, then the rest follows it.
    private func playVoice(chatId: String, messageId: String) async {
        let path = "/api/v1/chats/\(chatId)/messages/\(messageId)/speech"
        rest = .pending
        let restFetch = Task { await AvatarImages.shared.speech(for: path + "?part=rest") }
        let lead = await Self.speech(path + "?part=lead", within: Self.voiceWait)
        guard revealingId == messageId, !Task.isCancelled else {
            restFetch.cancel()
            return
        }
        waitingForVoice = false
        started = Date()
        // A voice that failed, timed out or was muted meanwhile leaves the persona's normal pace.
        if lead != nil, liveVoiceOpen { LiveVoiceLatencyLog.shared.markSpeechFirstAudio(part: "lead", streaming: false) }
        guard let lead, !PersonaVoiceMute.isMuted, play(lead, onEnd: { [weak self] in self?.leadEnded() }) else {
            restFetch.cancel()
            rest = .none
            return
        }
        if liveVoiceOpen { LiveVoiceLatencyLog.shared.markPlaybackStarted(part: "lead", streaming: false) }
        revealCap = lead.words
        let restClip = await withTaskCancellationHandler {
            await restFetch.value
        } onCancel: {
            restFetch.cancel()
        }
        guard !Task.isCancelled, case .pending = rest else { return }
        if let restClip {
            if leadDone { playRest(restClip) } else { rest = .ready(data: restClip.data, words: restClip.words) }
        } else {
            // Nothing after the lead (or its voice failed): the text carries on at the lead's pace.
            rest = .none
            releaseCap()
            if leadDone { speaking = false }
        }
    }

    /// Plays a clip and paces the text to it; false when it can't play.
    private func play(_ clip: (data: Data, words: Int), onEnd: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard let audio = try? AVAudioPlayer(data: clip.data), audio.duration > 0 else { return false }
        let id = ObjectIdentifier(audio)
        let end = VoicePlaybackEnd { [weak self] in
            guard let self, let player = self.player, ObjectIdentifier(player) == id else { return }
            self.player = nil
            self.playerEnd = nil
            onEnd()
        }
        audio.delegate = end
        guard audio.play() else { return false }
        player = audio
        playerEnd = end
        speaking = true
        if clip.words > 0 { wordsPerSecond = Double(clip.words) / audio.duration }
        return true
    }

    private func leadEnded() {
        leadDone = true
        switch rest {
        case let .ready(data, words): playRest((data, words))
        case .pending: break // the text holds at the lead's last word until the rest arrives
        case .none: speaking = false
        }
    }

    private func playRest(_ clip: (data: Data, words: Int)) {
        rest = .none
        releaseCap()
        if !play(clip, onEnd: { [weak self] in self?.speaking = false }) { speaking = false }
    }

    /// Lets the text run past the lead, carrying on from its last word if it was held there.
    private func releaseCap() {
        guard let cap = revealCap else { return }
        revealCap = nil
        if leadDone {
            revealBase = cap
            started = Date()
        }
    }

    private static func speech(_ path: String, within limit: Duration) async -> (data: Data, words: Int)? {
        await withTaskGroup(of: (data: Data, words: Int)?.self) { group in
            group.addTask { await AvatarImages.shared.speech(for: path) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Stops the reply being spoken (skipped, replaced or muted).
    func stopVoice() {
        voiceTask?.cancel()
        voiceTask = nil
        player?.stop()
        player = nil
        playerEnd = nil
        rest = .none
        leadDone = false
        revealCap = nil
        speaking = false
        waitingForVoice = false
    }

    private func tick() {
        if waitingForVoice { return }
        var words = revealBase + Int(Date().timeIntervalSince(started) * wordsPerSecond)
        if let cap = revealCap { words = min(words, cap) }
        let next = PersonaStateLoops.revealSlice(fullText, words: words)
        if next.done {
            shown = fullText // a natural end, so finishReveal lets the voice play out
            finishReveal()
        } else if next.text != shown {
            shown = next.text
        }
    }
}

/// Tells the companion when a reply's voice finishes on its own.
private final class VoicePlaybackEnd: NSObject, AVAudioPlayerDelegate, Sendable {
    private let onEnd: @MainActor @Sendable () -> Void

    init(_ onEnd: @escaping @MainActor @Sendable () -> Void) {
        self.onEnd = onEnd
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let onEnd = onEnd
        Task { @MainActor in onEnd() }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let onEnd = onEnd
        Task { @MainActor in onEnd() }
    }
}

/// One switch that silences every persona voice, remembered across launches.
@MainActor
enum PersonaVoiceMute {
    static let key = "vesper.companionMuted"
    static var isMuted: Bool { UserDefaults.standard.bool(forKey: key) }
    static func set(_ muted: Bool) {
        UserDefaults.standard.set(muted, forKey: key)
        if muted { ChatCompanions.stopAllVoices() }
    }
}

/// One `ChatCompanion` per chat for the life of the app.
@MainActor
enum ChatCompanions {
    static func stopAllVoices() {
        for c in byChat.values { c.stopVoice() }
    }

    private static var byChat: [String: ChatCompanion] = [:]
    static func companion(for chatId: String) -> ChatCompanion {
        if let hit = byChat[chatId] { return hit }
        let made = ChatCompanion()
        byChat[chatId] = made
        return made
    }
}

/// Personas whose companion the person tucked away, remembered across launches.
enum CompanionVisibility {
    static let key = "vesper.companionHidden"
    static func ids(_ raw: String) -> Set<String> { Set(raw.split(separator: ",").map(String.init)) }
    static func toggled(_ raw: String, _ id: String, hidden: Bool) -> String {
        var set = ids(raw)
        if hidden { set.insert(id) } else { set.remove(id) }
        return set.sorted().joined(separator: ",")
    }
}

/// The persona's loop standing bottom-right above the composer (web PersonaCompanion): idle when
/// nothing is happening, the turn's state while it works, talking while a reply reveals. A click
/// opens the pop-out; the hover ✕ tucks it away to a head chip.
struct PersonaCompanionDock: View {
    @Environment(\.vesperTheme) private var theme
    @AppStorage(CompanionVisibility.key) private var hiddenRaw = ""
    @AppStorage(PersonaVoiceMute.key) private var voiceMuted = false
    let companion: ChatCompanion
    let persona: API.Persona
    let loops: [String: String]
    let onOpen: () -> Void

    static let width: CGFloat = 140
    @State private var hovering = false
    @State private var head: NSImage?

    var body: some View {
        let hidden = CompanionVisibility.ids(hiddenRaw).contains(persona.id)
        let state = companion.work ?? .idle
        Group {
            if hidden {
                Button {
                    hiddenRaw = CompanionVisibility.toggled(hiddenRaw, persona.id, hidden: false)
                } label: {
                    ZStack {
                        Circle().fill(theme.palette.surface)
                        if let head { Image(nsImage: head).resizable().scaledToFill() } else { Text(String(persona.name.prefix(1))).font(.callout.weight(.semibold)) }
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(theme.palette.border))
                }
                .buttonStyle(.plain)
                .help("Show \(persona.name)")
                .task(id: persona.stateMedia?.headUrl) {
                    if let url = persona.stateMedia?.headUrl { head = await AvatarImages.shared.image(for: url) }
                }
            } else {
                ZStack(alignment: .topTrailing) {
                    Button(action: onOpen) {
                        PersonaStateStageView(loops: loops, state: state, talking: companion.talking, complete: companion.complete && companion.work == nil, width: Self.width, label: "\(persona.name), \(companion.talking ? "talking" : companion.complete && companion.work == nil ? "complete" : state.rawValue.replacingOccurrences(of: "_", with: " "))")
                    }
                    .buttonStyle(.plain)
                    .help("Talk with \(persona.name)")
                    if hovering || voiceMuted {
                        PersonaVoiceMuteButton(muted: $voiceMuted)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    if hovering {
                        Button {
                            hiddenRaw = CompanionVisibility.toggled(hiddenRaw, persona.id, hidden: true)
                        } label: {
                            Image(systemName: "xmark.circle.fill").imageScale(.medium).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Hide \(persona.name)")
                    }
                }
                .onHover { hovering = $0 }
            }
        }
        .padding(.trailing, 14)
        .padding(.bottom, 4)
    }
}

/// The companion large in the middle of the chat with the latest reply and a small composer
/// that sends like the main one (web CompanionPopOut).
struct PersonaCompanionPopOut: View {
    @Environment(\.vesperTheme) private var theme
    let companion: ChatCompanion
    let persona: API.Persona
    let loops: [String: String]
    let lastReply: API.ChatMessage?
    let onSend: (String) async -> String?
    let onClose: () -> Void

    @AppStorage(PersonaVoiceMute.key) private var voiceMuted = false
    @State private var text = ""
    @State private var error: String?
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        let p = theme.palette
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .onTapGesture(perform: onClose)
            HStack(alignment: .bottom, spacing: 24) {
                PersonaStateStageView(loops: loops, state: companion.work ?? .idle, talking: companion.talking, complete: companion.complete && companion.work == nil, width: 240, label: persona.name)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(persona.name).font(.headline).foregroundStyle(Color(cssHex: persona.color) ?? p.text)
                        Spacer()
                        PersonaVoiceMuteButton(muted: $voiceMuted)
                        Button(action: onClose) { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.cancelAction)
                            .help("Close")
                    }
                    if let lastReply {
                        ScrollView {
                            MarkdownView(
                                markdown: companion.revealingId == lastReply.id ? companion.shown : companionRevealText(lastReply.bodyMd),
                                textStyle: .chat,
                                chat: true
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .defaultScrollAnchor(.bottom)
                        .frame(maxHeight: 300)
                    }
                    TextEditor(text: $text)
                        .font(.body)
                        .focused($focused)
                        .frame(height: 72)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(p.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) { return .ignored }
                            send()
                            return .handled
                        }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Text("Return to send · Shift-Return for a new line · Esc to close")
                            .font(.caption)
                            .foregroundStyle(p.tertiaryText)
                        Spacer()
                        Button("Send", action: send)
                            .buttonStyle(.borderedProminent)
                            .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(16)
                .frame(width: 380)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(p.border))
            }
            .padding(24)
        }
        .onAppear {
            focused = true
            companion.popoutOpen = true // "pop-out only" voices speak while this is open
        }
        .onDisappear { companion.popoutOpen = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Talking with \(persona.name)")
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending else { return }
        sending = true
        companion.finishReveal()
        Task {
            defer { sending = false }
            if let problem = await onSend(body) {
                error = problem
            } else {
                text = ""
                error = nil
            }
        }
    }
}

/// The part of a reply that reveals: its prose without context markers or the closing source
/// list, which the transcript shows as chips.
@MainActor
func companionRevealText(_ bodyMd: String) -> String {
    ChatTranscriptLogic.splitSourceList(ChatTranscriptLogic.stripContext(bodyMd).typedBody).body
}

/// Mutes every persona voice; stops one speaking now.
struct PersonaVoiceMuteButton: View {
    @Binding var muted: Bool

    var body: some View {
        Button {
            muted.toggle()
            PersonaVoiceMute.set(muted)
        } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(muted ? "Unmute persona voices" : "Mute persona voices")
        .accessibilityLabel(muted ? "Unmute persona voices" : "Mute persona voices")
    }
}
