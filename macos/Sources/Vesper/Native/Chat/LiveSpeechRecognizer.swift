import AVFoundation
import Speech

/// The person's speech as text, for Live Voice and composer dictation: the microphone through
/// `AVAudioEngine` into a `SpeechAnalyzer` running Apple's on-device `SpeechTranscriber` model, so
/// speech never leaves the Mac. One analyzer per utterance; between utterances the microphone is
/// closed.
@Observable
@MainActor
final class LiveSpeechRecognizer {
    enum Problem: Equatable {
        case microphoneDenied
        case unavailable
        case failed(String)

        var message: String {
            switch self {
            case .microphoneDenied: "Vesper can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
            case .unavailable: "On-device speech recognition isn't available for your language on this Mac."
            case let .failed(reason): reason
            }
        }

        /// The Privacy & Security pane that fixes it, when there is one.
        var settingsURL: URL? {
            switch self {
            case .microphoneDenied: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .unavailable, .failed: nil
            }
        }
    }

    /// What the person has said in the current utterance so far: the transcriber's final text
    /// followed by its volatile guess at the latest words.
    private(set) var transcript = ""
    /// Input loudness, 0…1, for the meter.
    private(set) var level: Float = 0
    private(set) var listening = false
    /// The language's speech model is downloading (first use only).
    private(set) var downloadingModel = false
    private(set) var problem: Problem?
    /// When the transcript last changed, for end-of-utterance.
    @ObservationIgnored private(set) var lastChange = Date()
    /// Everything heard so far is final: no volatile guess is still pending.
    @ObservationIgnored private(set) var settled = true

    @ObservationIgnored private let engine = AVAudioEngine()
    /// The transcriber's language for the person's locale, set by `prepare()`.
    @ObservationIgnored private var locale: Locale?
    /// The audio format the analyzer wants; the microphone is converted to it.
    @ObservationIgnored private var analyzerFormat: AVAudioFormat?
    @ObservationIgnored private var utterance: Utterance?
    /// Bumped whenever an utterance ends so late results from it are dropped.
    @ObservationIgnored private var generation = 0

    /// The pieces of one utterance's analysis.
    private struct Utterance {
        let analyzer: SpeechAnalyzer
        let input: AsyncStream<AnalyzerInput>.Continuation
        /// Collects results; its value is the utterance's text once the analyzer finishes.
        let results: Task<String, Never>
    }

    /// Asks for the microphone the first time, checks the language is supported on device, and
    /// downloads its model if the Mac doesn't have it yet. False (with `problem` set) when any of
    /// that fails.
    func prepare() async -> Bool {
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
        guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            problem = .unavailable
            return false
        }
        let transcriber = Self.transcriber(locale)
        do {
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                downloadingModel = true
                defer { downloadingModel = false }
                try await install.downloadAndInstall()
            }
        } catch {
            problem = .failed("The speech model didn't download: \(error.localizedDescription)")
            return false
        }
        let natural = engine.inputNode.outputFormat(forBus: 0)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural) else {
            problem = .unavailable
            return false
        }
        self.locale = locale
        analyzerFormat = format
        return true
    }

    /// Clears a failure so the microphone can be opened again.
    func clearProblem() {
        problem = nil
    }

    /// Opens the microphone for a new utterance. Audio is queued from the first buffer, so
    /// nothing said while the analyzer starts is lost.
    func start() {
        guard !listening, let locale, let analyzerFormat else { return }
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            problem = .failed("No microphone is connected.")
            return
        }
        let converter: AVAudioConverter?
        if micFormat == analyzerFormat {
            converter = nil
        } else if let made = AVAudioConverter(from: micFormat, to: analyzerFormat) {
            converter = made
        } else {
            problem = .failed("The microphone's audio format isn't supported.")
            return
        }

        generation += 1
        let gen = generation
        let transcriber = Self.transcriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat, block: Self.tap(converter: converter, to: analyzerFormat, feed: feed) { [weak self] level in
            Task { @MainActor in self?.heard(level: level, gen: gen) }
        })
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            feed.finish()
            problem = .failed("The microphone didn't start: \(error.localizedDescription)")
            return
        }

        let results = Task { [weak self] () -> String in
            var finalized = ""
            var volatile = ""
            do {
                try await analyzer.start(inputSequence: stream)
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    self?.heard(transcript: finalized + volatile, settled: volatile.isEmpty, gen: gen)
                }
            } catch is CancellationError {
            } catch {
                self?.failed(error, gen: gen)
            }
            return (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        utterance = Utterance(analyzer: analyzer, input: feed, results: results)
        transcript = ""
        settled = true
        lastChange = Date()
        problem = nil
        listening = true
    }

    /// Closes the microphone and settles the utterance. A settled transcript is already final, so
    /// it returns at once; otherwise the analyzer finalizes its volatile tail, which is more
    /// accurate than the live guess, falling back to what was shown after `settleLimit`.
    func finish() -> Task<String, Never> {
        let shown = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if settled && !shown.isEmpty {
            stop()
            return Task { shown }
        }
        guard let current = closeMicrophone() else { return Task { shown } }
        current.input.finish()
        return Task {
            try? await current.analyzer.finalizeAndFinishThroughEndOfInput()
            let settled = await withTaskGroup(of: String?.self) { group in
                group.addTask { await current.results.value }
                group.addTask {
                    try? await Task.sleep(for: Self.settleLimit)
                    return nil
                }
                let first = await group.next() ?? nil
                if first == nil {
                    current.results.cancel()
                    await current.analyzer.cancelAndFinishNow()
                }
                group.cancelAll()
                return first
            }
            return settled.flatMap { $0.isEmpty ? nil : $0 } ?? shown
        }
    }

    /// Closes the microphone and drops the utterance.
    func stop() {
        guard let current = closeMicrophone() else { return }
        current.input.finish()
        current.results.cancel()
        Task { await current.analyzer.cancelAndFinishNow() }
    }

    /// How long `finish()` waits for the final text.
    static let settleLimit: Duration = .seconds(1)

    private func closeMicrophone() -> Utterance? {
        guard listening, let current = utterance else { return nil }
        generation += 1
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        utterance = nil
        listening = false
        level = 0
        transcript = ""
        return current
    }

    private func heard(level: Float, gen: Int) {
        guard gen == generation else { return }
        // Rise at once, fall gently, so the meter doesn't flicker between syllables.
        self.level = max(level, self.level * 0.8)
    }

    private func heard(transcript text: String, settled: Bool, gen: Int) {
        guard gen == generation else { return }
        self.settled = settled
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != transcript else { return }
        transcript = trimmed
        lastChange = Date()
    }

    private func failed(_ error: Error, gen: Int) {
        guard gen == generation else { return }
        stop()
        problem = .failed("Speech recognition stopped: \(error.localizedDescription)")
    }

    private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        // Progressive: quick volatile results while speaking, replaced by final text.
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    // MARK: - Off the main actor

    /// The audio tap: converts each buffer to the analyzer's format, queues it and reports its
    /// loudness. Built off the main actor because the engine calls it on its realtime thread.
    private nonisolated static func tap(
        converter: AVAudioConverter?,
        to format: AVAudioFormat,
        feed: AsyncStream<AnalyzerInput>.Continuation,
        level: @escaping @Sendable (Float) -> Void
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        // Only the audio thread touches the converter after this.
        let conversion = UncheckedSendableBox(value: (converter: converter, format: format))
        return { buffer, _ in
            level(loudness(buffer))
            guard let converted = convert(buffer, with: conversion.value.converter, to: conversion.value.format) else { return }
            feed.yield(AnalyzerInput(buffer: converted))
        }
    }

    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let supplied = SuppliedOnce()
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied.done {
                status.pointee = .noDataNow
                return nil
            }
            supplied.done = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
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

/// Hands a value the API doesn't mark Sendable to the audio thread, which is then its only user.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

/// The converter asks for input until told there's none; each call has exactly one buffer.
private final class SuppliedOnce: @unchecked Sendable {
    var done = false
}
