import AppKit
import os
import SwiftUI
import VesperCore

/// Logs per-stage latency for Live Voice turns (utterance end -> settle -> send -> reply ->
/// first audio -> playback) to the unified macOS log (`com.vesper.app`, category `LiveVoice`).
@MainActor
final class LiveVoiceLatencyLog {
    static let shared = LiveVoiceLatencyLog()
    private let logger = Logger(subsystem: "com.vesper.app", category: "LiveVoice")

    private var utteranceEndedAt: Date?
    private var sentAt: Date?
    private var replyObservedAt: Date?
    private var sawTurnRunning = false

    func markUtteranceEnd(settled: Bool) {
        utteranceEndedAt = Date()
        sentAt = nil
        replyObservedAt = nil
        sawTurnRunning = false
        emit("utterance_end settled=\(settled)")
    }

    func markSettled() {
        emit("settled settle_ms=\(msSince(utteranceEndedAt))")
    }

    func markSent() {
        let now = Date()
        sentAt = now
        emit("sent since_end_ms=\(msSince(utteranceEndedAt))")
    }

    func markTurnRunning() {
        guard !sawTurnRunning, utteranceEndedAt != nil else { return }
        sawTurnRunning = true
        emit("turn_running since_send_ms=\(msSince(sentAt)) since_end_ms=\(msSince(utteranceEndedAt))")
    }

    func markReplyObserved(messageId: String) {
        guard utteranceEndedAt != nil else { return }
        replyObservedAt = Date()
        emit("reply_observed msg=\(messageId) since_send_ms=\(msSince(sentAt)) since_end_ms=\(msSince(utteranceEndedAt))")
    }

    func markSpeechFirstAudio(part: String, streaming: Bool) {
        guard utteranceEndedAt != nil else { return }
        emit("speech_first_audio part=\(part) streaming=\(streaming) tts_ms=\(msSince(replyObservedAt)) total_ms=\(msSince(utteranceEndedAt))")
    }

    func markPlaybackStarted(part: String, streaming: Bool) {
        guard utteranceEndedAt != nil else { return }
        emit("playback_started part=\(part) streaming=\(streaming) tts_ms=\(msSince(replyObservedAt)) total_ms=\(msSince(utteranceEndedAt))")
        if part == "lead" || part == "full" {
            utteranceEndedAt = nil
        }
    }

    func reset() {
        utteranceEndedAt = nil
        sentAt = nil
        replyObservedAt = nil
        sawTurnRunning = false
    }

    private func msSince(_ start: Date?) -> Int {
        guard let start else { return -1 }
        return max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private func emit(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        vlog("live_voice \(message)")
    }
}

/// Drives a Live Voice conversation: listens, sends what the person said once they pause, closes
/// the microphone while the persona works and answers, and listens again when it's done
/// (`LiveVoiceTurn`). The answer reveals and speaks through the chat's `ChatCompanion`.
@Observable
@MainActor
final class LiveVoiceSession {
    let speech = LiveSpeechRecognizer()
    private(set) var turn = LiveVoiceTurn()
    /// The person paused the microphone.
    private(set) var micPaused = false
    /// What the person said last, shown while the persona answers.
    private(set) var lastSaid = ""
    private(set) var sendError: String?
    /// Microphone and speech access were granted.
    private(set) var ready = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var reopenTask: Task<Void, Never>?
    @ObservationIgnored private var coolingDown = false
    /// Live Voice closed, possibly while access was still being asked for.
    @ObservationIgnored private var ended = false
    @ObservationIgnored private var send: ((String) async -> String?)?
    @ObservationIgnored private var chat = ChatProgress(turnRunning: false, lastReplyId: nil, revealing: false, speaking: false)

    /// The chat as Live Voice follows it.
    struct ChatProgress: Equatable {
        var turnRunning: Bool
        var lastReplyId: String?
        var revealing: Bool
        var speaking: Bool
    }

    func begin(send: @escaping (String) async -> String?) async {
        self.send = send
        guard await speech.prepare(), !ended else { return }
        ready = true
        // If the persona is still answering when Live Voice opens, wait for it like any answer.
        if chat.turnRunning || chat.revealing || chat.speaking {
            turn.send(lastReplyId: chat.lastReplyId)
            turn.sent()
            turn.update(turnRunning: chat.turnRunning, lastReplyId: chat.lastReplyId, revealing: chat.revealing, speaking: chat.speaking)
        }
        syncMicrophone()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForPause() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func end() {
        ended = true
        reopenTask?.cancel()
        reopenTask = nil
        coolingDown = false
        timer?.invalidate()
        timer = nil
        speech.stop()
        ready = false
        LiveVoiceLatencyLog.shared.reset()
    }

    func follow(_ progress: ChatProgress) {
        chat = progress
        if progress.turnRunning { LiveVoiceLatencyLog.shared.markTurnRunning() }
        let prevPhase = turn.phase
        turn.update(turnRunning: progress.turnRunning, lastReplyId: progress.lastReplyId, revealing: progress.revealing, speaking: progress.speaking)
        scheduleReopenIfNeeded(from: prevPhase)
        syncMicrophone()
    }

    func toggleMicrophone() {
        micPaused.toggle()
        syncMicrophone()
    }

    /// Sends what's been said without waiting for the pause.
    func sendNow() {
        guard !speech.transcript.isEmpty else { return }
        endUtterance()
    }

    /// Cuts the persona's answer short and listens again.
    func interrupt(_ companion: ChatCompanion) {
        guard turn.phase == .replying else { return }
        reopenTask?.cancel()
        reopenTask = nil
        coolingDown = false
        companion.finishReveal()
        companion.stopVoice()
        turn.interrupt()
        syncMicrophone()
    }

    /// Tries the microphone again after a recognition failure.
    func retry() {
        speech.clearProblem()
        Task {
            guard await speech.prepare(), !ended else { return }
            ready = true
            syncMicrophone()
        }
    }

    private func checkForPause() {
        guard LiveVoiceTurn.utteranceEnded(transcript: speech.transcript, lastChange: speech.lastChange, now: Date(), settled: speech.settled) else { return }
        endUtterance()
    }

    /// Closes the microphone, waits for the transcriber's final text and sends it.
    private func endUtterance() {
        guard turn.phase == .listening, speech.listening, send != nil else { return }
        LiveVoiceLatencyLog.shared.markUtteranceEnd(settled: speech.settled)
        lastSaid = speech.transcript
        sendError = nil
        reopenTask?.cancel()
        reopenTask = nil
        coolingDown = false
        turn.send(lastReplyId: chat.lastReplyId)
        let settling = speech.finish()
        Task {
            let said = await settling.value
            guard !said.isEmpty, !ended else {
                LiveVoiceLatencyLog.shared.reset()
                turn.sendFailed()
                syncMicrophone()
                return
            }
            LiveVoiceLatencyLog.shared.markSettled()
            lastSaid = said
            let problem: String? = await self.send?(said) ?? nil
            if let problem {
                LiveVoiceLatencyLog.shared.reset()
                sendError = problem
                turn.sendFailed()
            } else {
                LiveVoiceLatencyLog.shared.markSent()
                turn.sent()
                // The chat may already have moved on while the send was in flight.
                let prevPhase = turn.phase
                turn.update(turnRunning: chat.turnRunning, lastReplyId: chat.lastReplyId, revealing: chat.revealing, speaking: chat.speaking)
                scheduleReopenIfNeeded(from: prevPhase)
            }
            syncMicrophone()
        }
    }

    private func scheduleReopenIfNeeded(from prevPhase: LiveVoiceTurn.Phase) {
        if turn.phase != .listening || chat.speaking || chat.revealing {
            reopenTask?.cancel()
            reopenTask = nil
            coolingDown = false
            return
        }
        guard prevPhase != .listening, turn.resumeCooldown > 0 else { return }
        reopenTask?.cancel()
        coolingDown = true
        let delay = turn.resumeCooldown
        reopenTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.ended else { return }
            self.coolingDown = false
            self.reopenTask = nil
            self.syncMicrophone()
        }
    }

    /// The microphone is open exactly while it's the person's turn and the persona isn't speaking.
    private func syncMicrophone() {
        let open = ready && !micPaused && turn.phase == .listening && !coolingDown && !chat.speaking && !chat.revealing && speech.problem == nil
        if open && !speech.listening {
            speech.start()
        } else if !open && speech.listening {
            speech.stop()
        }
    }
}

/// Live Voice (like ChatGPT or Gemini voice): the persona takes over the chat, large and centred,
/// while the person talks with it out loud. A persona with state loops plays them, talking while
/// it answers; one without stands in as its avatar with a ring that follows the microphone.
struct LiveVoiceView: View {
    @Environment(\.vesperTheme) private var theme
    @AppStorage(PersonaVoiceMute.key) private var voiceMuted = false
    let companion: ChatCompanion
    let persona: API.Persona?
    let lastReply: API.ChatMessage?
    let turnRunning: Bool
    let syncCompanion: () -> Void
    let onSend: (String) async -> String?
    let onClose: () -> Void

    @State private var session = LiveVoiceSession()
    /// The companion told Live Voice is open, so "pop-out only" voices speak.
    @State private var speakingCompanion: ChatCompanion?

    private static let topBarHeight: CGFloat = 52
    private static let captionHeight: CGFloat = 120
    private static let controlsHeight: CGFloat = 96

    var body: some View {
        let p = theme.palette
        let tint = Color(cssHex: persona?.color) ?? p.accent
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(.ultraThickMaterial)
                LinearGradient(colors: [tint.opacity(0.0), tint.opacity(0.18)], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 0) {
                    topBar
                        .frame(height: Self.topBarHeight)
                    stage(available: CGSize(width: geo.size.width, height: geo.size.height - Self.topBarHeight - Self.captionHeight - Self.controlsHeight))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    captions
                        .frame(maxWidth: 680)
                        .frame(height: Self.captionHeight)
                        .padding(.horizontal, 24)
                    controls
                        .frame(height: Self.controlsHeight)
                }
            }
        }
        .ignoresSafeArea()
        .task {
            // Keystrokes shouldn't land in the composer hidden underneath.
            NSApp.keyWindow?.makeFirstResponder(nil)
            syncCompanion()
            session.follow(progress)
            await session.begin(send: onSend)
        }
        // A new chat's first message moves Live Voice to the chat it created, with its own companion.
        .onChange(of: ObjectIdentifier(companion), initial: true) { _, _ in
            speakingCompanion?.liveVoiceOpen = false
            companion.liveVoiceOpen = true
            speakingCompanion = companion
        }
        .onDisappear {
            session.end()
            speakingCompanion?.liveVoiceOpen = false
            speakingCompanion = nil
        }
        .onChange(of: lastReply?.id) { _, _ in
            syncCompanion()
            session.follow(progress)
        }
        .onChange(of: progress) { _, _ in
            syncCompanion()
            session.follow(progress)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live Voice with \(persona?.name ?? "your assistant")")
    }

    private var progress: LiveVoiceSession.ChatProgress {
        .init(turnRunning: turnRunning, lastReplyId: lastReply?.id, revealing: companion.revealingId != nil, speaking: companion.speaking)
    }

    // MARK: - Parts

    private var topBar: some View {
        let p = theme.palette
        return HStack(spacing: 12) {
            Label("Live Voice", systemImage: "waveform")
                .font(.callout.weight(.semibold))
                .foregroundStyle(p.secondaryText)
            Spacer()
            statusChip
            Spacer()
            PersonaVoiceMuteButton(muted: $voiceMuted)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(p.secondaryText)
            .keyboardShortcut(.cancelAction)
            .help("End Live Voice (Esc)")
        }
        .padding(.horizontal, 20)
    }

    private var statusChip: some View {
        let p = theme.palette
        return HStack(spacing: 8) {
            if session.speech.listening {
                LevelMeter(level: session.speech.level, color: p.accent)
            }
            Text(statusText)
                .font(.callout)
                .foregroundStyle(p.text)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(p.surface.opacity(0.7), in: Capsule())
        .overlay(Capsule().stroke(p.border))
        .animation(.easeOut(duration: 0.15), value: statusText)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if session.speech.problem != nil { return "Microphone unavailable" }
        if session.speech.downloadingModel { return "Downloading the speech model…" }
        if !session.ready { return "Starting…" }
        let name = persona?.name ?? "Assistant"
        switch session.turn.phase {
        case .listening: return session.micPaused ? "Microphone paused" : "Listening"
        case .sending: return "Sending…"
        case .waiting:
            switch companion.work {
            case .reading?: return "\(name) is reading"
            case .coding?, .working?: return "\(name) is working"
            case .creating?: return "\(name) is creating"
            case .needsYou?: return "\(name) needs you in the chat"
            default: return "\(name) is thinking"
            }
        case .replying: return "\(name) is speaking · click to interrupt"
        }
    }

    @ViewBuilder
    private func stage(available: CGSize) -> some View {
        let state = companion.work ?? .idle
        let talking = companion.talking || companion.speaking
        let complete = companion.complete && companion.work == nil
        Group {
            if let persona, let loops = persona.playableLoops {
                // As tall as the space allows at the loops' 9:16, but never wider than most of it.
                // Snapped to 40pt steps: each new size decodes the loop again, so a window resize
                // shouldn't decode on every pixel.
                let fit = min(available.width * 0.7, max(0, available.height) * 9 / 16)
                let width = max(120, (fit / 40).rounded(.down) * 40)
                PersonaStateStageView(loops: loops, state: state, talking: talking, complete: complete, width: width, label: persona.name)
            } else {
                AvatarStage(persona: persona, state: state, talking: talking, listening: session.speech.listening, level: session.speech.level, size: max(120, min(available.width, available.height) * 0.5))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if session.turn.phase == .replying {
                session.interrupt(companion)
            } else {
                session.sendNow()
            }
        }
        .help(session.turn.phase == .replying ? "Interrupt" : "Send what you've said now")
    }

    @ViewBuilder
    private var captions: some View {
        let p = theme.palette
        VStack(spacing: 8) {
            if let problem = session.speech.problem {
                Text(problem.message)
                    .font(.callout)
                    .foregroundStyle(p.text)
                    .multilineTextAlignment(.center)
                HStack {
                    if let url = problem.settingsURL {
                        Button("Open System Settings") { NSWorkspace.shared.open(url) }
                    }
                    Button("Try Again") { session.retry() }
                }
            } else if let sendError = session.sendError {
                Text(sendError).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            } else {
                switch session.turn.phase {
                case .listening:
                    let said = session.speech.transcript
                    if said.isEmpty {
                        caption(AttributedString(session.micPaused ? "Unpause the microphone to talk." : "\(persona?.name ?? "Your assistant") is listening. Go ahead."), color: p.tertiaryText)
                    } else {
                        caption(AttributedString(said), color: p.text)
                    }
                case .sending, .waiting:
                    caption(AttributedString(session.lastSaid), color: p.secondaryText)
                case .replying:
                    caption(replyCaption, color: p.text)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: session.turn.phase)
    }

    /// Large centred text that keeps its newest line in view as it grows.
    private func caption(_ text: AttributedString, color: Color) -> some View {
        ScrollView {
            Text(text)
                .font(.title3)
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.never)
    }

    /// The answer as it reveals, with inline Markdown kept and block syntax left as text.
    private var replyCaption: AttributedString {
        guard let lastReply else { return AttributedString() }
        let text = companion.revealingId == lastReply.id ? companion.shown : companionRevealText(lastReply.bodyMd)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private var controls: some View {
        let p = theme.palette
        return HStack(spacing: 28) {
            Button(action: session.toggleMicrophone) {
                Image(systemName: session.micPaused ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 56, height: 56)
                    .background(session.micPaused ? p.selected : p.surface, in: Circle())
                    .overlay(Circle().stroke(p.border))
            }
            .buttonStyle(.plain)
            .foregroundStyle(session.micPaused ? p.accent : p.text)
            .help(session.micPaused ? "Unpause the microphone" : "Pause the microphone")
            .accessibilityLabel(session.micPaused ? "Unpause microphone" : "Pause microphone")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(Color.red, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("End Live Voice")
            .accessibilityLabel("End Live Voice")
        }
    }
}

/// A persona without state loops: its avatar, large, with a ring that swells with the person's
/// voice while listening and pulses while it talks.
private struct AvatarStage: View {
    let persona: API.Persona?
    let state: CharacterState
    let talking: Bool
    let listening: Bool
    let level: Float
    let size: CGFloat

    @Environment(\.vesperTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let tint = Color(cssHex: persona?.color) ?? theme.palette.accent
        let swell = listening ? CGFloat(level) * 0.18 : (talking && pulse ? 0.08 : 0)
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
                .scaleEffect(1.12 + (reduceMotion ? 0 : swell))
            WorkPersonaAvatarView(id: persona?.id, handle: persona?.handle, name: persona?.name ?? "Assistant", size: size, state: state, active: talking, preferCharacter: true)
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .animation(.easeOut(duration: 0.12), value: level)
        .animation(talking && !reduceMotion ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default, value: pulse)
        .onChange(of: talking, initial: true) { _, now in pulse = now }
        .accessibilityLabel(persona?.name ?? "Assistant")
    }
}

/// Five bars that follow the microphone's level.
private struct LevelMeter: View {
    let level: Float
    let color: Color

    private static let weights: [CGFloat] = [0.5, 0.8, 1, 0.8, 0.5]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.weights.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 4 + 12 * CGFloat(level) * Self.weights[i])
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}
