import AVFoundation
import Foundation
import VesperCore

/// Plays streamed 16-bit signed little-endian mono PCM chunks on `AVAudioEngine` with a short
/// jitter buffer (~120 ms) so Live Voice starts speaking as soon as Gemini emits its first audio
/// chunks rather than waiting for the entire WAV clip.
@MainActor
final class StreamingPCMPlayer {
    /// Initial audio buffered before starting playback so bursty network chunks never stutter.
    static let prebufferSeconds: Double = 0.12

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format: AVAudioFormat
    private var framer: PCMChunkFramer
    private let prebufferSamples: Int

    private var started = false
    private var paused = false
    private var inputFinished = false
    private var stopped = false
    private var pendingBuffers = 0
    private var endFired = false

    private let onStarted: @MainActor () -> Void
    private let onEnd: @MainActor () -> Void

    init?(
        sampleRate: Int,
        rate: Float = 1.0,
        onStarted: @escaping @MainActor () -> Void,
        onEnd: @escaping @MainActor () -> Void
    ) {
        let rateVal = max(1, sampleRate)
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(rateVal),
            channels: 1,
            interleaved: false
        ) else { return nil }
        self.format = fmt
        self.framer = PCMChunkFramer(sampleRate: rateVal)
        self.prebufferSamples = max(1, Int((Double(rateVal) * Self.prebufferSeconds).rounded()))
        self.onStarted = onStarted
        self.onEnd = onEnd
        self.timePitch.rate = max(0.5, min(2.5, rate))

        engine.attach(playerNode)
        engine.attach(timePitch)
        engine.connect(playerNode, to: timePitch, format: fmt)
        engine.connect(timePitch, to: engine.mainMixerNode, format: fmt)
    }

    var hasStarted: Bool { started }
    var isPaused: Bool { paused }
    var decodedDuration: Double { framer.decodedDuration }

    func setRate(_ newRate: Float) {
        timePitch.rate = max(0.5, min(2.5, newRate))
    }

    func pause() {
        guard started, !stopped, !paused else { return }
        paused = true
        playerNode.pause()
    }

    func resume() {
        guard started, !stopped, paused else { return }
        paused = false
        if !engine.isRunning {
            try? engine.start()
        }
        playerNode.play()
    }

    /// Feeds the next raw PCM byte slice. Returns false if the audio engine failed to start.
    @discardableResult
    func append(_ data: Data) -> Bool {
        guard !stopped, !inputFinished else { return false }
        let samples = framer.decode(data)
        guard !samples.isEmpty else { return true }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return false
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                channel.update(from: base, count: samples.count)
            }
        }
        pendingBuffers += 1
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor [weak self] in
                self?.bufferCompleted()
            }
        }
        if !started && framer.totalSamples >= prebufferSamples {
            return startPlayback()
        }
        return true
    }

    /// Marks the stream complete. Starts playback immediately for short clips smaller than the
    /// prebuffer threshold, or fires `onEnd` if no audio was received.
    func finishInput() {
        guard !stopped, !inputFinished else { return }
        inputFinished = true
        if !started {
            if pendingBuffers > 0 {
                if !startPlayback() {
                    finish()
                }
            } else {
                finish()
            }
        } else if pendingBuffers == 0 {
            finish()
        }
    }

    /// Stops playback immediately (interrupt, mute, or replacement) without firing `onEnd`.
    func stop() {
        guard !stopped else { return }
        stopped = true
        playerNode.stop()
        engine.stop()
    }

    private func startPlayback() -> Bool {
        guard !started, !stopped else { return false }
        do {
            engine.prepare()
            try engine.start()
            playerNode.play()
            started = true
            onStarted()
            return true
        } catch {
            stop()
            return false
        }
    }

    private func bufferCompleted() {
        guard !stopped else { return }
        pendingBuffers = max(0, pendingBuffers - 1)
        if inputFinished && pendingBuffers == 0 {
            finish()
        }
    }

    private func finish() {
        guard !stopped, !endFired else { return }
        endFired = true
        playerNode.stop()
        engine.stop()
        onEnd()
    }
}
