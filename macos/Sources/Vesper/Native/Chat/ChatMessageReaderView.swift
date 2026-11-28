import AVFoundation
import SwiftUI
import VesperCore

/// On-demand message Read Aloud controller for any assistant message in a chat.
/// Streams the persona's voice from `GET /api/v1/chats/:id/messages/:msgId/speech/stream`
/// through `StreamingPCMPlayer` (with pause/resume and pitch-preserved speed controls),
/// falling back cleanly to `AVSpeechSynthesizer` if the voice provider is unavailable.
@Observable
@MainActor
final class ChatMessageReader: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var activeChatId: String?
    private(set) var activeMessageId: String?
    private(set) var personaId: String?
    private(set) var speakerName = ""
    private(set) var snippet = ""
    private(set) var isLoading = false
    private(set) var isPlaying = false
    private(set) var isPaused = false
    private(set) var rate: ChatPlaybackRate = .x1
    private(set) var usingSystemVoice = false
    private(set) var notice: String?

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var pcmPlayer: StreamingPCMPlayer?
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    @ObservationIgnored private var currentPlainText = ""

    var isActive: Bool { activeMessageId != nil }

    func isReading(messageId: String) -> Bool {
        activeMessageId == messageId
    }

    func toggle(chatId: String, messageId: String, personaId: String?, speakerName: String, bodyMd: String) {
        if activeMessageId == messageId {
            stop()
            return
        }
        start(chatId: chatId, messageId: messageId, personaId: personaId, speakerName: speakerName, bodyMd: bodyMd)
    }

    func start(chatId: String, messageId: String, personaId: String?, speakerName: String, bodyMd: String) {
        stop()
        activeChatId = chatId
        activeMessageId = messageId
        self.personaId = personaId
        self.speakerName = speakerName
        snippet = ChatReadAloudLogic.snippet(from: bodyMd)
        currentPlainText = SystemVoiceText.plain(bodyMd).trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true
        isPlaying = false
        isPaused = false
        usingSystemVoice = false
        notice = nil

        let path = "/api/v1/chats/\(chatId)/messages/\(messageId)/speech/stream"
        streamTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await AvatarImages.shared.speechStream(for: path)
            guard !Task.isCancelled, self.activeMessageId == messageId else {
                if case .stream(let s) = outcome { s.cancel() }
                return
            }
            switch outcome {
            case .stream(let stream):
                await self.playPCMStream(stream, messageId: messageId)
            case .limited(let msg):
                self.notice = msg
                self.playSystemVoice(messageId: messageId)
            case .unavailable:
                self.playSystemVoice(messageId: messageId)
            }
        }
    }

    func togglePause() {
        guard isActive else { return }
        if let pcmPlayer {
            if pcmPlayer.isPaused {
                pcmPlayer.resume()
                isPaused = false
            } else {
                pcmPlayer.pause()
                isPaused = true
            }
        } else if let synthesizer {
            if isPaused {
                synthesizer.continueSpeaking()
                isPaused = false
            } else {
                synthesizer.pauseSpeaking(at: .word)
                isPaused = true
            }
        }
    }

    func cycleRate() {
        rate = rate.next()
        pcmPlayer?.setRate(rate.floatValue)
        // AVSpeechSynthesizer applies rate per utterance; restart system voice cleanly if active.
        if usingSystemVoice, let msgId = activeMessageId, !isPaused {
            synthesizer?.stopSpeaking(at: .immediate)
            playSystemVoice(messageId: msgId)
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        pcmPlayer?.stop()
        pcmPlayer = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer?.delegate = nil
        synthesizer = nil
        activeChatId = nil
        activeMessageId = nil
        personaId = nil
        speakerName = ""
        snippet = ""
        currentPlainText = ""
        isLoading = false
        isPlaying = false
        isPaused = false
        usingSystemVoice = false
        notice = nil
    }

    private func playPCMStream(_ stream: AvatarImages.SpeechStream, messageId: String) async {
        guard let player = StreamingPCMPlayer(
            sampleRate: stream.sampleRate,
            rate: rate.floatValue,
            onStarted: { [weak self] in
                guard let self, self.activeMessageId == messageId else { return }
                self.isLoading = false
                self.isPlaying = true
                self.isPaused = false
            },
            onEnd: { [weak self] in
                guard let self, self.activeMessageId == messageId else { return }
                self.stop()
            }
        ) else {
            stream.cancel()
            playSystemVoice(messageId: messageId)
            return
        }
        pcmPlayer = player

        var sawFirst = false
        for await chunk in stream.chunks {
            if Task.isCancelled || activeMessageId != messageId {
                stream.cancel()
                player.stop()
                if pcmPlayer === player { pcmPlayer = nil }
                return
            }
            sawFirst = true
            if !player.append(chunk) {
                stream.cancel()
                if pcmPlayer === player { pcmPlayer = nil }
                playSystemVoice(messageId: messageId)
                return
            }
        }
        player.finishInput()
        if !sawFirst || !player.hasStarted {
            playSystemVoice(messageId: messageId)
        }
    }

    private func playSystemVoice(messageId: String) {
        guard activeMessageId == messageId else { return }
        guard !currentPlainText.isEmpty else {
            stop()
            return
        }
        usingSystemVoice = true
        isLoading = false
        isPlaying = true
        isPaused = false
        let synth = AVSpeechSynthesizer()
        synth.delegate = self
        synthesizer = synth
        let utterance = AVSpeechUtterance(string: currentPlainText)
        // Map 1x..2x cleanly onto AVSpeechUtterance rate range around default.
        let base = AVSpeechUtteranceDefaultSpeechRate
        let maxR = AVSpeechUtteranceMaximumSpeechRate
        let scaled = base + (maxR - base) * Float((rate.rawValue - 1.0) * 0.55)
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(maxR, scaled))
        synth.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finishedID = ObjectIdentifier(synthesizer)
        Task { @MainActor [weak self] in
            guard let self, let current = self.synthesizer, ObjectIdentifier(current) == finishedID else { return }
            self.stop()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Explicit stop/rate-change handles state.
    }
}

/// Compact floating mini playback bar shown while Read Aloud is playing a message.
struct ChatReadAloudMiniBarView: View {
    @Environment(\.vesperTheme) private var theme

    let reader: ChatMessageReader
    let onJumpToMessage: @MainActor (String) -> Void

    var body: some View {
        let p = theme.palette
        HStack(spacing: 10) {
            WorkPersonaAvatarView(
                id: reader.personaId,
                handle: nil,
                name: reader.speakerName,
                size: 20,
                active: reader.isPlaying && !reader.isPaused
            )

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(reader.speakerName)
                        .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                        .foregroundStyle(p.text)
                    if reader.isLoading {
                        Text("Loading voice…")
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(p.tertiaryText)
                    } else if reader.usingSystemVoice {
                        Text("System voice")
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(p.tertiaryText)
                    }
                }
                Text(reader.snippet)
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                reader.togglePause()
            } label: {
                Image(systemName: reader.isPaused ? "play.fill" : "pause.fill")
                    .imageScale(.small)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(p.text)
            .disabled(reader.isLoading)
            .help(reader.isPaused ? "Resume" : "Pause")

            Button {
                reader.cycleRate()
            } label: {
                Text(reader.rate.label)
                    .font(.system(size: theme.pointSize(.micro), weight: .semibold, design: .monospaced))
                    .foregroundStyle(p.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(p.selected, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Change playback speed")

            if let msgId = reader.activeMessageId {
                Button {
                    onJumpToMessage(msgId)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .imageScale(.small)
                        .foregroundStyle(p.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Jump to message")
            }

            Button {
                reader.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Stop reading aloud")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .background(p.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.accent.opacity(0.35)))
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }
}
