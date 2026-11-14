import AVFoundation
import Foundation

final class AudioPassThrough {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.blackholemonitor.passthrough", qos: .userInteractive)
    private var isEnabled = false
    private var isConfigured = false
    private var sourceFormat: AVAudioFormat?
    private var playbackFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let maxScheduledBuffers = 4
    private var scheduledBufferCount = 0
    private(set) var acceptsBuffers = false

    var onError: ((Error) -> Void)?

    func start() throws {
        queue.sync {
            guard !isEnabled else { return }
            isEnabled = true
            acceptsBuffers = true
        }
    }

    func stop() {
        queue.sync {
            acceptsBuffers = false
            isEnabled = false
            scheduledBufferCount = 0
            playerNode.stop()
            if engine.isRunning {
                engine.stop()
            }
            if isConfigured {
                engine.disconnectNodeInput(engine.mainMixerNode)
                engine.disconnectNodeOutput(playerNode)
                engine.detach(playerNode)
            }
            engine.reset()
            resetConfiguration()
        }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            self?.enqueueOnQueue(buffer)
        }
    }

    private func enqueueOnQueue(_ buffer: AVAudioPCMBuffer) {
        guard isEnabled, buffer.frameLength > 0 else { return }

        do {
            try configureIfNeeded(format: buffer.format)
            guard isConfigured else { return }

            if scheduledBufferCount >= maxScheduledBuffers {
                return
            }

            let playbackBuffer = try makePlaybackBuffer(from: buffer)

            if !engine.isRunning {
                try engine.start()
                playerNode.play()
            }

            scheduledBufferCount += 1
            playerNode.scheduleBuffer(playbackBuffer, at: nil, options: []) { [weak self] in
                self?.queue.async {
                    self?.scheduledBufferCount = max(0, (self?.scheduledBufferCount ?? 1) - 1)
                }
            }
        } catch {
            disableWithError(error)
        }
    }

    private func configureIfNeeded(format inputFormat: AVAudioFormat) throws {
        if isConfigured {
            guard formatsCompatible(sourceFormat, inputFormat) else {
                throw PassThroughError.formatChanged
            }
            return
        }

        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw PassThroughError.noInputChannels
        }

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.prepare()

        let mixerInputFormat = engine.mainMixerNode.inputFormat(forBus: 0)
        guard mixerInputFormat.channelCount > 0, mixerInputFormat.sampleRate > 0 else {
            throw PassThroughError.noInputChannels
        }

        playbackFormat = mixerInputFormat
        sourceFormat = inputFormat

        if formatsCompatible(inputFormat, mixerInputFormat) {
            converter = nil
        } else {
            guard let audioConverter = AVAudioConverter(from: inputFormat, to: mixerInputFormat) else {
                throw PassThroughError.unsupportedFormat
            }
            converter = audioConverter
        }

        isConfigured = true
    }

    private func makePlaybackBuffer(from buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter, let playbackFormat else {
            return copyBuffer(buffer)
        }

        let ratio = playbackFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
        guard let output = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frameCapacity) else {
            throw PassThroughError.unsupportedFormat
        }

        var consumedInput = false
        var conversionError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: output, error: &conversionError, withInputFrom: inputBlock)
        if status == .error || conversionError != nil {
            throw PassThroughError.unsupportedFormat
        }

        return output
    }

    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return buffer
        }
        copy.frameLength = buffer.frameLength

        let channels = Int(buffer.format.channelCount)
        if let floatData = buffer.floatChannelData, let copyData = copy.floatChannelData {
            for channel in 0..<channels {
                memcpy(copyData[channel], floatData[channel], Int(buffer.frameLength) * MemoryLayout<Float>.size)
            }
        }

        return copy
    }

    private func disableWithError(_ error: Error) {
        acceptsBuffers = false
        isEnabled = false
        onError?(error)
    }

    private func resetConfiguration() {
        isConfigured = false
        sourceFormat = nil
        playbackFormat = nil
        converter = nil
    }

    private func formatsCompatible(_ lhs: AVAudioFormat?, _ rhs: AVAudioFormat) -> Bool {
        guard let lhs else { return false }
        return lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    enum PassThroughError: LocalizedError {
        case noInputChannels
        case formatChanged
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .noInputChannels:
                return "Selected device has no input channels"
            case .formatChanged:
                return "Capture audio format changed during pass-through"
            case .unsupportedFormat:
                return "Could not convert capture audio for pass-through"
            }
        }
    }
}

enum AudioErrorFormatting {
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        let description = error.localizedDescription
        if nsError.domain == NSOSStatusErrorDomain || nsError.domain.contains("coreaudio") {
            return "\(description) (OSStatus \(nsError.code))"
        }
        return description
    }
}
