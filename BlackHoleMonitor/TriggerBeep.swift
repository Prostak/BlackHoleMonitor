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
            playOnQueue(amplitude: amplitude)
        }
    }

    private func playOnQueue(amplitude: Float) {
        do {
            try configureIfNeeded()
            guard let playbackFormat else { return }

            let buffer = try makeBeepBuffer(amplitude: amplitude, format: playbackFormat)
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
        let sampleRate = format.sampleRate
        let duration: TimeInterval = 0.15
        let frequency: Double = 880
        let frameCount = AVAudioFrameCount(sampleRate * duration)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData else {
            throw BeepError.unavailableOutput
        }

        buffer.frameLength = frameCount
        let level = min(max(amplitude, 0.01), 1.0)
        let fadeInFrames = Int(sampleRate * 0.01)
        let fadeOutFrames = Int(sampleRate * 0.03)
        let channels = Int(format.channelCount)

        for index in 0..<Int(frameCount) {
            let time = Double(index) / sampleRate
            let sample = sin(2 * .pi * frequency * time)
            let fadeIn = min(1.0, Double(index) / Double(max(fadeInFrames, 1)))
            let fadeOut = min(1.0, Double(Int(frameCount) - index) / Double(max(fadeOutFrames, 1)))
            let value = Float(sample) * level * Float(fadeIn * fadeOut)
            for channel in 0..<channels {
                channelData[channel][index] = value
            }
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
