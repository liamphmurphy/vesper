import AVFoundation
import Speech
import SwiftUI
import VesperCore

// MARK: - On-Demand Message Read Aloud (Server WAV TTS with AVSpeechSynthesizer Fallback)

@Observable
@MainActor
final class IOSChatVoiceReader: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private(set) var activeMessageId: String?
    private(set) var speakerName = ""
    private(set) var snippet = ""
    private(set) var isLoading = false
    private(set) var isPlaying = false
    private(set) var isPaused = false
    private(set) var rate: ChatPlaybackRate = .x1
    private(set) var usingSystemVoice = false

    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var synthesizer: AVSpeechSynthesizer?
    @ObservationIgnored private var currentPlainText = ""

    var isActive: Bool { activeMessageId != nil }

    func isReading(messageId: String) -> Bool {
        activeMessageId == messageId
    }

    func toggle(
        chatId: String,
        messageId: String,
        speakerName: String,
        bodyMd: String,
        client: APIClient?
    ) {
        if activeMessageId == messageId {
            stop()
            return
        }
        start(chatId: chatId, messageId: messageId, speakerName: speakerName, bodyMd: bodyMd, client: client)
    }

    func start(
        chatId: String,
        messageId: String,
        speakerName: String,
        bodyMd: String,
        client: APIClient?
    ) {
        stop()
        activeMessageId = messageId
        self.speakerName = speakerName
        snippet = ChatReadAloudLogic.snippet(from: bodyMd, maxLength: 60)
        currentPlainText = SystemVoiceText.plain(bodyMd).trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true
        isPlaying = false
        isPaused = false
        usingSystemVoice = false

        guard let client else {
            playSystemVoice(messageId: messageId)
            return
        }

        let path = "/api/v1/chats/\(chatId)/messages/\(messageId)/speech"
        fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await client.request(
                    "GET",
                    path,
                    headers: ["Accept": "audio/wav"],
                    timeout: 90
                )
                guard !Task.isCancelled, self.activeMessageId == messageId else { return }
                self.playWAV(data, messageId: messageId)
            } catch {
                guard !Task.isCancelled, self.activeMessageId == messageId else { return }
                self.playSystemVoice(messageId: messageId)
            }
        }
    }

    func togglePause() {
        guard isActive else { return }
        if let player = audioPlayer {
            if isPaused {
                player.play()
                isPaused = false
            } else {
                player.pause()
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
        if let player = audioPlayer {
            player.rate = rate.floatValue
        } else if usingSystemVoice, let msgId = activeMessageId, !isPaused {
            synthesizer?.stopSpeaking(at: .immediate)
            playSystemVoice(messageId: msgId)
        }
    }

    func stop() {
        fetchTask?.cancel()
        fetchTask = nil
        audioPlayer?.stop()
        audioPlayer?.delegate = nil
        audioPlayer = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer?.delegate = nil
        synthesizer = nil
        activeMessageId = nil
        speakerName = ""
        snippet = ""
        currentPlainText = ""
        isLoading = false
        isPlaying = false
        isPaused = false
        usingSystemVoice = false
    }

    private func playWAV(_ data: Data, messageId: String) {
        guard activeMessageId == messageId else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.enableRate = true
            player.rate = rate.floatValue
            player.prepareToPlay()
            guard player.play() else {
                playSystemVoice(messageId: messageId)
                return
            }
            audioPlayer = player
            isLoading = false
            isPlaying = true
            isPaused = false
            usingSystemVoice = false
        } catch {
            playSystemVoice(messageId: messageId)
        }
    }

    private func playSystemVoice(messageId: String) {
        guard activeMessageId == messageId else { return }
        guard !currentPlainText.isEmpty else {
            stop()
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        usingSystemVoice = true
        isLoading = false
        isPlaying = true
        isPaused = false
        let synth = AVSpeechSynthesizer()
        synth.delegate = self
        synthesizer = synth
        let utterance = AVSpeechUtterance(string: currentPlainText)
        let base = AVSpeechUtteranceDefaultSpeechRate
        let maxR = AVSpeechUtteranceMaximumSpeechRate
        let scaled = base + (maxR - base) * Float((rate.rawValue - 1.0) * 0.55)
        utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(maxR, scaled))
        synth.speak(utterance)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finishedID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.audioPlayer, ObjectIdentifier(current) == finishedID else { return }
            self.stop()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finishedID = ObjectIdentifier(synthesizer)
        Task { @MainActor [weak self] in
            guard let self, let current = self.synthesizer, ObjectIdentifier(current) == finishedID else { return }
            self.stop()
        }
    }
}

// MARK: - Floating Mini Read-Aloud Bar (iOS)

struct IOSReadAloudMiniBarView: View {
    let reader: IOSChatVoiceReader
    let onJumpToMessage: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: reader.isPlaying && !reader.isPaused ? "waveform" : "speaker.wave.2")
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(reader.speakerName)
                        .font(.caption.weight(.semibold))
                    if reader.isLoading {
                        Text("Loading voice…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if reader.usingSystemVoice {
                        Text("System voice")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(reader.snippet)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                reader.togglePause()
            } label: {
                Image(systemName: reader.isPaused ? "play.fill" : "pause.fill")
                    .font(.subheadline)
            }
            .disabled(reader.isLoading)

            Button {
                reader.cycleRate()
            } label: {
                Text(reader.rate.label)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }

            if let msgId = reader.activeMessageId {
                Button {
                    onJumpToMessage(msgId)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                reader.stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Live Speech-to-Text Dictation (iOS SFSpeechRecognizer)

@Observable
@MainActor
final class IOSDictationController {
    private(set) var isListening = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var basePrefix = ""

    func toggle(currentDraft: String, onUpdate: @escaping @MainActor (String) -> Void) {
        if isListening {
            stop()
            return
        }
        Task {
            await start(currentDraft: currentDraft, onUpdate: onUpdate)
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
    }

    private func start(currentDraft: String, onUpdate: @escaping @MainActor (String) -> Void) async {
        errorMessage = nil
        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            errorMessage = "Allow Speech Recognition in iOS Settings to dictate messages."
            return
        }

        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            errorMessage = "Allow Microphone access in iOS Settings to dictate messages."
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now."
            return
        }

        stop()
        basePrefix = currentDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let errDesc = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let text, !text.isEmpty {
                        let combined = self.basePrefix.isEmpty ? text : "\(self.basePrefix) \(text)"
                        onUpdate(combined)
                    }
                    if isFinal || errDesc != nil {
                        self.stop()
                    }
                }
            }
        } catch {
            stop()
            errorMessage = error.localizedDescription
        }
    }
}
