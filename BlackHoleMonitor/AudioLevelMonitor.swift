import AppKit
import AVFoundation
import Combine
import CoreMedia
import Foundation

struct AudioInputOption: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

enum TriggerResponseMode: String, CaseIterable, Identifiable {
    case screenSharing
    case serial
    case localBeep

    var id: String { rawValue }

    var label: String {
        switch self {
        case .screenSharing: "Send ` to Screen Sharing"
        case .serial: "Send ` via serial (Pico)"
        case .localBeep: "Local beep only"
        }
    }
}

@MainActor
final class AudioLevelMonitor: NSObject, ObservableObject {
    static let defaultDeviceName = "BlackHole 2ch"
    static let historyCapacity = 240
    static let absoluteGraphMaxRMS: Float = GraphScaleStore.absoluteGraphMax
    static let triggerDelaySeconds: TimeInterval = 0.5
    static let keepaliveIntervalSeconds: TimeInterval = 30
    static let rearmThresholdFraction: Float = 0.5
    static let minimumTriggerRMS: Float = 0.001

    var triggerThresholdDB: Float { Self.db(fromRMS: triggerThresholdRMS) }

    @Published private(set) var levelRMS: Float = 0
    @Published private(set) var peakRMS: Float = 0
    @Published private(set) var levelHistory: [Float] = Array(repeating: 0, count: historyCapacity)
    @Published private(set) var isRunning = false
    @Published private(set) var permissionGranted = false
    @Published private(set) var statusMessage = "Requesting microphone access…"
    @Published private(set) var selectedDeviceName: String?
    @Published private(set) var availableInputs: [AudioInputOption] = []
    @Published var selectedInputUID: String = ""
    @Published var triggerThresholdRMS: Float = ThresholdStore.defaultThresholdRMS {
        didSet {
            guard !isLoadingThreshold, !selectedInputUID.isEmpty else { return }
            ThresholdStore.save(uid: selectedInputUID, rms: triggerThresholdRMS)
        }
    }
    @Published private(set) var graphMaxRMS: Float = GraphScaleStore.defaultGraphMax
    @Published var passThroughEnabled = false {
        didSet {
            guard oldValue != passThroughEnabled else { return }
            updatePassThrough()
        }
    }
    @Published var triggerResponseMode: TriggerResponseMode = {
        TriggerResponseMode(
            rawValue: UserDefaults.standard.string(forKey: "triggerResponseMode") ?? ""
        ) ?? .screenSharing
    }() {
        didSet {
            guard oldValue != triggerResponseMode else { return }
            UserDefaults.standard.set(triggerResponseMode.rawValue, forKey: Self.triggerResponseModeKey)
            updateSerialConnectionForMode()
            updateKeepaliveMonitoring()
            if isRunning, !passThroughEnabled {
                statusMessage = listeningStatusMessage()
            }
        }
    }

    @Published var serialPortPath: String = {
        UserDefaults.standard.string(forKey: "serialPortPath") ?? SerialPort.defaultPath
    }() {
        didSet {
            guard oldValue != serialPortPath else { return }
            UserDefaults.standard.set(serialPortPath, forKey: Self.serialPortPathKey)
            if triggerResponseMode == .serial {
                updateSerialConnectionForMode()
            }
        }
    }

    @Published private(set) var serialConnected = false

    private static let triggerResponseModeKey = "triggerResponseMode"
    private static let serialPortPathKey = "serialPortPath"

    private let captureSession = AVCaptureSession()
    private nonisolated(unsafe) let passThrough = AudioPassThrough()
    private let serialPort = SerialPort()
    private let captureQueue = DispatchQueue(label: "com.blackholemonitor.capture", qos: .userInteractive)

    override init() {
        super.init()
        passThrough.onError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.passThroughEnabled = false
                self.statusMessage = "Pass-through failed: \(AudioErrorFormatting.describe(error))"
            }
        }
        updateSerialConnectionForMode()
    }
    private var peakHoldRMS: Float = 0
    private var peakHoldUntil: Date = .distantPast
    private var isExecutingAutomation = false
    private var isArmed = true
    private var awaitingRearm = false
    private var automationTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var isLoadingThreshold = false

    func requestPermissionAndStart() {
        refreshInputDevices()
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

    func refreshInputDevices() {
        let devices = AudioDeviceHelper.inputDevices().compactMap { device -> AudioInputOption? in
            guard let uid = AudioDeviceHelper.deviceUID(device.id) else { return nil }
            return AudioInputOption(uid: uid, name: device.name)
        }
        availableInputs = devices

        if selectedInputUID.isEmpty || !devices.contains(where: { $0.uid == selectedInputUID }) {
            selectedInputUID = devices.first(where: { $0.name == Self.defaultDeviceName })?.uid
                ?? devices.first?.uid
                ?? ""
        }
        loadSettingsForCurrentInput()
    }

    func selectInput(uid: String) {
        guard uid != selectedInputUID else { return }
        selectedInputUID = uid
        selectedDeviceName = availableInputs.first(where: { $0.uid == uid })?.name
        loadSettingsForCurrentInput()

        if isRunning {
            startMonitoring()
        } else {
            updatePassThrough()
        }
    }

    func setTriggerThresholdRMS(_ rms: Float) {
        triggerThresholdRMS = min(max(rms, Self.minimumTriggerRMS), graphMaxRMS)
    }

    private func loadSettingsForCurrentInput() {
        guard !selectedInputUID.isEmpty else { return }
        isLoadingThreshold = true
        graphMaxRMS = GraphScaleStore.graphMaxRMS(for: selectedInputUID, deviceName: selectedDeviceName)
        triggerThresholdRMS = min(
            ThresholdStore.threshold(for: selectedInputUID, deviceName: selectedDeviceName),
            graphMaxRMS
        )
        isLoadingThreshold = false
    }

    private func updateGraphScale(with peak: Float) {
        guard !selectedInputUID.isEmpty else { return }
        let newMax = GraphScaleStore.recordPeak(uid: selectedInputUID, peak: peak, deviceName: selectedDeviceName)
        guard abs(newMax - graphMaxRMS) > 0.000_001 else { return }
        graphMaxRMS = newMax
        if triggerThresholdRMS > graphMaxRMS {
            triggerThresholdRMS = graphMaxRMS
        }
    }

    func stopMonitoring() {
        cancelAutomation()
        stopKeepaliveMonitoring()
        passThrough.stop()
        captureQueue.async { [weak self] in
            self?.tearDownCaptureSession()
        }
        isRunning = false
        statusMessage = "Stopped"
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
        cancelAutomation()
        isExecutingAutomation = false
        isArmed = true
        awaitingRearm = false
        peakHoldRMS = 0
        peakRMS = 0
        refreshInputDevices()

        guard !selectedInputUID.isEmpty,
              let captureDevice = AVCaptureDevice(uniqueID: selectedInputUID) else {
            statusMessage = "No audio input selected"
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
                    setupError = "Could not add input \"\(captureDevice.localizedName)\""
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

    private func updatePassThrough() {
        passThrough.stop()

        guard passThroughEnabled else { return }

        do {
            try passThrough.start()
            if isRunning {
                statusMessage = "\(listeningStatusMessage()) · pass-through on"
            }
        } catch {
            passThroughEnabled = false
            statusMessage = "Pass-through failed: \(AudioErrorFormatting.describe(error))"
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
            if self.isRunning {
                self.updatePassThrough()
                self.updateKeepaliveMonitoring()
                if !self.passThroughEnabled {
                    self.statusMessage = self.listeningStatusMessage()
                }
            } else {
                self.statusMessage = "Capture session failed to start"
            }
        }
    }

    private func applyLevel(rms: Float) {
        let clamped = max(0, min(1, rms))

        if !isExecutingAutomation {
            levelRMS = clamped

            if clamped > peakHoldRMS || Date() >= peakHoldUntil {
                peakHoldRMS = clamped
                peakHoldUntil = Date().addingTimeInterval(1.2)
                peakRMS = clamped
                updateGraphScale(with: clamped)
            }

            var history = levelHistory
            history.removeFirst()
            history.append(clamped)
            levelHistory = history
        }

        updateRearmState(rms: clamped)
        checkThreshold(rms: clamped)
    }

    private func updateRearmState(rms: Float) {
        guard awaitingRearm, !isExecutingAutomation else { return }

        let rearmLevel = triggerThresholdRMS * Self.rearmThresholdFraction
        guard rms < rearmLevel else { return }

        awaitingRearm = false
        isArmed = true
        updateKeepaliveMonitoring()
    }

    private func checkThreshold(rms: Float) {
        guard isRunning, isArmed, !awaitingRearm, !isExecutingAutomation else { return }
        guard rms >= triggerThresholdRMS else { return }

        isArmed = false
        awaitingRearm = true
        isExecutingAutomation = true

        switch triggerResponseMode {
        case .screenSharing:
            handleScreenSharingTrigger()
        case .serial:
            handleSerialTrigger()
        case .localBeep:
            handleLocalBeepTrigger()
        }
    }

    private func handleLocalBeepTrigger() {
        statusMessage = String(
            format: "Threshold reached (≥ %.2f%%), playing beep…",
            triggerThresholdRMS * 100
        )
        TriggerBeep.shared.play(amplitude: triggerThresholdRMS)
        isExecutingAutomation = false
        statusMessage = waitingStatusMessage()
    }

    private func handleSerialTrigger() {
        statusMessage = String(
            format: "Threshold reached (≥ %.2f%%), sending first ` via serial…",
            triggerThresholdRMS * 100
        )

        automationTask = Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(for: .seconds(Self.triggerDelaySeconds))
            guard !Task.isCancelled else { return }
            let stillRunning = await MainActor.run { self.isRunning }
            guard stillRunning else { return }

            let firstSent = await MainActor.run { self.sendBacktickViaSerial() }
            guard !Task.isCancelled else { return }

            if !firstSent {
                await MainActor.run {
                    self.isExecutingAutomation = false
                    self.statusMessage = "Serial send failed (first `)"
                }
                return
            }

            let delay = ScreenSharingAutomation.secondBacktickDelay()
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }

            let secondSent = await MainActor.run { self.sendBacktickViaSerial() }
            await MainActor.run {
                self.isExecutingAutomation = false
                self.statusMessage = secondSent
                    ? self.waitingStatusMessage()
                    : "Serial send failed (second `)"
            }
        }
    }

    private func handleScreenSharingTrigger() {
        statusMessage = String(
            format: "Threshold reached (≥ %.2f%%), sending first `…",
            triggerThresholdRMS * 100
        )

        automationTask = Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(for: .seconds(Self.triggerDelaySeconds))
            guard !Task.isCancelled else { return }
            let stillRunning = await MainActor.run { self.isRunning }
            guard stillRunning else { return }

            let firstSent = await ScreenSharingAutomation.focusAndTypeBacktick()
            guard !Task.isCancelled else { return }

            if !firstSent {
                await MainActor.run {
                    self.isExecutingAutomation = false
                    self.statusMessage = "Screen Sharing automation failed (first `)"
                }
                await ScreenSharingAutomation.activateSelf()
                return
            }

            let delay = ScreenSharingAutomation.secondBacktickDelay()
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }

            let secondSent = await ScreenSharingAutomation.refocusWaitAndTypeSecondBacktick()
            if !secondSent {
                await MainActor.run {
                    self.isExecutingAutomation = false
                    self.statusMessage = "Screen Sharing automation failed (second `)"
                }
                await ScreenSharingAutomation.activateSelf()
                return
            }

            try? await Task.sleep(for: .seconds(ScreenSharingAutomation.postSecondKeyReturnDelaySeconds))
            await ScreenSharingAutomation.activateSelf()

            await MainActor.run {
                self.isExecutingAutomation = false
                self.statusMessage = self.waitingStatusMessage()
            }
        }
    }

    private func updateKeepaliveMonitoring() {
        stopKeepaliveMonitoring()
        guard isRunning else { return }
        guard triggerResponseMode == .screenSharing || triggerResponseMode == .serial else { return }

        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.keepaliveIntervalSeconds))
                guard !Task.isCancelled else { return }

                let mode = await MainActor.run { () -> TriggerResponseMode? in
                    guard let self else { return nil }
                    guard self.isRunning, !self.isExecutingAutomation else { return nil }
                    switch self.triggerResponseMode {
                    case .screenSharing, .serial:
                        return self.triggerResponseMode
                    case .localBeep:
                        return nil
                    }
                }
                guard let mode else { continue }

                switch mode {
                case .screenSharing:
                    await MainActor.run {
                        self?.isExecutingAutomation = true
                        self?.statusMessage = "Keepalive: sending ` to Screen Sharing…"
                    }

                    let sent = await ScreenSharingAutomation.focusWaitTypeBacktickAndReturn()

                    await MainActor.run {
                        guard let self else { return }
                        self.isExecutingAutomation = false
                        self.statusMessage = sent
                            ? self.waitingStatusMessage()
                            : "Keepalive failed: could not send `"
                    }

                case .serial:
                    await MainActor.run {
                        guard let self else { return }
                        self.isExecutingAutomation = true
                        self.statusMessage = "Keepalive: sending ` via serial…"
                        let sent = self.sendBacktickViaSerial()
                        self.isExecutingAutomation = false
                        self.statusMessage = sent
                            ? self.waitingStatusMessage()
                            : "Keepalive failed: serial send failed"
                    }

                case .localBeep:
                    continue
                }
            }
        }
    }

    @discardableResult
    func reconnectSerial() -> Bool {
        guard triggerResponseMode == .serial else {
            statusMessage = "Switch trigger mode to serial first"
            return false
        }
        return openSerialPort()
    }

    private func updateSerialConnectionForMode() {
        if triggerResponseMode == .serial {
            _ = openSerialPort()
        } else {
            closeSerialPort()
        }
    }

    @discardableResult
    private func openSerialPort() -> Bool {
        do {
            try serialPort.open(path: serialPortPath)
            serialConnected = true
            statusMessage = "Serial connected: \(serialPortPath)"
            return true
        } catch {
            serialConnected = false
            statusMessage = "Serial connect failed: \(error.localizedDescription)"
            return false
        }
    }

    private func closeSerialPort() {
        serialPort.close()
        serialConnected = false
    }

    @discardableResult
    private func sendBacktickViaSerial() -> Bool {
        if !serialPort.isOpen {
            guard openSerialPort() else { return false }
        }

        do {
            try serialPort.writeBacktick()
            serialConnected = true
            return true
        } catch {
            serialConnected = false
            statusMessage = "Serial send failed: \(error.localizedDescription)"
            return false
        }
    }

    private func stopKeepaliveMonitoring() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    private func listeningStatusMessage() -> String {
        let device = selectedDeviceName ?? "input"
        switch triggerResponseMode {
        case .screenSharing:
            return "Listening to \"\(device)\""
        case .serial:
            let link = serialConnected ? "serial OK" : "serial offline"
            return "Listening to \"\(device)\" · \(link)"
        case .localBeep:
            return "Listening to \"\(device)\" · local beep mode"
        }
    }

    private func waitingStatusMessage() -> String {
        switch triggerResponseMode {
        case .screenSharing:
            return "Waiting for next sound trigger…"
        case .serial:
            return "Waiting for next sound trigger (serial)…"
        case .localBeep:
            return "Waiting for next sound trigger (local beep)…"
        }
    }

    private func cancelAutomation() {
        automationTask?.cancel()
        automationTask = nil
    }

    nonisolated static func rms(fromDB db: Float) -> Float {
        pow(10, db / 20)
    }

    nonisolated static func db(fromRMS rms: Float) -> Float {
        20 * log10(max(rms, 0.000_000_1))
    }

    nonisolated private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let format = AVAudioFormat(streamDescription: streamDescription)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let format,
              let pcmBuffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            return nil
        }

        return pcmBuffer
    }

    nonisolated private static func computeRMS(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let pcmBuffer = pcmBuffer(from: sampleBuffer) else { return 0 }
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
        if passThrough.acceptsBuffers, let pcmBuffer = Self.pcmBuffer(from: sampleBuffer) {
            passThrough.enqueue(pcmBuffer)
        }
        Task { @MainActor [weak self] in
            self?.applyLevel(rms: rms)
        }
    }
}
