import AudioUnit
import AVFoundation
import Foundation

final class AudioPassThrough {
    private let engine = AVAudioEngine()
    private var isRunning = false

    func start(deviceUID: String) throws {
        stop()

        guard let deviceID = AudioDeviceHelper.findInputDevice(uid: deviceUID) else {
            throw PassThroughError.deviceNotFound
        }

        let inputNode = engine.inputNode
        let audioUnit = inputNode.audioUnit!
        guard AudioDeviceHelper.setInputDevice(deviceID, on: audioUnit) else {
            throw PassThroughError.deviceSetupFailed
        }

        let format = inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw PassThroughError.noInputChannels
        }

        engine.connect(inputNode, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        engine.reset()
        isRunning = false
    }

    enum PassThroughError: LocalizedError {
        case deviceNotFound
        case deviceSetupFailed
        case noInputChannels

        var errorDescription: String? {
            switch self {
            case .deviceNotFound: "Audio input device not found"
            case .deviceSetupFailed: "Could not select audio input device"
            case .noInputChannels: "Selected device has no input channels"
            }
        }
    }
}
