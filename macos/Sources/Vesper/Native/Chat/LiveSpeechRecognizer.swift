import AVFoundation
import Speech

/// The person's speech as text, for Live Voice: the microphone through `AVAudioEngine` into
/// `SFSpeechRecognizer`, on-device when the Mac supports the language, so speech stays local.
/// One recognition request per utterance; `stop()` closes the microphone between them.
@Observable
@MainActor
final class LiveSpeechRecognizer {
    enum Problem: Equatable {
        case microphoneDenied
        case speechDenied
        case unavailable
        case failed(String)

        var message: String {
            switch self {
            case .microphoneDenied: "Vesper can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
            case .speechDenied: "Vesper can't use speech recognition. Allow it in System Settings → Privacy & Security → Speech Recognition."
            case .unavailable: "Speech recognition isn't available for your language right now."
            case let .failed(reason): reason
            }
        }

        /// The Privacy & Security pane that fixes it, when there is one.
        var settingsURL: URL? {
            switch self {
            case .microphoneDenied: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .speechDenied: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            case .unavailable, .failed: nil
            }
        }
    }

    /// What the person has said in the current utterance so far.
    private(set) var transcript = ""
    /// Input loudness, 0…1, for the meter.
    private(set) var level: Float = 0
    private(set) var listening = false
    private(set) var problem: Problem?
    /// When the transcript last changed, for end-of-utterance.
    @ObservationIgnored private(set) var lastChange = Date()

    /// The recognizer ended an utterance by itself (its own time limit or a final result) with
    /// what was said; the microphone is already closed.
    @ObservationIgnored var onEnded: ((String) -> Void)?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Bumped on every start and stop so late callbacks from an earlier request are dropped.
    @ObservationIgnored private var generation = 0
    /// Errors in a row with nothing heard; past a few it's a real failure, not a restart.
    @ObservationIgnored private var failures = 0

    /// Asks for microphone and speech recognition access the first time; false (with `problem`
    /// set) when either is refused.
    func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                problem = .microphoneDenied
                return false
            }
        default:
            problem = .microphoneDenied
            return false
        }
        guard await Self.speechAuthorization() == .authorized else {
            problem = .speechDenied
            return false
        }
        return true
    }

    /// Opens the microphone for a new utterance.
    func start() {
        guard !listening else { return }
        guard let recognizer, recognizer.isAvailable else {
            problem = .unavailable
            return
        }
        generation += 1
        let gen = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        // Local recognition keeps speech on the Mac and has no one-minute limit.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            problem = .failed("No microphone is connected.")
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(feeding: request) { [weak self] level in
            Task { @MainActor in self?.heard(level: level, gen: gen) }
        })
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = .failed("The microphone didn't start: \(error.localizedDescription)")
            return
        }
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results { [weak self] update in
            Task { @MainActor in self?.received(update, gen: gen) }
        })
        transcript = ""
        lastChange = Date()
        problem = nil
        listening = true
    }

    /// Clears a failure so the microphone can be opened again.
    func clearProblem() {
        problem = nil
        failures = 0
    }

    /// Closes the microphone and returns what was said in this utterance.
    @discardableResult
    func stop() -> String {
        generation += 1
        // Touching inputNode creates the input unit, so leave it alone if it was never opened.
        if listening {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        listening = false
        level = 0
        let said = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        return said
    }

    private func heard(level: Float, gen: Int) {
        guard gen == generation else { return }
        // Rise at once, fall gently, so the meter doesn't flicker between syllables.
        self.level = max(level, self.level * 0.8)
    }

    private func received(_ update: RecognitionUpdate, gen: Int) {
        guard gen == generation, listening else { return }
        if let text = update.text, text != transcript {
            transcript = text
            lastChange = Date()
            failures = 0
        }
        guard update.isFinal || update.error != nil else { return }
        // The recognizer ended the request on its own: a final result, its time limit, nothing
        // heard for a long while, or an error.
        let said = stop()
        if !said.isEmpty {
            onEnded?(said)
            return
        }
        if let error = update.error, !update.noSpeech {
            failures += 1
            if failures >= 3 {
                failures = 0
                problem = .failed("Speech recognition stopped: \(error)")
                return
            }
        }
        start()
    }

    // MARK: - Off the main actor

    /// What a recognition callback carries, copied out of the non-Sendable result.
    struct RecognitionUpdate: Sendable {
        var text: String?
        var isFinal: Bool
        var error: String?
        /// "No speech detected": a long silence, not a failure.
        var noSpeech: Bool
    }

    /// The audio tap: feeds each buffer to the request and reports its loudness. Built off the
    /// main actor because the engine calls it on its realtime audio thread.
    private nonisolated static func tap(feeding request: SFSpeechAudioBufferRecognitionRequest, level: @escaping @Sendable (Float) -> Void) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        let request = UncheckedSendableBox(value: request)
        return { buffer, _ in
            request.value.append(buffer)
            level(loudness(buffer))
        }
    }

    /// The recognition handler, built off the main actor because Speech calls it on its own queue.
    private nonisolated static func results(_ deliver: @escaping @Sendable (RecognitionUpdate) -> Void) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let nsError = error as NSError?
            deliver(RecognitionUpdate(
                text: result?.bestTranscription.formattedString,
                isFinal: result?.isFinal ?? false,
                error: nsError?.localizedDescription,
                noSpeech: nsError?.domain == "kAFAssistantErrorDomain" && nsError?.code == 1110
            ))
        }
    }

    private nonisolated static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
    }

    /// RMS of the first channel mapped from about -50…0 dBFS to 0…1.
    private nonisolated static func loudness(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let rms = (sum / Float(n)).squareRoot()
        guard rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 50) / 50))
    }
}

/// Hands a value the API doesn't mark Sendable to a callback on another thread. Only for values
/// that are safe there: the speech request is documented to accept buffers from the audio thread.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}
