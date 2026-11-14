import AVFoundation
import CoreGraphics
import Foundation
import VideoToolbox

/// Grabs the latest frame from a USB/UVC capture device (prefers Elgato).
final class AutobattleCameraCapture: NSObject {
    static let shared = AutobattleCameraCapture()

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(label: "com.local.Bhm12.autobattle.camera.sample", qos: .userInitiated)
    /// Serializes beginConfiguration / startRunning / stopRunning (AVCapture is not re-entrant).
    private let controlQueue = DispatchQueue(label: "com.local.Bhm12.autobattle.camera.control")
    private let frameLock = NSLock()

    private var latestImage: CGImage?
    private var latestDate: Date?
    private var activeDeviceID: String?
    private var isConfigured = false
    private(set) var lastError: String?

    private override init() {
        super.init()
    }

    static func listVideoDevices() -> [AVCaptureDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices
    }

    /// Prefer Elgato, then any external (non-FaceTime) device, then first video device.
    static func preferredDevice() -> AVCaptureDevice? {
        let devices = listVideoDevices()
        if let elgato = devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains("Elgato") }) {
            return elgato
        }
        if let external = devices.first(where: {
            !$0.localizedName.localizedCaseInsensitiveContains("FaceTime")
        }) {
            return external
        }
        return devices.first
    }

    var isRunning: Bool {
        controlQueue.sync { session.isRunning }
    }

    var activeDeviceName: String? {
        controlQueue.sync {
            guard let id = activeDeviceID else { return nil }
            return Self.listVideoDevices().first(where: { $0.uniqueID == id })?.localizedName
        }
    }

    @discardableResult
    func start() -> Bool {
        controlQueue.sync { startLocked() }
    }

    private func startLocked() -> Bool {
        lastError = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            // Caller should request permission first; avoid blocking here.
            lastError = "camera permission not granted yet"
            return false
        default:
            lastError = "camera permission denied"
            return false
        }

        guard let device = Self.preferredDevice() else {
            lastError = "no camera found"
            return false
        }

        if session.isRunning, activeDeviceID == device.uniqueID, isConfigured {
            return true
        }

        stopLocked()

        do {
            session.beginConfiguration()
            session.sessionPreset = .high

            for input in session.inputs {
                session.removeInput(input)
            }
            for out in session.outputs {
                session.removeOutput(out)
            }

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                lastError = "cannot add camera input"
                return false
            }
            session.addInput(input)

            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                lastError = "cannot add video output"
                return false
            }
            session.addOutput(output)
            session.commitConfiguration()

            activeDeviceID = device.uniqueID
            isConfigured = true
            session.startRunning()
            return session.isRunning
        } catch {
            if session.isRunning == false {
                // beginConfiguration may still be open if throw happened mid-setup
            }
            session.commitConfiguration()
            lastError = error.localizedDescription
            isConfigured = false
            activeDeviceID = nil
            return false
        }
    }

    func stop() {
        controlQueue.sync { stopLocked() }
    }

    private func stopLocked() {
        if session.isRunning {
            session.stopRunning()
        }
        // Drain in-flight sample callbacks before clearing frames.
        sampleQueue.sync {}
        frameLock.lock()
        latestImage = nil
        latestDate = nil
        frameLock.unlock()
        isConfigured = false
        activeDeviceID = nil
    }

    /// Newest frame if fresher than `maxAge` seconds. Never starts the session.
    func latestFrame(maxAge: TimeInterval = 2.5) -> CGImage? {
        frameLock.lock()
        defer { frameLock.unlock() }
        guard let image = latestImage, let date = latestDate else { return nil }
        guard Date().timeIntervalSince(date) <= maxAge else { return nil }
        return image
    }
}

extension AutobattleCameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard status == noErr, let cgImage else { return }

        frameLock.lock()
        latestImage = cgImage
        latestDate = Date()
        frameLock.unlock()
    }
}
