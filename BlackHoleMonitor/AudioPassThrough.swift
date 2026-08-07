import AVFoundation
import Foundation

final class AudioPassThrough {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.blackholemonitor.passthrough", qos: .userInteractive)
    private var isEnabled = false
    private var isConfigured = false
    private var configuredFormat: AVAudioFormat?
    private let maxScheduledBuffers = 4
    private var scheduledBufferCount = 0
    nonisolated(unsafe) private(set) var acceptsBuffers = false

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
            isConfigured = false
            configuredFormat = nil
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

            if !engine.isRunning {
                try engine.start()
                playerNode.play()
            }

            scheduledBufferCount += 1
            playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
                self?.queue.async {
                    self?.scheduledBufferCount = max(0, (self?.scheduledBufferCount ?? 1) - 1)
                }
            }
        } catch {
            isEnabled = false
            onError?(error)
        }
    }

    private func configureIfNeeded(format: AVAudioFormat) throws {
        guard !isConfigured else {
            if configuredFormat != format {
                throw PassThroughError.formatChanged
            }
            return
        }

        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw PassThroughError.noInputChannels
        }

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.prepare()
        isConfigured = true
        configuredFormat = format
    }

    enum PassThroughError: LocalizedError {
        case noInputChannels
        case formatChanged

        var errorDescription: String? {
            switch self {
            case .noInputChannels: "Selected device has no input channels"
            case .formatChanged: "Capture audio format changed during pass-through"
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
