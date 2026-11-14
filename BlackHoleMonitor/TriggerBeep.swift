import AVFoundation
import Foundation

final class TriggerBeep {
    static let shared = TriggerBeep()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.blackholemonitor.beep", qos: .userInteractive)
    private var isConfigured = false
    private var playbackFormat: AVAudioFormat?

    func play(amplitude: Float) {
        queue.async { [self] in
            playOnQueue(amplitude: amplitude, pattern: .single)
        }
    }

    /// Three short beeps — used when Autobattle button disappears (battle ended).
    func playTriple(amplitude: Float) {
        queue.async { [self] in
            playOnQueue(amplitude: amplitude, pattern: .triple)
        }
    }

    private enum BeepPattern {
        case single
        case triple
    }

    private func playOnQueue(amplitude: Float, pattern: BeepPattern) {
        do {
            try configureIfNeeded()
            guard let playbackFormat else { return }

            let buffer: AVAudioPCMBuffer
            switch pattern {
            case .single:
                buffer = try makeBeepBuffer(amplitude: amplitude, format: playbackFormat)
            case .triple:
                buffer = try makeTripleBeepBuffer(amplitude: amplitude, format: playbackFormat)
            }
            playerNode.scheduleBuffer(buffer)

            if !engine.isRunning {
                try engine.start()
            }
            playerNode.play()
        } catch {
            NSLog("TriggerBeep failed: \(error.localizedDescription)")
        }
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.prepare()

        let mixerInputFormat = engine.mainMixerNode.inputFormat(forBus: 0)
        guard mixerInputFormat.channelCount > 0, mixerInputFormat.sampleRate > 0 else {
            throw BeepError.unavailableOutput
        }

        playbackFormat = mixerInputFormat
        isConfigured = true
    }

    private func makeBeepBuffer(amplitude: Float, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        try makeToneBuffer(
            amplitude: amplitude,
            format: format,
            beepDuration: 0.15,
            gapDuration: 0,
            beepCount: 1,
            frequency: 880
        )
    }

    private func makeTripleBeepBuffer(amplitude: Float, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        try makeToneBuffer(
            amplitude: amplitude,
            format: format,
            beepDuration: 0.07,
            gapDuration: 0.07,
            beepCount: 3,
            frequency: 1175
        )
    }

    private func makeToneBuffer(
        amplitude: Float,
        format: AVAudioFormat,
        beepDuration: TimeInterval,
        gapDuration: TimeInterval,
        beepCount: Int,
        frequency: Double
    ) throws -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let beepFrames = Int(sampleRate * beepDuration)
        let gapFrames = Int(sampleRate * gapDuration)
        let totalFrames = beepCount * beepFrames + max(0, beepCount - 1) * gapFrames
        let frameCount = AVAudioFrameCount(max(totalFrames, 1))

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData else {
            throw BeepError.unavailableOutput
        }

        buffer.frameLength = frameCount
        let level = min(max(amplitude, 0.01), 1.0)
        let fadeInFrames = max(1, Int(sampleRate * 0.008))
        let fadeOutFrames = max(1, Int(sampleRate * 0.02))
        let channels = Int(format.channelCount)

        for channel in 0..<channels {
            for i in 0..<Int(frameCount) {
                channelData[channel][i] = 0
            }
        }

        var cursor = 0
        for _ in 0..<beepCount {
            for index in 0..<beepFrames {
                let time = Double(index) / sampleRate
                let sample = sin(2 * .pi * frequency * time)
                let fadeIn = min(1.0, Double(index) / Double(fadeInFrames))
                let fadeOut = min(1.0, Double(beepFrames - index) / Double(fadeOutFrames))
                let value = Float(sample) * level * Float(fadeIn * fadeOut)
                let frame = cursor + index
                guard frame < Int(frameCount) else { break }
                for channel in 0..<channels {
                    channelData[channel][frame] = value
                }
            }
            cursor += beepFrames + gapFrames
        }

        return buffer
    }

    enum BeepError: LocalizedError {
        case unavailableOutput

        var errorDescription: String? {
            "System audio output is unavailable"
        }
    }
}
