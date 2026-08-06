import AppKit
import AVFoundation
import Combine
import CoreMedia
import Foundation

@MainActor
final class AudioLevelMonitor: NSObject, ObservableObject {
    static let targetDeviceName = "BlackHole 2ch"
    static let historyCapacity = 240
    static let referencePeakDB: Float = -28
    static let triggerThresholdScale: Float = 0.72
    static let triggerDelaySeconds: TimeInterval = 0.5

    static var triggerThresholdRMS: Float { rms(fromDB: referencePeakDB) * triggerThresholdScale }
    static var triggerThresholdDB: Float { db(fromRMS: triggerThresholdRMS) }

    @Published private(set) var levelRMS: Float = 0
    @Published private(set) var peakRMS: Float = 0
    @Published private(set) var levelHistory: [Float] = Array(repeating: 0, count: historyCapacity)
    @Published private(set) var isRunning = false
    @Published private(set) var permissionGranted = false
    @Published private(set) var statusMessage = "Requesting microphone access…"
    @Published private(set) var selectedDeviceName: String?

    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.blackholemonitor.capture", qos: .userInteractive)
    private var peakHoldRMS: Float = 0
    private var peakHoldUntil: Date = .distantPast
    private var thresholdTriggered = false
    private var autoStopTask: Task<Void, Never>?

    func requestPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permissionGranted = true
            startMonitoring()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    self?.permissionGranted = granted
                    if granted {
                        self?.startMonitoring()
                    } else {
                        self?.statusMessage = "Microphone access denied. Enable it in System Settings → Privacy → Microphone."
                    }
                }
            }
        case .denied, .restricted:
            permissionGranted = false
            statusMessage = "Microphone access denied. Enable it in System Settings → Privacy → Microphone."
        @unknown default:
            permissionGranted = false
            statusMessage = "Unknown microphone permission status."
        }
    }

    func stopMonitoring() {
        cancelAutoStop()
        captureQueue.async { [weak self] in
            self?.tearDownCaptureSession()
        }
        isRunning = false
        if !statusMessage.hasPrefix("Stopped (threshold") {
            statusMessage = "Stopped"
        }
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    nonisolated private func tearDownCaptureSession() {
        let session = captureSession
        if session.isRunning {
            session.stopRunning()
        }

        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        session.commitConfiguration()
    }

    private func startMonitoring() {
        cancelAutoStop()
        thresholdTriggered = false
        peakHoldRMS = 0
        peakRMS = 0

        guard let deviceID = AudioDeviceHelper.findInputDevice(named: Self.targetDeviceName) else {
            let available = AudioDeviceHelper.inputDevices().map(\.name).joined(separator: ", ")
            statusMessage = "Device \"\(Self.targetDeviceName)\" not found. Available inputs: \(available.isEmpty ? "none" : available)"
            return
        }

        guard let deviceUID = AudioDeviceHelper.deviceUID(deviceID) else {
            statusMessage = "Could not read UID for \"\(Self.targetDeviceName)\""
            return
        }

        guard let captureDevice = AVCaptureDevice(uniqueID: deviceUID) else {
            statusMessage = "AVCaptureDevice could not find \"\(Self.targetDeviceName)\" (uid: \(deviceUID))"
            return
        }

        selectedDeviceName = captureDevice.localizedName

        captureQueue.async { [weak self] in
            guard let self else { return }

            self.tearDownCaptureSession()

            let session = self.captureSession
            var setupError: String?

            session.beginConfiguration()

            do {
                let input = try AVCaptureDeviceInput(device: captureDevice)
                guard session.canAddInput(input) else {
                    setupError = "Could not add input \"\(Self.targetDeviceName)\""
                    session.commitConfiguration()
                    self.reportStartResult(error: setupError)
                    return
                }
                session.addInput(input)

                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: self.captureQueue)
                guard session.canAddOutput(output) else {
                    setupError = "Could not add audio output"
                    session.commitConfiguration()
                    self.reportStartResult(error: setupError)
                    return
                }
                session.addOutput(output)
            } catch {
                setupError = "Setup error: \(error.localizedDescription)"
                session.commitConfiguration()
                self.reportStartResult(error: setupError)
                return
            }

            session.commitConfiguration()
            session.startRunning()
            self.reportStartResult(error: nil)
        }
    }

    nonisolated private func reportStartResult(error: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                self.isRunning = false
                self.statusMessage = error
                return
            }

            self.isRunning = self.captureSession.isRunning
            self.statusMessage = self.isRunning
                ? "Listening to \"\(Self.targetDeviceName)\""
                : "Capture session failed to start"
        }
    }

    private func applyLevel(rms: Float) {
        let clamped = max(0, min(1, rms))
        levelRMS = clamped

        if clamped > peakHoldRMS || Date() >= peakHoldUntil {
            peakHoldRMS = clamped
            peakHoldUntil = Date().addingTimeInterval(1.2)
            peakRMS = clamped
        }

        var history = levelHistory
        history.removeFirst()
        history.append(clamped)
        levelHistory = history

        checkThreshold(rms: clamped)
    }

    private func checkThreshold(rms: Float) {
        guard isRunning, !thresholdTriggered else { return }
        guard rms >= Self.triggerThresholdRMS else { return }

        thresholdTriggered = true
        statusMessage = String(
            format: "Threshold reached (≥ %.1f dB), stopping in 0.5s…",
            Self.triggerThresholdDB
        )

        autoStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.triggerDelaySeconds))
            guard let self, !Task.isCancelled else { return }
            self.stopMonitoring()
            self.statusMessage = String(
                format: "Stopped (threshold %.1f dB reached)",
                Self.triggerThresholdDB
            )
        }
    }

    private func cancelAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = nil
    }

    nonisolated static func rms(fromDB db: Float) -> Float {
        pow(10, db / 20)
    }

    nonisolated static func db(fromRMS rms: Float) -> Float {
        20 * log10(max(rms, 0.000_000_1))
    }

    nonisolated private static func computeRMS(from sampleBuffer: CMSampleBuffer) -> Float {
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return 0
        }

        let format = AVAudioFormat(streamDescription: streamDescription)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let format,
              let pcmBuffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return 0
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            return 0
        }

        return computeRMS(from: pcmBuffer)
    }

    nonisolated private static func computeRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return 0
        }

        let channels = Int(buffer.format.channelCount)
        var sumSquares: Float = 0
        var sampleCount = 0

        if let floatData = buffer.floatChannelData {
            for channel in 0..<channels {
                let samples = floatData[channel]
                for index in 0..<frameLength {
                    let sample = samples[index]
                    sumSquares += sample * sample
                    sampleCount += 1
                }
            }
        } else if let int16Data = buffer.int16ChannelData {
            let scale = 1.0 / Float(Int16.max)
            for channel in 0..<channels {
                let samples = int16Data[channel]
                for index in 0..<frameLength {
                    let sample = Float(samples[index]) * scale
                    sumSquares += sample * sample
                    sampleCount += 1
                }
            }
        } else if let int32Data = buffer.int32ChannelData {
            let scale = 1.0 / Float(Int32.max)
            for channel in 0..<channels {
                let samples = int32Data[channel]
                for index in 0..<frameLength {
                    let sample = Float(samples[index]) * scale
                    sumSquares += sample * sample
                    sampleCount += 1
                }
            }
        } else {
            return 0
        }

        let meanSquare = sumSquares / Float(max(sampleCount, 1))
        return sqrt(meanSquare)
    }
}

extension AudioLevelMonitor: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let rms = Self.computeRMS(from: sampleBuffer)
        Task { @MainActor [weak self] in
            self?.applyLevel(rms: rms)
        }
    }
}
